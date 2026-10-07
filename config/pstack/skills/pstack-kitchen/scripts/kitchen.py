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
import tempfile
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
    # Who verifies moved to the host roster; the keys still parse so older repos validate.
    ver = {k: _choice(v, f'verify.{k}', VERIFY_KINDS) for k, v in verify.items()}

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


# One state directory per repository, keyed by its git common dir, so a
# worktree (a verifier's scratch, a jj workspace) shares the main checkout's
# ledger and logs instead of leaving a directory of its own. A ledger kept
# under the older per-checkout key is copied over once.
def state_dir(root: Path) -> Path:
    base = Path(os.environ.get('XDG_STATE_HOME') or Path.home() / '.local/state') / 'pstack/kitchen/repos'
    common = git(root, 'rev-parse', '--path-format=absolute', '--git-common-dir', check=False).strip()
    main = Path(common).parent if common else root
    d = base / f'{main.name}-{hashlib.sha256(str(main).encode()).hexdigest()[:8]}'
    d.mkdir(parents=True, exist_ok=True)
    old = base / f'{root.name}-{hashlib.sha256(str(root).encode()).hexdigest()[:8]}'
    if old != d and (old / 'ledger.tsv').exists() and not (d / 'ledger.tsv').exists():
        shutil.copy2(old / 'ledger.tsv', d / 'ledger.tsv')
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
        args.outside = []
        for pattern in args.paths:
            # An absolute path is repo-relative when it is inside the repo;
            # outside it (the run's own store, a report) it is bookkeeping that
            # no gate covers and no rule escalates.
            if pattern.startswith('/'):
                try:
                    pattern = str(Path(pattern).relative_to(root))
                except ValueError:
                    args.outside.append(pattern)
                    continue
            rx = glob_regex(pattern)
            # A glob for files that do not exist yet stands for one file it
            # would match, so a new directory still maps to its profile.
            hits = [f for f in files if rx.match(f)] or [re.sub(r'\*\*/?|[*?]', 'x', pattern)]
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
        # From the merge-base: a range whose base was rewritten (a squash, a
        # rebase) still covers every change since the histories forked, not
        # only the difference between two trees.
        numstat = git(root, 'diff', *DIFF_OPTS, '--numstat', f"{args.base}...{args.head or 'HEAD'}")
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


def classify(kitchen: Kitchen, changed: list[tuple[str, int, int]], outside: list[str] | None = None) -> dict:
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
        verify = {'mode': 'unit', 'kind': 'escalated'}
        sample = 1.0
    else:
        mode = max((p.verify for p in profiles), key=VERIFY_MODES.index, default='gates')
        verify = {'mode': mode, 'kind': 'routine'}
        sample = max((p.sample for p in profiles), default=0.0)
    return {
        'risk': risk, 'escalate': reasons, 'profiles': sorted(touched), 'unmapped': unmapped,
        'diff_lines': diff_lines, 'verify': verify, 'sample': sample,
        'review': {'engine': kitchen.review['engine'], **kitchen.review[risk]},
        'features': sorted({f for p in profiles for f in p.features}),
        'behavioral': [p.name for p in profiles if p.commands['behavioral']],
        'max_batch_diff': kitchen.review['max_batch_diff'],
        'files': files,
        'outside': outside or [],
        'bookkeeping': not changed and bool(outside),
    }


def acquire_slot(lock_dir: Path, prefix: str, slots: int):
    """Holds one of `slots` machine-wide locks named <prefix>-<i>.lock; returns
    the open file and the seconds spent waiting for it."""
    start = time.monotonic()
    while True:
        for i in range(slots):
            f = open(lock_dir / f'{prefix}-{i}.lock', 'w')  # noqa: SIM115 - held open as the slot until the gate ends
            try:
                fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)
                return f, round(time.monotonic() - start, 1)
            except BlockingIOError:
                f.close()
        time.sleep(2)


# Heavy profiles share max_parallel_heavy slots across every kitchen on the
# machine, so a verifier's build never races the sidekick's.
def heavy_slot(root: Path, kitchen: Kitchen):
    return acquire_slot(state_dir(root).parent, 'heavy', kitchen.max_parallel_heavy)[0]


# Every gate takes one of the machine's gate slots, shared by all kitchens on
# it, so two runs queue their test suites instead of running them at once and
# slowing both past the per-step budget. The size is the host's: [machine]
# gate_slots in the roster, else PSTACK_KITCHEN_GATE_SLOTS, else one slot per
# eight cores.
def machine_gate_slots() -> int:
    env = os.environ.get('PSTACK_KITCHEN_GATE_SLOTS')
    if env:
        return max(1, int(env))
    path = Path(os.environ.get('PSTACK_KITCHEN_ROSTER') or Path.home() / '.config/pstack/kitchen.toml')
    try:
        slots = tomllib.loads(path.read_text()).get('machine', {}).get('gate_slots')
    except (OSError, tomllib.TOMLDecodeError):
        slots = None
    return max(1, int(slots)) if slots else max(1, (os.cpu_count() or 8) // 8)


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
                keep_going: bool, only: int | None, role: str) -> dict:
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
                              stderr=subprocess.STDOUT, env={**os.environ, WRAPPED: '1', ROLE: role}, check=False).returncode
    if result.exists():
        return json.loads(result.read_text())
    tail = log.read_text(errors='replace').splitlines()[-20:]
    return {'profile': profile, 'stage': stage, 'passed': False, 'commands': [
        {'command': f'{wrap} (wrap)', 'exit': code or 1, 'seconds': round(time.monotonic() - start, 1),
         'log': str(log), 'tail': tail}]}


# Every command sees PSTACK_KITCHEN_ROLE (sidekick or verifier), so a repo's
# scripts can give each role its own ports, emulators, and data: a verifier
# and the sidekick run at the same time on one machine.
ROLE = 'PSTACK_KITCHEN_ROLE'
ROLES = ('sidekick', 'verifier')
# The commit a step or unit is checked against, so an affected-only command
# covers every commit of a multi-commit step (turbo --filter=...[$BASE]).
BASE = 'PSTACK_KITCHEN_STEP_BASE'



def gate_tmp_base() -> Path:
    """Where gate TMPDIRs go: short, so sockets nested under them fit."""
    env = os.environ.get('PSTACK_KITCHEN_GATE_TMP')
    if env:
        return Path(env)
    # macOS's own $TMPDIR (/var/folders/...) is already ~50 bytes deep.
    return Path('/tmp') if os.access('/tmp', os.W_OK) else Path(tempfile.gettempdir())


def sweep_gate_tmp(base: Path) -> None:
    """Remove TMPDIRs of gates that died without cleaning up (kill -9)."""
    for d in base.glob('kg-*-*'):
        try:
            pid = int(d.name.split('-')[1])
            if d.stat().st_uid != os.getuid():
                continue
            os.kill(pid, 0)
        except ProcessLookupError:
            shutil.rmtree(d, ignore_errors=True)
        except (ValueError, OSError):
            continue


def run_gate(root: Path, kitchen: Kitchen, profile: str, stage: str, log_dir: Path | None,
             keep_going: bool = False, only: int | None = None, result: Path | None = None,
             role: str | None = None, base: str | None = None) -> dict:
    role = role or os.environ.get(ROLE) or 'sidekick'
    if base:
        sha = git(root, 'rev-parse', '--verify', '--quiet', f'{base}^{{commit}}', check=False).strip()
        if not sha:
            raise ConfigError(f'--base {base} is not a commit')
        os.environ[BASE] = sha
    if role not in ROLES:
        raise ConfigError(f'role must be sidekick or verifier, not {role}')
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
    # Each gate gets its own TMPDIR, removed when it ends. Tools and `nix
    # develop` (which makes a nix-shell.* directory there and never removes it
    # after --command) otherwise left hundreds of directories in /tmp: 6 GB in
    # two days of one kitchen. The path stays short: tools nest unix sockets
    # under it (mbx: nix-shell.*/mbx-session-*/cache-agent.sock), and a socket
    # path has 104-108 bytes.
    tmp = None
    if commands and not inside:
        base = gate_tmp_base()
        sweep_gate_tmp(base)
        tmp = tempfile.mkdtemp(prefix=f'kg-{os.getpid()}-', dir=base)
        os.environ['TMPDIR'] = tmp
    try:
        out = _run_gate(root, kitchen, p, profile, stage, commands, log_dir, keep_going, only, result, role,
                        inside, wrap)
    finally:
        if tmp:
            shutil.rmtree(tmp, ignore_errors=True)
    if commands and not inside and only is None:
        record_timing(root, profile, stage, role, out)
    return out


TIMINGS = 'timings.tsv'


def record_timing(root: Path, profile: str, stage: str, role: str, g: dict) -> None:
    """One row per whole gate run, so verify can size its timeout."""
    secs = round(sum(c['seconds'] for c in g['commands']), 1)
    row = [str(int(time.time())), profile, stage, role, 'pass' if g['passed'] else 'fail', str(secs)]
    try:
        with open(state_dir(root) / TIMINGS, 'a') as f:
            f.write('\t'.join(row) + '\n')
    except OSError:
        pass


def gate_timing(root: Path, profiles: list[str], stage: str, last: int = 10) -> dict:
    """The slowest of each profile's last passing runs of a stage, and their sum:
    a verifier runs the profiles one after another."""
    runs: dict[str, list[float]] = {p: [] for p in profiles}
    path = state_dir(root) / TIMINGS
    if path.exists():
        for line in path.read_text().splitlines():
            f = line.split('\t')
            if len(f) == 6 and f[1] in runs and f[2] == stage and f[4] == 'pass':
                runs[f[1]].append(float(f[5]))
    slowest = {p: max(r[-last:]) for p, r in runs.items() if r}
    return {'stage': stage, 'profiles': slowest, 'seconds': round(sum(slowest.values()), 1),
            'unmeasured': [p for p in profiles if p not in slowest]}


def _run_gate(root: Path, kitchen: Kitchen, p: Profile, profile: str, stage: str, commands: list, log_dir: Path,
              keep_going: bool, only: int | None, result: Path | None, role: str, inside: bool, wrap: str) -> dict:
    pool, waited = (None, 0.0)
    if commands and not inside:
        slots = machine_gate_slots()
        pool, waited = acquire_slot(state_dir(root).parent, 'gate', slots)
        if waited >= 2:
            print(f'kitchen: waited {waited:.0f}s for one of {slots} machine gate slots', file=sys.stderr)
    if wrap and commands and not inside:
        slot = heavy_slot(root, kitchen) if p.heavy else None
        try:
            out = run_wrapped(root, wrap, profile, stage, log_dir, keep_going, only, role)
            out['waited'] = waited
            return out
        finally:
            if slot:
                slot.close()
            pool.close()
    slot = heavy_slot(root, kitchen) if p.heavy and commands and not inside else None
    results = []
    try:
        for i, cmd in commands:
            log = log_dir / f'{profile}-{stage}-{i}.log'
            start = time.monotonic()
            code = run_command(root, cmd, log, role)
            r = {'command': cmd, 'exit': code, 'seconds': round(time.monotonic() - start, 1), 'log': str(log)}
            load = overloaded() if code != 0 else None
            if load is not None:
                # A suite that times out on a loaded machine is not a broken
                # change: it gets one rerun, recorded as flaky when it passes.
                first = log.with_name(f'{log.stem}.first.log')
                log.rename(first)
                code = run_command(root, cmd, log, role)
                r.update(exit=code, seconds=round(time.monotonic() - start, 1),
                         retried={'load': load, 'first_exit': r['exit'], 'first_log': str(first)}, flaky=code == 0)
            if code != 0:
                r['tail'] = log.read_text(errors='replace').splitlines()[-20:]
            results.append(r)
            if code != 0 and not keep_going:
                break
    finally:
        if slot:
            slot.close()
        if pool:
            pool.close()
    out = {'profile': profile, 'stage': stage, 'role': role, 'passed': all(r['exit'] == 0 for r in results),
           'commands': results, 'waited': waited}
    if result:
        result.write_text(json.dumps(out))
    return out


def run_command(root: Path, cmd: str, log: Path, role: str) -> int:
    with open(log, 'w') as out:
        return subprocess.run(['bash', '-c', cmd], cwd=root, stdout=out, stderr=subprocess.STDOUT,
                              env={**os.environ, ROLE: role}, check=False).returncode


def overloaded() -> float | None:
    """The one-minute load when it is over PSTACK_KITCHEN_RETRY_LOAD per core
    (default 1.0; `off` never retries), else None."""
    limit = os.environ.get('PSTACK_KITCHEN_RETRY_LOAD', '1.0')
    if limit == 'off':
        return None
    try:
        load = os.getloadavg()[0]
    except OSError:
        return None
    return round(load, 1) if load > float(limit) * (os.cpu_count() or 1) else None


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
        diff = git(root, 'diff', *DIFF_OPTS, '-U0', f"{args.base}...{args.head or 'HEAD'}")
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


# Which agents fill the roles is the host's choice, not the repo's, so it
# lives beside the other host preferences, outside every repo.
def _entry(t: dict, source: str) -> dict:
    fb = t.get('fallback')
    return {'kind': t.get('kind', ''), 'args': [str(a) for a in t.get('args', [])],
            'fallback': {'kind': fb.get('kind', ''), 'args': [str(a) for a in fb.get('args', [])]} if fb else None,
            'source': source}


def roster(as_json: bool) -> int:
    path = Path(os.environ.get('PSTACK_KITCHEN_ROSTER') or Path.home() / '.config/pstack/kitchen.toml')
    data = tomllib.loads(path.read_text()) if path.exists() else {}
    out = {}
    for role in ('sidekick', 'consultant'):
        t = data.get(role, {})
        out[role] = {'kind': t.get('kind', ''), 'args': [str(a) for a in t.get('args', [])]}
        if role == 'sidekick':
            fb = t.get('fallback', {})
            out[role]['fallback'] = {'kind': fb.get('kind', ''), 'args': [str(a) for a in fb.get('args', [])]}
    # A routine verifier without an entry is the run's current sidekick, which only
    # the store knows, so the entry is a marker that cmd_verify resolves.
    v = data.get('verifier', {})
    esc = v.get('escalated')
    out['verifier'] = {
        'routine': _entry(v, 'roster') if v.get('kind') else {'kind': 'sidekick', 'args': [], 'fallback': None, 'source': 'sidekick'},
        'escalated': _entry(esc, 'roster') if esc and esc.get('kind') else
        {'kind': 'claude', 'args': ['--model', 'claude-opus-5-5'], 'fallback': None, 'source': 'default'},
    }
    emit(out, as_json, f'{path}: ' + ', '.join(f'{r} {v["kind"] or "unset"}' for r, v in out.items() if 'kind' in v)
         + f', verifier {out["verifier"]["routine"]["kind"]}/{out["verifier"]["escalated"]["kind"]}')
    return 0


def _header(path: Path, key: str) -> str:
    try:
        for line in path.read_text().splitlines():
            if line.startswith(f'{key}:'):
                return line[len(key) + 1:].strip()
    except OSError:
        pass
    return ''


def _json(path: Path) -> dict:
    try:
        data = json.loads(path.read_text())
    except (OSError, ValueError):
        return {}
    return data if isinstance(data, dict) else {}


def pstack_state() -> Path:
    return Path(os.environ.get('XDG_STATE_HOME') or Path.home() / '.local/state') / 'pstack'


def build_revs() -> dict[str, str]:
    """skills path -> flake rev, from the switch's builds.tsv (the last row of a path wins)."""
    revs = {}
    try:
        for line in (pstack_state() / 'builds.tsv').read_text().splitlines():
            cols = line.split('\t')
            if len(cols) >= 3:
                revs[cols[2]] = cols[1]
    except OSError:
        pass
    return revs


def repo_label(git_root: str) -> str:
    """The repo's name, not its worktree's: a bare repo's common dir is its own name."""
    if not git_root:
        return ''
    r = subprocess.run(['git', '-C', git_root, 'rev-parse', '--path-format=absolute', '--git-common-dir'],
                       capture_output=True, text=True, check=False)
    common = Path(r.stdout.strip()) if r.returncode == 0 and r.stdout.strip() else None
    if common is None:
        return Path(git_root).name
    return common.parent.name if common.name == '.git' else common.name.removesuffix('.git')


def run_counters(store: Path) -> dict:
    """One run's counters, read-only. Every file is optional: an older or partial store gives zeros."""
    pair = _json(store / 'pair.json')
    events = []
    try:
        events = [line.split('\t') for line in (store / 'events.tsv').read_text().splitlines()[1:]]
    except OSError:
        pass
    events = [e + [''] * (6 - len(e)) for e in events]
    done = 0
    for brief in sorted((store / 'briefs').glob('[0-9][0-9][0-9]-*.md')):
        report = store / 'reports' / (re.sub(r'-a\d+$', '', brief.stem) + '.md')
        done += _header(report, 'status') == 'done'
    verified: set[str] = set()
    gates_only: set[str] = set()
    clean_first = 0
    landing = None
    for v in sorted((store / 'verdicts').glob('*-v[0-9]*.md')):
        if v.stem.endswith('-packet') or 'packet' in v.name:
            continue
        status = _header(v, 'status')
        ok = status.startswith('clean')
        if v.name.startswith('landing-'):
            landing = status.split(' ')[0] or None
            continue
        if ok:
            units = _header(v, 'units').split()
            verified.update(units)
            if 'gates only' in status:
                gates_only.update(units)
            clean_first += v.stem.endswith('-v1')
    wakes = sum(e[2] == 'master' and e[3] == 'wake' for e in events)
    catches: dict[str, int] = {}
    for e in events:
        if e[3] == 'catch':
            catches[e[5]] = catches.get(e[5], 0) + 1
    paths = [b.get('path') for b in pair.get('skill_builds') or [] if isinstance(b, dict) and b.get('path')]
    revs = build_revs()
    if len(set(paths)) > 1:
        build = 'mixed'
    elif paths:
        build = revs.get(paths[0], 'unknown')
    else:
        build = 'unknown'
    failovers = pair.get('sidekick', {}).get('failovers') if isinstance(pair.get('sidekick'), dict) else None
    return {
        'run': store.name, 'repo': repo_label(pair.get('git_root') or ''), 'build': build,
        'started': int(events[0][1]) if events and events[0][1].isdigit() else None,
        'last': int(events[-1][1]) if events and events[-1][1].isdigit() else None,
        'done_units': done, 'verified_units': len(verified), 'gates_only_units': len(gates_only),
        'clean_first_try': clean_first, 'landing': landing, 'wakes': wakes,
        'wakes_per_verified': round(wakes / len(verified), 1) if verified else None,
        'failovers': len(failovers) if isinstance(failovers, list) else 0,
        'escalations': sum(e[3] == 'escalate' for e in events),
        'verify_missing': sum(e[5] == 'verify:missing' for e in events),
        'verify_provider': sum(e[5] == 'verify:provider' for e in events),
        'gate_flaky': sum(e[3] == 'gate-flaky' for e in events),
        'catches': catches, 'steers': len(list((store / 'steers').glob('*-s[0-9]*.md'))),
    }


def open_feedback() -> dict[str, int]:
    """store path -> open feedback reports filed from it."""
    out: dict[str, int] = {}
    for f in (pstack_state() / 'feedback/inbox').glob('*.md'):
        if (f.parent.parent / 'done' / f.name).exists():
            continue
        m = re.search(r'store: (\S+)', _header(f, 'run'))
        if m:
            out[m.group(1)] = out.get(m.group(1), 0) + 1
    return out


def fleet(runs_dir: Path, since: str | None, as_json: bool) -> int:
    """Every kitchen run on the host and each skills build, read-only (it never runs retro)."""
    rows = []
    fb = open_feedback()
    for store in sorted(p for p in runs_dir.glob('*') if p.is_dir()):
        c = run_counters(store)
        c['open_feedback'] = fb.get(str(store), 0)
        if since and (c['started'] is None or time.strftime('%Y-%m-%d', time.gmtime(c['started'])) < since):
            continue
        rows.append(c)
    rows.sort(key=lambda r: (r['started'] is None, r['started'] or 0, r['run']))
    builds: dict[str, dict] = {}
    for r in rows:
        b = builds.setdefault(r['build'], {'build': r['build'], 'runs': 0, 'wakes_per_verified': [], 'failovers': 0, 'provider_stops': 0})
        b['runs'] += 1
        b['failovers'] += r['failovers']
        b['provider_stops'] += r['verify_provider']
        if r['wakes_per_verified'] is not None:
            b['wakes_per_verified'].append(r['wakes_per_verified'])
    brows = []
    for b in builds.values():
        w = b.pop('wakes_per_verified')
        b['mean_wakes_per_verified'] = round(sum(w) / len(w), 1) if w else None
        b['eligible_runs'] = len(w)
        b['failovers_per_run'] = round(b['failovers'] / b['runs'], 1)
        b['provider_stops_per_run'] = round(b['provider_stops'] / b['runs'], 1)
        brows.append(b)

    def when(t):
        return time.strftime('%Y-%m-%d %H:%M', time.gmtime(t)) if t else '-'

    def num(x):
        return '-' if x is None else str(x)
    lines = [f'{"run":24} {"repo":14} {"build":9} {"started":16} {"last":16} {"done":>4} {"ver":>3} {"gates":>5} {"land":6} '
             + f'{"wakes":>5} {"w/ver":>5} {"fo":>2} {"miss":>4} {"prov":>4} {"flaky":>5} {"steer":>5} {"fb":>2}  catches']
    for r in rows:
        lines.append(f'{r["run"][:24]:24} {r["repo"][:14]:14} {r["build"][:9]:9} {when(r["started"]):16} {when(r["last"]):16} '
                     f'{r["done_units"]:>4} {r["verified_units"]:>3} {r["gates_only_units"]:>5} {num(r["landing"]):6} {r["wakes"]:>5} '
                     f'{num(r["wakes_per_verified"]):>5} {r["failovers"]:>2} {r["verify_missing"]:>4} {r["verify_provider"]:>4} '
                     f'{r["gate_flaky"]:>5} {r["steers"]:>5} {r["open_feedback"]:>2}  '
                     f'{",".join(f"{k}:{v}" for k, v in sorted(r["catches"].items())) or "-"}')
    lines.append('')
    lines.append(f'{"build":9} {"runs":>4} {"eligible":>8} {"mean w/ver":>10} {"fo/run":>6} {"prov/run":>8}')
    for b in brows:
        lines.append(f'{b["build"][:9]:9} {b["runs"]:>4} {b["eligible_runs"]:>8} {num(b["mean_wakes_per_verified"]):>10} '
                     f'{b["failovers_per_run"]:>6} {b["provider_stops_per_run"]:>8}')
    emit({'runs': rows, 'builds': brows}, as_json, '\n'.join(lines))
    return 0


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
    g.add_argument('--base', metavar='REV', help=f'exported as {BASE}: the commit the change is checked against')
    g.add_argument('--role', choices=('sidekick', 'verifier'),
                   help='exported as PSTACK_KITCHEN_ROLE (default: that variable, else sidekick)')
    h = sub.add_parser('history', help='classify and policy-check each of the last commits')
    h.add_argument('--last', type=int, default=20)
    d = sub.add_parser('doctor', help='check the kitchen against the repo')
    d.add_argument('--run', action='store_true', help='also run every fast gate on HEAD and record a baseline')
    rs = sub.add_parser('review-settings', help='style budget second_reviewer walkthrough for a review class')
    rs.add_argument('cls', choices=('routine', 'escalated', 'landing'))
    sub.add_parser('roster', help='the host roster: which agents fill the roles (no repo needed)')
    f = sub.add_parser('fleet', help='every run on the host and each skills build (no repo needed, read-only)')
    f.add_argument('--since', metavar='YYYY-MM-DD', help='only runs that started on or after this date')
    f.add_argument('--runs', type=Path, help='runs directory (default: the host kitchen runs)')
    c = sub.add_parser('counters', help="one run store's counters as JSON (no repo needed, read-only)")
    c.add_argument('store', type=Path)
    sub.add_parser('statedir', help="this repo's kitchen state directory")
    t = sub.add_parser('timing', help="the slowest recent passing run of each profile's stage, and their sum")
    t.add_argument('profiles', nargs='*')
    t.add_argument('--stage', choices=STAGES, default='behavioral')
    args = ap.parse_args(argv)

    if args.cmd == 'roster':
        return roster(args.json)
    if args.cmd == 'fleet':
        return fleet(args.runs or pstack_state() / 'kitchen/runs', args.since, args.json)
    if args.cmd == 'counters':
        print(json.dumps(run_counters(args.store)))
        return 0
    try:
        if args.cmd == 'statedir':
            print(state_dir(repo_root(args.repo)))
            return 0
        root = repo_root(args.repo)
        if args.cmd == 'timing':
            r = gate_timing(root, args.profiles, args.stage)
            emit(r, args.json, f'{args.stage}: {r["seconds"]}s'
                 + ''.join(f'\n  {p} {s}s' for p, s in r['profiles'].items())
                 + (f'\n  unmeasured: {", ".join(r["unmeasured"])}' if r['unmeasured'] else ''))
            return 0
        kitchen = load(root, args.at, args.config)
        INVOCATION[:] = ['--repo', str(root)] + (['--config', args.config] if args.config else []) \
            + (['--at', args.at] if args.at else [])
        if kitchen.verify and args.cmd in ('validate', 'doctor'):
            print(f'kitchen: warning: [verify] {", ".join(sorted(kitchen.verify))} moved to the host roster\'s '
                  '[verifier]; remove it from kitchen.toml', file=sys.stderr)
        if args.cmd == 'review-settings':
            r = kitchen.review[args.cls]
            print(r['style'], r['budget'], str(r['second_reviewer']).lower(), str(r['walkthrough']).lower())
            return 0
        if args.cmd == 'validate':
            emit({'ok': True, 'profiles': list(kitchen.profiles), 'self': kitchen.review['self'],
                  'landing': kitchen.landing}, args.json,
                 f'ok: {len(kitchen.profiles)} profiles ({", ".join(kitchen.profiles)})')
            return 0
        if args.cmd == 'classify':
            if not args.paths:
                args.paths = None
            changed = changes(root, args)
            r = classify(kitchen, changed, getattr(args, 'outside', []))
            text = [f'risk: {r["risk"]}', f'profiles: {", ".join(r["profiles"]) or "none"}',
                    f'diff_lines: {r["diff_lines"]}',
                    f'verify: {r["verify"]["mode"]} by {r["verify"]["kind"]} verifier', f'sample: {r["sample"]}',
                    f'review: {r["review"]["engine"]} {r["review"]["style"]} budget {r["review"]["budget"]}']
            text += [f'escalate: {x}' for x in r['escalate']]
            text += [f'unmapped: {x}' for x in r['unmapped']]
            text += [f'outside the repo: {x}' for x in r['outside']]
            emit(r, args.json, '\n'.join(text))
            return 0
        if args.cmd == 'gate':
            r = run_gate(root, kitchen, args.profile, args.stage, args.log_dir, args.keep_going, args.only, args.result,
                         args.role, args.base)
            lines = [f'{args.profile} {args.stage}: {"pass" if r["passed"] else "FAIL"}'
                     + ('' if r['commands'] else ' (no commands)')]
            for x in r['commands']:
                lines.append(f'  exit {x["exit"]} {x["seconds"]}s {x["command"]}  log: {x["log"]}')
                if x.get('retried'):
                    t = x['retried']
                    lines.append(f'  retried at load {t["load"]} after exit {t["first_exit"]} (log: {t["first_log"]}): '
                                 + ('passed' if x['flaky'] else 'failed again'))
                lines += [f'    | {t}' for t in x.get('tail', [])]
            lines += [f'flaky under load: {args.profile} {args.stage}' for x in r['commands'] if x.get('flaky')][:1]
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
