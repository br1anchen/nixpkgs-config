#!/usr/bin/env python3
"""Deterministic half of pstack-kitchen: a repo's .agents/kitchen.toml read
as data. It classifies a change into profiles and a risk class, runs a
profile's gate commands, checks added lines against the repo's policy, and
diagnoses the kitchen itself. Nothing here calls a model.

Exit codes: 0 ok, 1 usage or config error, 2 a gate or policy check failed,
3 doctor found a problem.
"""
from __future__ import annotations

import argparse
import fcntl
import hashlib
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path

import tomllib

CONFIG = '.agents/kitchen.toml'
STAGES = ('fast', 'behavioral', 'landing')
VERIFY_MODES = ('gates', 'batch', 'unit')  # cheapest first
VERIFY_KINDS = ('sidekick', 'master')
LANDING_MODES = ('commit', 'branch', 'stack', 'pr')
REVIEW_STYLES = ('quick', 'standard', 'thorough')
NAME = re.compile(r'^[a-z][a-z0-9-]*$')


class ConfigError(Exception):
    pass


# Globs match repo-relative paths. `**` crosses directories, `*` and `?` do
# not, and a pattern never matches a basename alone: `*.py` is top-level only,
# `**/*.py` is everywhere.
def glob_regex(pattern: str) -> re.Pattern:
    out, i = '', 0
    while i < len(pattern):
        if pattern.startswith('**/', i):
            out, i = out + '(?:.*/)?', i + 3
        elif pattern.startswith('**', i):
            out, i = out + '.*', i + 2
        elif pattern[i] == '*':
            out, i = out + '[^/]*', i + 1
        elif pattern[i] == '?':
            out, i = out + '[^/]', i + 1
        else:
            out, i = out + re.escape(pattern[i]), i + 1
    return re.compile(out + r'\Z')


def matches(path: str, patterns: list[re.Pattern]) -> bool:
    return any(p.match(path) for p in patterns)


@dataclass
class Profile:
    name: str
    paths: list[str]
    commands: dict[str, list[str]]
    features: list[str]
    tests: list[str]
    require_tests: bool
    verify: str
    sample: float
    heavy: bool
    wrap: str | None
    path_res: list[re.Pattern] = field(default_factory=list)
    test_res: list[re.Pattern] = field(default_factory=list)


@dataclass
class Rule:
    id: str
    pattern: re.Pattern
    message: str
    paths: list[re.Pattern]
    source: str


@dataclass
class Kitchen:
    profiles: dict[str, Profile]
    escalate: dict
    rules: list[Rule]
    review: dict
    verify: dict
    landing: str
    coverage_ignore: list[re.Pattern]
    max_parallel_heavy: int
    wrap: str


def _check_keys(table: dict, where: str, allowed: set[str]) -> None:
    unknown = set(table) - allowed
    if unknown:
        raise ConfigError(f'{where}: unknown key {", ".join(sorted(unknown))}')


def _strings(value, where: str) -> list[str]:
    if not isinstance(value, list) or not all(isinstance(v, str) and v for v in value):
        raise ConfigError(f'{where}: expected a list of non-empty strings')
    return value


def _choice(value, where: str, choices: tuple[str, ...]) -> str:
    if value not in choices:
        raise ConfigError(f'{where}: expected one of {", ".join(choices)}, got {value!r}')
    return value


def _int(value, where: str, minimum: int = 0) -> int:
    if not isinstance(value, int) or isinstance(value, bool) or value < minimum:
        raise ConfigError(f'{where}: expected an integer >= {minimum}')
    return value


def _bool(value, where: str) -> bool:
    if not isinstance(value, bool):
        raise ConfigError(f'{where}: expected true or false')
    return value


def parse(data: dict) -> Kitchen:
    _check_keys(data, 'kitchen.toml', {'version', 'profile', 'escalate', 'policy', 'review',
                                       'verify', 'landing', 'coverage', 'resources', 'run'})
    if data.get('version') != 1:
        raise ConfigError('version: expected 1')
    raw_profiles = data.get('profile')
    if not isinstance(raw_profiles, dict) or not raw_profiles:
        raise ConfigError('profile: define at least one [profile.<name>]')
    profiles = {}
    for name, p in raw_profiles.items():
        where = f'profile.{name}'
        if not NAME.match(name):
            raise ConfigError(f'{where}: name must match {NAME.pattern}')
        _check_keys(p, where, {'paths', *STAGES, 'features', 'tests', 'require_tests',
                               'verify', 'sample', 'heavy', 'wrap'})
        wrap = p.get('wrap')
        if wrap is not None and not isinstance(wrap, str):
            raise ConfigError(f'{where}.wrap: expected a string ("" runs this profile unwrapped)')
        paths = _strings(p.get('paths'), f'{where}.paths')
        if not paths:
            raise ConfigError(f'{where}.paths: list at least one glob')
        sample = p.get('sample', 0.1)
        if not isinstance(sample, (int, float)) or isinstance(sample, bool) or not 0 <= sample <= 1:
            raise ConfigError(f'{where}.sample: expected a number from 0 to 1')
        tests = _strings(p.get('tests', []), f'{where}.tests')
        require_tests = _bool(p.get('require_tests', False), f'{where}.require_tests')
        if require_tests and not tests:
            raise ConfigError(f'{where}: require_tests needs tests globs')
        profiles[name] = Profile(
            name=name, paths=paths,
            commands={s: _strings(p.get(s, []), f'{where}.{s}') for s in STAGES},
            features=_strings(p.get('features', []), f'{where}.features'),
            tests=tests, require_tests=require_tests,
            verify=_choice(p.get('verify', 'batch'), f'{where}.verify', VERIFY_MODES),
            sample=float(sample), heavy=_bool(p.get('heavy', False), f'{where}.heavy'), wrap=wrap,
            path_res=[glob_regex(g) for g in paths], test_res=[glob_regex(g) for g in tests])

    escalate = data.get('escalate', {})
    _check_keys(escalate, 'escalate', {'paths', 'manifests', 'max_profiles', 'max_diff_lines', 'unmapped'})
    esc = {
        'paths': [glob_regex(g) for g in _strings(escalate.get('paths', []), 'escalate.paths')],
        'manifests': [glob_regex(g) for g in _strings(escalate.get('manifests', []), 'escalate.manifests')],
        'max_profiles': _int(escalate['max_profiles'], 'escalate.max_profiles', 1) if 'max_profiles' in escalate else None,
        'max_diff_lines': _int(escalate.get('max_diff_lines', 600), 'escalate.max_diff_lines', 1),
        'unmapped': _bool(escalate.get('unmapped', True), 'escalate.unmapped'),
    }

    policy = data.get('policy', {})
    _check_keys(policy, 'policy', {'forbid'})
    rules, seen = [], set()
    for i, r in enumerate(policy.get('forbid', [])):
        where = f'policy.forbid[{i}]'
        if not isinstance(r, dict):
            raise ConfigError(f'{where}: expected a table')
        _check_keys(r, where, {'id', 'pattern', 'message', 'paths', 'source'})
        rid = r.get('id')
        if not isinstance(rid, str) or not NAME.match(rid) or rid in seen:
            raise ConfigError(f'{where}.id: expected a unique name matching {NAME.pattern}')
        seen.add(rid)
        if not isinstance(r.get('message'), str) or not r['message']:
            raise ConfigError(f'{where}.message: say what to do instead')
        try:
            pattern = re.compile(r.get('pattern', ''))
        except re.error as e:
            raise ConfigError(f'{where}.pattern: {e}') from None
        if not r.get('pattern'):
            raise ConfigError(f'{where}.pattern: expected a regular expression')
        rules.append(Rule(rid, pattern, r['message'],
                          [glob_regex(g) for g in _strings(r.get('paths', ['**']), f'{where}.paths')],
                          str(r.get('source', ''))))

    review = data.get('review', {})
    _check_keys(review, 'review', {'engine', 'self', 'standards', 'max_batch_diff',
                                   'routine', 'escalated', 'landing'})
    rev = {
        'engine': _choice(review.get('engine', 'none'), 'review.engine', ('joo', 'none')),
        'self': _strings(review.get('self', []), 'review.self'),
        'standards': _strings(review.get('standards', []), 'review.standards'),
        'max_batch_diff': _int(review.get('max_batch_diff', 800), 'review.max_batch_diff', 1),
    }
    defaults = {'routine': ('standard', 4), 'escalated': ('thorough', 8), 'landing': ('quick', 4)}
    for cls, (style, budget) in defaults.items():
        t = review.get(cls, {})
        where = f'review.{cls}'
        _check_keys(t, where, {'style', 'budget', 'second_reviewer', 'walkthrough'})
        rev[cls] = {
            'style': _choice(t.get('style', style), f'{where}.style', REVIEW_STYLES),
            'budget': _int(t.get('budget', budget), f'{where}.budget', 1),
            'second_reviewer': _bool(t.get('second_reviewer', False), f'{where}.second_reviewer'),
            'walkthrough': _bool(t.get('walkthrough', cls == 'landing'), f'{where}.walkthrough'),
        }

    verify = data.get('verify', {})
    _check_keys(verify, 'verify', {'routine_kind', 'escalated_kind'})
    ver = {
        'routine_kind': _choice(verify.get('routine_kind', 'sidekick'), 'verify.routine_kind', VERIFY_KINDS),
        'escalated_kind': _choice(verify.get('escalated_kind', 'master'), 'verify.escalated_kind', VERIFY_KINDS),
    }

    landing = data.get('landing', {})
    _check_keys(landing, 'landing', {'mode'})
    coverage = data.get('coverage', {})
    _check_keys(coverage, 'coverage', {'ignore'})
    resources = data.get('resources', {})
    _check_keys(resources, 'resources', {'max_parallel_heavy'})
    run = data.get('run', {})
    _check_keys(run, 'run', {'wrap'})
    if not isinstance(run.get('wrap', ''), str):
        raise ConfigError('run.wrap: expected a string, such as "nix develop --command"')
    return Kitchen(
        profiles=profiles, escalate=esc, rules=rules, review=rev, verify=ver,
        landing=_choice(landing.get('mode', 'commit'), 'landing.mode', LANDING_MODES),
        coverage_ignore=[glob_regex(g) for g in _strings(coverage.get('ignore', []), 'coverage.ignore')],
        max_parallel_heavy=_int(resources.get('max_parallel_heavy', 1), 'resources.max_parallel_heavy', 1),
        wrap=run.get('wrap', ''))


# Fixed diff output whatever the user's git config says (mnemonicPrefix,
# noprefix, color, an external diff driver).
DIFF_OPTS = ('--no-renames', '--no-color', '--no-ext-diff', '--src-prefix=a/', '--dst-prefix=b/')


def git(root: Path, *args: str, check: bool = True) -> str:
    result = subprocess.run(['git', '-C', str(root), *args], capture_output=True, text=True, check=False)
    if check and result.returncode != 0:
        raise ConfigError(f'git {" ".join(args)}: {result.stderr.strip()}')
    return result.stdout


def repo_root(start: str | None) -> Path:
    try:
        out = subprocess.run(['git', '-C', start or '.', 'rev-parse', '--show-toplevel'],
                             capture_output=True, text=True, check=True).stdout
    except subprocess.CalledProcessError:
        raise ConfigError(f'not a git repository: {start or os.getcwd()}') from None
    return Path(out.strip())


# The kitchen at a revision, so a unit is verified against the rules it was
# built under; the working copy otherwise.
def load(root: Path, at: str | None, config: str | None) -> Kitchen:
    try:
        if at:
            text = git(root, 'show', f'{at}:{config or CONFIG}')
        else:
            text = (root / (config or CONFIG)).read_text()
    except (OSError, ConfigError):
        where = f'{at}:{config or CONFIG}' if at else str(root / (config or CONFIG))
        raise ConfigError(f'no kitchen at {where}; run the pstack-kitchen-setup skill') from None
    try:
        return parse(tomllib.loads(text))
    except tomllib.TOMLDecodeError as e:
        raise ConfigError(f'kitchen.toml: {e}') from None


def state_dir(root: Path) -> Path:
    base = Path(os.environ.get('XDG_STATE_HOME') or Path.home() / '.local/state')
    tag = hashlib.sha256(str(root).encode()).hexdigest()[:8]
    d = base / 'pstack/kitchen/repos' / f'{root.name}-{tag}'
    d.mkdir(parents=True, exist_ok=True)
    return d


def tracked(root: Path, at: str | None) -> list[str]:
    if at:
        return git(root, 'ls-tree', '-r', '--name-only', at).splitlines()
    return git(root, 'ls-files', '--cached', '--others', '--exclude-standard').splitlines()


# Changed files with added and removed line counts: a commit range, the
# working tree against HEAD (untracked files count as added), or a brief's
# Scope globs expanded against the tracked files.
def changes(root: Path, args) -> list[tuple[str, int, int]]:
    if args.paths:
        files = tracked(root, args.at)
        out, seen = [], set()
        for pattern in args.paths:
            rx = glob_regex(pattern)
            hits = [f for f in files if rx.match(f)] or ([pattern] if not any(c in pattern for c in '*?') else [])
            for f in hits:
                if f not in seen:
                    seen.add(f)
                    out.append((f, 0, 0))
        return out
    if args.working_tree:
        numstat = git(root, 'diff', *DIFF_OPTS, '--numstat', 'HEAD')
        extra = git(root, 'ls-files', '--others', '--exclude-standard').splitlines()
    else:
        if not args.base:
            raise ConfigError('give --base REV [--head REV], --working-tree, or --paths GLOB...')
        numstat = git(root, 'diff', *DIFF_OPTS, '--numstat', args.base, args.head or 'HEAD')
        extra = []
    out = []
    for line in numstat.splitlines():
        added, removed, path = line.split('\t', 2)
        out.append((path, int(added) if added != '-' else 0, int(removed) if removed != '-' else 0))
    for path in extra:
        try:
            n = len((root / path).read_text(errors='replace').splitlines())
        except OSError:
            n = 0
        out.append((path, n, 0))
    return out


def classify(kitchen: Kitchen, changed: list[tuple[str, int, int]]) -> dict:
    files, touched, unmapped, reasons = [], set(), [], []
    for path, added, removed in changed:
        hit = [p.name for p in kitchen.profiles.values() if matches(path, p.path_res)]
        files.append({'path': path, 'profiles': hit, 'added': added, 'removed': removed})
        touched.update(hit)
        if not hit and not matches(path, kitchen.coverage_ignore):
            unmapped.append(path)
        if matches(path, kitchen.escalate['paths']):
            reasons.append(f'escalate path: {path}')
        if matches(path, kitchen.escalate['manifests']):
            reasons.append(f'dependency manifest: {path}')
    diff_lines = sum(a + r for _, a, r in changed)
    esc = kitchen.escalate
    if esc['max_profiles'] is not None and len(touched) > esc['max_profiles']:
        reasons.append(f'{len(touched)} profiles touched: {", ".join(sorted(touched))} (max {esc["max_profiles"]})')
    if diff_lines > esc['max_diff_lines']:
        reasons.append(f'{diff_lines} diff lines (max {esc["max_diff_lines"]})')
    if unmapped and esc['unmapped']:
        reasons.append(f'{len(unmapped)} files no profile covers: {", ".join(unmapped[:5])}')
    risk = 'escalated' if reasons else 'routine'
    profiles = [kitchen.profiles[n] for n in sorted(touched)]
    if risk == 'escalated':
        verify = {'mode': 'unit', 'kind': kitchen.verify['escalated_kind']}
        sample = 1.0
    else:
        mode = max((p.verify for p in profiles), key=VERIFY_MODES.index, default='gates')
        verify = {'mode': mode, 'kind': kitchen.verify['routine_kind']}
        sample = max((p.sample for p in profiles), default=0.0)
    return {
        'risk': risk, 'escalate': reasons, 'profiles': sorted(touched), 'unmapped': unmapped,
        'diff_lines': diff_lines, 'verify': verify, 'sample': sample,
        'review': {'engine': kitchen.review['engine'], **kitchen.review[risk]},
        'features': sorted({f for p in profiles for f in p.features}),
        'files': files,
    }


# Heavy profiles share max_parallel_heavy slots across every kitchen on the
# machine, so a verifier's build never races the sidekick's.
def heavy_slot(root: Path, kitchen: Kitchen):
    lock_dir = state_dir(root).parent
    while True:
        for i in range(kitchen.max_parallel_heavy):
            f = open(lock_dir / f'heavy-{i}.lock', 'w')  # noqa: SIM115 - held open as the slot until the gate ends
            try:
                fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)
                return f
            except BlockingIOError:
                f.close()
        time.sleep(2)


# Global options that re-run this script inside a profile's wrap; set by main.
INVOCATION: list[str] = []
WRAPPED = 'KITCHEN_WRAPPED'


def wrap_of(kitchen: Kitchen, p: Profile) -> str:
    return kitchen.wrap if p.wrap is None else p.wrap


# A wrapped profile (a toolchain that exists only inside `nix develop` and the
# like) enters its wrap once per gate: this script re-runs itself inside it
# and writes its result to a file, since a wrap's shell hook may print to
# stdout. The outer run keeps the heavy slot.
def run_wrapped(root: Path, wrap: str, profile: str, stage: str, log_dir: Path,
                keep_going: bool, only: int | None) -> dict:
    result = log_dir / f'{profile}-{stage}-result.json'
    result.unlink(missing_ok=True)
    inner = [sys.executable, str(Path(__file__).resolve()), *INVOCATION, 'gate', profile, stage,
             '--log-dir', str(log_dir), '--result', str(result)]
    inner += ['--keep-going'] if keep_going else []
    inner += ['--only', str(only)] if only is not None else []
    log = log_dir / f'{profile}-{stage}-wrap.log'
    start = time.monotonic()
    with open(log, 'w') as out:
        code = subprocess.run(['bash', '-c', f'{wrap} {shlex.join(inner)}'], cwd=root, stdout=out,
                              stderr=subprocess.STDOUT, env={**os.environ, WRAPPED: '1'}, check=False).returncode
    if result.exists():
        return json.loads(result.read_text())
    tail = log.read_text(errors='replace').splitlines()[-20:]
    return {'profile': profile, 'stage': stage, 'passed': False, 'commands': [
        {'command': f'{wrap} (wrap)', 'exit': code or 1, 'seconds': round(time.monotonic() - start, 1),
         'log': str(log), 'tail': tail}]}


def run_gate(root: Path, kitchen: Kitchen, profile: str, stage: str, log_dir: Path | None,
             keep_going: bool = False, only: int | None = None, result: Path | None = None) -> dict:
    if profile not in kitchen.profiles:
        raise ConfigError(f'no profile {profile}; profiles: {", ".join(kitchen.profiles)}')
    p = kitchen.profiles[profile]
    commands = list(enumerate(p.commands[stage]))
    if only is not None:
        if not 0 <= only < len(commands):
            raise ConfigError(f'--only {only}: {profile}.{stage} has {len(commands)} commands, numbered from 0')
        commands = [commands[only]]
    log_dir = log_dir or state_dir(root) / 'logs' / time.strftime('%Y%m%dT%H%M%S')
    log_dir.mkdir(parents=True, exist_ok=True)
    inside = os.environ.get(WRAPPED) == '1'
    wrap = wrap_of(kitchen, p)
    if wrap and commands and not inside:
        slot = heavy_slot(root, kitchen) if p.heavy else None
        try:
            return run_wrapped(root, wrap, profile, stage, log_dir, keep_going, only)
        finally:
            if slot:
                slot.close()
    slot = heavy_slot(root, kitchen) if p.heavy and commands and not inside else None
    results = []
    try:
        for i, cmd in commands:
            log = log_dir / f'{profile}-{stage}-{i}.log'
            start = time.monotonic()
            with open(log, 'w') as out:
                code = subprocess.run(['bash', '-c', cmd], cwd=root, stdout=out, stderr=subprocess.STDOUT, check=False).returncode
            r = {'command': cmd, 'exit': code, 'seconds': round(time.monotonic() - start, 1), 'log': str(log)}
            if code != 0:
                r['tail'] = log.read_text(errors='replace').splitlines()[-20:]
            results.append(r)
            if code != 0 and not keep_going:
                break
    finally:
        if slot:
            slot.close()
    out = {'profile': profile, 'stage': stage, 'passed': all(r['exit'] == 0 for r in results), 'commands': results}
    if result:
        result.write_text(json.dumps(out))
    return out


ALLOW = re.compile(r'kitchen-allow:\s*([a-z0-9,\s-]+)')


# Added lines that break a forbid rule, unless the line carries
# `kitchen-allow: <id>` with the reason beside it; and profiles that require
# tests whose source changed with no test change.
def check_policy(root: Path, kitchen: Kitchen, args) -> list[dict]:
    if args.working_tree:
        diff = git(root, 'diff', *DIFF_OPTS, '-U0', 'HEAD')
    else:
        if not args.base:
            raise ConfigError('give --base REV [--head REV] or --working-tree')
        diff = git(root, 'diff', *DIFF_OPTS, '-U0', args.base, args.head or 'HEAD')
    findings, path, line_no = [], None, 0
    for line in diff.splitlines():
        if line.startswith('+++ '):
            path = line[6:] if line.startswith('+++ b/') else None
        elif line.startswith('@@'):
            m = re.search(r'\+(\d+)', line)
            line_no = int(m.group(1)) if m else 0
        elif line.startswith('+') and path:
            text = line[1:]
            allowed = {a.strip() for m in ALLOW.finditer(text) for a in m.group(1).split(',')}
            for rule in kitchen.rules:
                if rule.id not in allowed and matches(path, rule.paths) and rule.pattern.search(text):
                    findings.append({'rule': rule.id, 'path': path, 'line': line_no, 'text': text.strip()[:200],
                                     'message': rule.message, 'source': rule.source})
            line_no += 1
    if args.working_tree:
        changed = changes(root, argparse.Namespace(paths=None, working_tree=True, at=None))
    else:
        changed = changes(root, argparse.Namespace(paths=None, working_tree=False, at=None,
                                                   base=args.base, head=args.head))
    paths = [c[0] for c in changed]
    for p in kitchen.profiles.values():
        if not p.require_tests or any(matches(f, p.test_res) for f in paths):
            continue
        source = [f for f in paths if matches(f, p.path_res)]
        if source:
            findings.append({'rule': 'test-touch', 'profile': p.name, 'path': source[0], 'line': 0, 'text': '',
                             'message': f'profile {p.name} requires tests: {len(source)} source files changed '
                                        f'and no file matching {", ".join(p.tests)}', 'source': CONFIG})
    return findings


def first_word(cmd: str) -> str | None:
    for word in shlex.split(cmd, comments=True):
        if not re.match(r'^[A-Za-z_][A-Za-z0-9_]*=', word):
            return word
    return None


def shell_builtins() -> set[str]:
    out = subprocess.run(['bash', '-c', 'compgen -b; compgen -k'], capture_output=True, text=True, check=False).stdout
    return set(out.split())


def doctor(root: Path, kitchen: Kitchen, run: bool) -> list[dict]:
    checks = []
    builtins = shell_builtins()

    def add(name: str, status: str, detail: str = '', items: list | None = None):
        checks.append({'check': name, 'status': status, 'detail': detail, 'items': items or []})

    files = tracked(root, None)
    uncovered = [f for f in files
                 if not any(matches(f, p.path_res) for p in kitchen.profiles.values())
                 and not matches(f, kitchen.coverage_ignore)]
    add('coverage', 'fail' if uncovered else 'ok',
        f'{len(uncovered)} of {len(files)} files match no profile; add them to a profile or coverage.ignore'
        if uncovered else f'{len(files)} files covered', uncovered[:20])
    empty = [p.name for p in kitchen.profiles.values() if not any(matches(f, p.path_res) for f in files)]
    add('profiles', 'warn' if empty else 'ok',
        'profiles that match no file' if empty else f'{len(kitchen.profiles)} profiles match files', empty)
    # Each command's program must exist where it runs: on PATH or in the repo,
    # or, for a wrapped profile, inside its wrap, asked once per wrap.
    missing, inside = [], {}
    for p in kitchen.profiles.values():
        wrap = wrap_of(kitchen, p)
        for stage in STAGES:
            for cmd in p.commands[stage]:
                try:
                    word = first_word(cmd)
                except ValueError as e:
                    missing.append(f'{p.name}.{stage}: unparsable: {e}')
                    continue
                if not word or word in builtins or (root / word).exists():
                    continue
                if wrap:
                    inside.setdefault(wrap, {}).setdefault(word, []).append(f'{p.name}.{stage}')
                elif not shutil.which(word):
                    missing.append(f'{p.name}.{stage}: {word}')
    for wrap, words in inside.items():
        try:
            entry = first_word(wrap)
        except ValueError:
            entry = None
        if not entry or not (shutil.which(entry) or (root / entry).exists()):
            missing.append(f'wrap: {wrap}')
            continue
        probe = 'for w in "$@"; do command -v "$w" >/dev/null 2>&1 || echo "KITCHEN-MISSING:$w"; done'
        out = subprocess.run(['bash', '-c', f'{wrap} bash -c {shlex.quote(probe)} probe {shlex.join(words)}'],
                             cwd=root, capture_output=True, text=True, check=False)
        absent = re.findall(r'^KITCHEN-MISSING:(.+)$', out.stdout, re.MULTILINE)
        if out.returncode != 0 and not absent:
            missing.append(f'wrap: {wrap} exited {out.returncode}: {(out.stderr or out.stdout).strip()[-200:]}')
        missing += [f'{where}: {w} (inside wrap)' for w in absent for where in words[w]]
    add('commands', 'fail' if missing else 'ok',
        'commands whose program is not where it runs' if missing else 'every command resolves', missing)
    no_fast = [p.name for p in kitchen.profiles.values() if not p.commands['fast']]
    add('fast gates', 'warn' if no_fast else 'ok',
        'profiles with no fast gate: their steps run no check' if no_fast else 'every profile has a fast gate', no_fast)
    lost = [f'{p.name}: {f}' for p in kitchen.profiles.values() for f in p.features if not (root / f).exists()]
    listed = sum(len(p.features) for p in kitchen.profiles.values())
    add('features', 'fail' if lost else 'ok',
        'feature files that do not exist' if lost else f'{listed} feature files listed, all present', lost)
    skills = sorted(str(s.parent.relative_to(root)) for s in root.glob('.agents/skills/verify-*/SKILL.md'))
    behavioral = any(p.commands['behavioral'] for p in kitchen.profiles.values())
    if skills:
        add('verification skill', 'ok', ', '.join(skills))
    else:
        add('verification skill', 'warn' if behavioral else 'ok',
            'no .agents/skills/verify-*; run create-verification-skill' if behavioral
            else 'none, and no profile has behavioral commands')
    if kitchen.review['engine'] == 'joo':
        joo = shutil.which('joo-dev') or shutil.which('joo')
        add('review engine', 'ok' if joo else 'warn', joo or 'joo-dev and joo are not on PATH')
    if run:
        dirty = git(root, 'status', '--porcelain').strip()
        if dirty:
            add('baseline', 'warn', 'tree is dirty; the baseline ran on uncommitted changes')
        baseline, red = {}, []
        for p in kitchen.profiles.values():
            if not p.commands['fast']:
                continue
            print(f'doctor: {p.name} fast gate ({len(p.commands["fast"])} commands)...', file=sys.stderr, flush=True)
            g = run_gate(root, kitchen, p.name, 'fast', None, keep_going=True)
            print(f'doctor: {p.name} {"pass" if g["passed"] else "FAIL"} in '
                  f'{round(sum(c["seconds"] for c in g["commands"]), 1)}s', file=sys.stderr, flush=True)
            baseline[p.name] = {'passed': g['passed'], 'seconds': round(sum(c['seconds'] for c in g['commands']), 1)}
            if not g['passed']:
                red.append(f'{p.name}: ' + '; '.join(f'{c["command"]} exit {c["exit"]} ({c["log"]})'
                                                     for c in g['commands'] if c['exit']))
        head = git(root, 'rev-parse', 'HEAD', check=False).strip()
        path = state_dir(root) / 'baseline.json'
        path.write_text(json.dumps({'head': head, 'profiles': baseline}, indent=2) + '\n')
        add('fast gates on HEAD', 'fail' if red else 'ok',
            'red before any change: fix or record why' if red else f'all green; timings in {path}', red)
    return checks


# How the kitchen would have classified each of the last commits, and which
# policy findings each one adds: a draft kitchen tested against changes the
# repo already accepted. Merge commits are skipped.
def history(root: Path, kitchen: Kitchen, last: int) -> list[dict]:
    revs = git(root, 'rev-list', '--no-merges', f'--max-count={last}', 'HEAD').split()
    rows = []
    for rev in revs:
        parent = git(root, 'rev-parse', '--verify', '--quiet', f'{rev}~1', check=False).strip()
        if not parent:
            continue
        ns = argparse.Namespace(paths=None, working_tree=False, at=None, base=parent, head=rev)
        r = classify(kitchen, changes(root, ns))
        findings = check_policy(root, kitchen, ns)
        rows.append({'rev': rev[:9], 'subject': git(root, 'log', '-1', '--format=%s', rev).strip(),
                     'risk': r['risk'], 'profiles': r['profiles'], 'escalate': r['escalate'],
                     'diff_lines': r['diff_lines'],
                     'findings': [f['rule'] + (f'({f["profile"]})' if 'profile' in f else '') for f in findings]})
    return rows


def emit(obj, as_json: bool, text: str) -> None:
    print(json.dumps(obj, indent=2) if as_json else text)


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(prog='kitchen.py', description=__doc__.split('\n\n')[0])
    ap.add_argument('--repo', help='repository (default: the current directory)')
    ap.add_argument('--config', help=f'kitchen file relative to the repo (default {CONFIG})')
    ap.add_argument('--at', help='read the kitchen (and, for --paths, the files) at this revision')
    ap.add_argument('--json', action='store_true', help='machine-readable output')
    sub = ap.add_subparsers(dest='cmd', required=True)
    sub.add_parser('validate', help='parse and check kitchen.toml')
    c = sub.add_parser('classify', help='profiles, risk class, and verify/review settings for a change')
    p = sub.add_parser('policy', help='forbid rules on added lines, and test-touch')
    for s in (c, p):
        s.add_argument('--base')
        s.add_argument('--head')
        s.add_argument('--working-tree', action='store_true')
    c.add_argument('--paths', nargs='+', metavar='GLOB', help="a brief's Scope, expanded against tracked files")
    g = sub.add_parser('gate', help="run one profile's commands for a stage")
    g.add_argument('profile')
    g.add_argument('stage', choices=STAGES)
    g.add_argument('--log-dir', type=Path)
    g.add_argument('--keep-going', action='store_true', help='run every command after a failure')
    g.add_argument('--only', type=int, metavar='N', help='run only command N, counted from 0')
    g.add_argument('--result', type=Path, help=argparse.SUPPRESS)
    h = sub.add_parser('history', help='classify and policy-check each of the last commits')
    h.add_argument('--last', type=int, default=20)
    d = sub.add_parser('doctor', help='check the kitchen against the repo')
    d.add_argument('--run', action='store_true', help='also run every fast gate on HEAD and record a baseline')
    args = ap.parse_args(argv)

    try:
        root = repo_root(args.repo)
        kitchen = load(root, args.at, args.config)
        INVOCATION[:] = ['--repo', str(root)] + (['--config', args.config] if args.config else []) \
            + (['--at', args.at] if args.at else [])
        if args.cmd == 'validate':
            emit({'ok': True, 'profiles': list(kitchen.profiles)}, args.json,
                 f'ok: {len(kitchen.profiles)} profiles ({", ".join(kitchen.profiles)})')
            return 0
        if args.cmd == 'classify':
            if not args.paths:
                args.paths = None
            r = classify(kitchen, changes(root, args))
            text = [f'risk: {r["risk"]}', f'profiles: {", ".join(r["profiles"]) or "none"}',
                    f'diff_lines: {r["diff_lines"]}',
                    f'verify: {r["verify"]["mode"]} by {r["verify"]["kind"]}', f'sample: {r["sample"]}',
                    f'review: {r["review"]["engine"]} {r["review"]["style"]} budget {r["review"]["budget"]}']
            text += [f'escalate: {x}' for x in r['escalate']]
            text += [f'unmapped: {x}' for x in r['unmapped']]
            emit(r, args.json, '\n'.join(text))
            return 0
        if args.cmd == 'gate':
            r = run_gate(root, kitchen, args.profile, args.stage, args.log_dir, args.keep_going, args.only, args.result)
            lines = [f'{args.profile} {args.stage}: {"pass" if r["passed"] else "FAIL"}'
                     + ('' if r['commands'] else ' (no commands)')]
            for x in r['commands']:
                lines.append(f'  exit {x["exit"]} {x["seconds"]}s {x["command"]}  log: {x["log"]}')
                lines += [f'    | {t}' for t in x.get('tail', [])]
            emit(r, args.json, '\n'.join(lines))
            return 0 if r['passed'] else 2
        if args.cmd == 'policy':
            f = check_policy(root, kitchen, args)
            emit({'findings': f}, args.json, '\n'.join(
                [f'{x["path"]}' + (f':{x["line"]}' if x['line'] else '') + f': [{x["rule"]}] {x["message"]}' + (f'  ({x["source"]})' if x['source'] else '')
                 + (f'\n    {x["text"]}' if x['text'] else '') for x in f] or ['policy: clean']))
            return 2 if f else 0
        if args.cmd == 'history':
            rows = history(root, kitchen, args.last)
            lines = [f'{r["rev"]} {r["risk"]:9} {",".join(r["profiles"]) or "-":24} {r["diff_lines"]:>6}  {r["subject"][:60]}'
                     + ''.join(f'\n{"":20}escalate: {x}' for x in r['escalate'])
                     + (f'\n{"":20}policy: {", ".join(r["findings"])}' if r['findings'] else '') for r in rows]
            n = sum(r['risk'] == 'escalated' for r in rows)
            lines.append(f'{n} of {len(rows)} escalated; {sum(bool(r["findings"]) for r in rows)} with policy findings')
            emit({'commits': rows}, args.json, '\n'.join(lines))
            return 0
        if args.cmd == 'doctor':
            checks = doctor(root, kitchen, args.run)
            lines = []
            for x in checks:
                lines.append(f'{x["status"]:4} {x["check"]}: {x["detail"]}')
                lines += [f'       {i}' for i in x['items']]
            emit({'checks': checks}, args.json, '\n'.join(lines))
            return 3 if any(x['status'] == 'fail' for x in checks) else 0
    except ConfigError as e:
        print(f'kitchen: {e}', file=sys.stderr)
        return 1
    return 1


if __name__ == '__main__':
    sys.exit(main())
