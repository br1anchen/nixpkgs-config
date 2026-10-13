#!/usr/bin/env python3
"""Deterministic half of pstack-kitchen: a repo's .agents/kitchen.toml (or
its host kitchen) read as data. It classifies a change into profiles and a risk class, runs a
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
import math
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
    scratch_setup: list[str] = field(default_factory=list)


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
                                       'verify', 'landing', 'coverage', 'resources', 'run', 'scratch'})
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
    # The kitchen runs no reviewer: review is the master's step, done with
    # whatever the repo's owner chose. An owner who names an engine makes it
    # required: land-check refuses a unit whose review note cites no run of
    # it. The per-class tables tuned a reviewer the kitchen ran; they still
    # parse, ignored.
    legacy_review = {'routine', 'escalated', 'landing'}
    _check_keys(review, 'review', {'self', 'standards', 'max_batch_diff', 'engine', *legacy_review})
    engine = review.get('engine', '')
    if not isinstance(engine, str) or (engine and not re.fullmatch(r'[A-Za-z0-9_.-]+', engine)):
        raise ConfigError('review.engine: expected a tool name such as "joo"')
    rev = {
        'engine': engine,
        'self': _strings(review.get('self', []), 'review.self'),
        'standards': _strings(review.get('standards', []), 'review.standards'),
        'max_batch_diff': _int(review.get('max_batch_diff', 800), 'review.max_batch_diff', 1),
        'legacy': sorted(legacy_review & set(review)),
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
    scratch = data.get('scratch', {})
    _check_keys(scratch, 'scratch', {'setup'})
    run = data.get('run', {})
    _check_keys(run, 'run', {'wrap'})
    if not isinstance(run.get('wrap', ''), str):
        raise ConfigError('run.wrap: expected a string, such as "nix develop --command"')
    return Kitchen(
        profiles=profiles, escalate=esc, rules=rules, review=rev, verify=ver,
        landing=_choice(landing.get('mode', 'commit'), 'landing.mode', LANDING_MODES),
        coverage_ignore=[glob_regex(g) for g in _strings(coverage.get('ignore', []), 'coverage.ignore')],
        max_parallel_heavy=_int(resources.get('max_parallel_heavy', 1), 'resources.max_parallel_heavy', 1),
        wrap=run.get('wrap', ''), scratch_setup=_strings(scratch.get('setup', []), 'scratch.setup'))


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


# Where a repo's kitchen lives. The repo's own .agents/kitchen.toml wins: at a
# revision, so a unit is verified against the rules it was built under, or
# the working copy. A repo whose team has not agreed to commit one keeps it on
# the host instead: a [[kitchen]] entry in the host roster whose match glob
# covers the checkout, else kitchens/<origin>.toml beside the roster, keyed by
# the origin remote so every clone, worktree and verifier scratch finds the
# same file. A host kitchen has no history, so kitchen.sh hands each unit a
# snapshot of it through an absolute --config.
@dataclass
class Source:
    kind: str  # repo, file, roster or user
    label: str
    text: str


def roster_path() -> Path:
    return Path(os.environ.get('PSTACK_KITCHEN_ROSTER') or Path.home() / '.config/pstack/kitchen.toml')


# The checkout that holds .git, or a bare repository's git dir: one per repo
# however many worktrees it has.
def repo_main(root: Path) -> Path:
    common = git(root, 'rev-parse', '--path-format=absolute', '--git-common-dir', check=False).strip()
    if not common:
        return root
    return Path(common).parent if Path(common).name == '.git' else Path(common)


# host/owner/repo from any spelling of a remote URL: https, ssh://, scp-like
# git@host:owner/repo, with or without .git.
def origin_key(url: str) -> str | None:
    url = url.strip()
    m = re.match(r'^[a-z][a-z0-9+.-]*://(?:[^@/]*@)?([^/:]+)(?::\d+)?/(.+)$', url, re.I) \
        or re.match(r'^(?:[^@/]+@)?([^/:]+):(?!/)(.+)$', url)
    if not m:
        return None
    path = re.sub(r'(?:\.git)?/*$', '', m.group(2)).strip('/')
    return f'{m.group(1).lower()}/{path}' if path else None


def host_key(root: Path) -> str:
    k = origin_key(git(root, 'remote', 'get-url', 'origin', check=False))
    if k:
        return re.sub(r'[^A-Za-z0-9._-]', '_', k.replace('/', '__'))
    main = repo_main(root)
    return f'{main.name}-{hashlib.sha256(str(main).encode()).hexdigest()[:8]}'


# A path glob with ~ expanded and its literal directories resolved, since git
# reports resolved paths (on macOS /var is /private/var).
def real_glob(pattern: str) -> str:
    pattern = os.path.expanduser(pattern).rstrip('/')
    cut = min([i for i in (pattern.find(c) for c in '*?') if i >= 0], default=len(pattern))
    head = pattern[:cut].rsplit('/', 1)[0] if cut < len(pattern) else pattern
    return os.path.realpath(head) + pattern[len(head):] if head else pattern


# The host file this repo would use, and how it was chosen: a roster
# [[kitchen]] entry whose match covers the checkout or its main checkout,
# else kitchens/<key>.toml. It need not exist yet.
def host_kitchen(root: Path) -> tuple[str, Path]:
    path = roster_path()
    try:
        entries = tomllib.loads(path.read_text()).get('kitchen', []) if path.exists() else []
    except tomllib.TOMLDecodeError as e:
        raise ConfigError(f'{path}: {e}') from None
    if not isinstance(entries, list):
        raise ConfigError(f'{path}: kitchen must be an array of tables ([[kitchen]])')
    here = [str(root), str(repo_main(root))]
    for i, e in enumerate(entries):
        where = f'{path}: kitchen[{i}]'
        if not isinstance(e, dict) or not isinstance(e.get('match'), str) or not isinstance(e.get('file'), str):
            raise ConfigError(f'{where} needs match and file strings')
        rx = glob_regex(real_glob(e['match']))
        if any(rx.match(h) or rx.match(h + '/') for h in here):
            f = Path(os.path.expanduser(e['file']))
            return 'roster', f if f.is_absolute() else path.parent / 'kitchens' / f
    return 'user', path.parent / 'kitchens' / f'{host_key(root)}.toml'


def locate(root: Path, at: str | None, config: str | None) -> Source:
    if config and Path(config).is_absolute():
        try:
            return Source('file', config, Path(config).read_text())
        except OSError:
            raise ConfigError(f'no kitchen at {config}') from None
    rel = config or CONFIG
    if at:
        r = subprocess.run(['git', '-C', str(root), 'show', f'{at}:{rel}'], capture_output=True, text=True, check=False)
        if r.returncode == 0:
            return Source('repo', f'{rel} at {at}', r.stdout)
    elif (root / rel).is_file():
        return Source('repo', rel, (root / rel).read_text())
    tried = [f'{at}:{rel}' if at else str(root / rel)]
    if not config:
        kind, path = host_kitchen(root)
        if path.is_file():
            return Source(kind, str(path), path.read_text())
        tried.append(str(path))
    raise ConfigError(f'no kitchen at {" or ".join(tried)}; run the pstack-kitchen-setup skill')


def load(root: Path, at: str | None, config: str | None) -> tuple[Kitchen, Source]:
    src = locate(root, at, config)
    try:
        return parse(tomllib.loads(src.text)), src
    except tomllib.TOMLDecodeError as e:
        raise ConfigError(f'{src.label}: {e}') from None


# One state directory per repository, keyed by its git common dir, so a
# worktree (a verifier's scratch, a jj workspace) shares the main checkout's
# ledger and logs instead of leaving a directory of its own. The key is the
# checkout holding .git, or for a bare repository (name.git with worktrees
# beside it) the git dir itself: keying a bare one on its parent put every
# bare repository in that directory into one ledger and one timings file.
# State kept under an older key (per checkout, or a bare repo's parent) is
# copied over once.
def state_dir(root: Path) -> Path:
    base = Path(os.environ.get('XDG_STATE_HOME') or Path.home() / '.local/state') / 'pstack/kitchen/repos'
    common = git(root, 'rev-parse', '--path-format=absolute', '--git-common-dir', check=False).strip()
    def key(p: Path) -> Path:
        return base / f'{p.name}-{hashlib.sha256(str(p).encode()).hexdigest()[:8]}'
    if not common:
        main, older = root, []
    elif Path(common).name == '.git':
        main, older = Path(common).parent, []
    else:
        main, older = Path(common), [key(Path(common).parent)]
    d = key(main)
    d.mkdir(parents=True, exist_ok=True)
    for old in [key(root), *older]:
        for name in ('ledger.tsv', TIMINGS):
            if old != d and (old / name).exists() and not (d / name).exists():
                shutil.copy2(old / name, d / name)
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


def classify(kitchen: Kitchen, changed: list[tuple[str, int, int]], outside: list[str] | None = None,
             escalate: list[str] | None = None) -> dict:
    files, touched, unmapped, reasons = [], set(), [], list(escalate or [])
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
        'features': sorted({f for p in profiles for f in p.features}),
        'behavioral': [p.name for p in profiles if p.commands['behavioral']],
        'max_batch_diff': kitchen.review['max_batch_diff'],
        'files': files,
        'outside': outside or [],
        'bookkeeping': not changed and bool(outside),
        'scratch_setup': kitchen.scratch_setup,
    }


QUEUE_STALE_S = 60


def acquire_slot(lock_dir: Path, prefix: str, slots: int, on_wait=None):
    """Holds one of `slots` machine-wide locks named <prefix>-<i>.lock; returns
    the open file and the seconds spent waiting for it. Waiters queue in
    arrival order: each keeps a ticket in <prefix>-queue/, named for when it
    arrived and touched while it waits, and only the `slots` oldest tickets
    try the locks, so a gate that came later never takes a slot first. A
    ticket untouched for QUEUE_STALE_S belongs to a waiter that died and is
    dropped. on_wait(position, waiting) is called when the position changes."""
    start = time.monotonic()
    queue = lock_dir / f'{prefix}-queue'
    queue.mkdir(parents=True, exist_ok=True)
    ticket = queue / f'{time.time_ns():020d}-{os.getpid()}'
    ticket.touch()
    last = None
    try:
        while True:
            ticket.touch()
            now = time.time()
            live = []
            for t in sorted(queue.iterdir()):
                try:
                    if t != ticket and now - t.stat().st_mtime > QUEUE_STALE_S:
                        t.unlink(missing_ok=True)
                        continue
                except OSError:
                    continue
                live.append(t)
            pos = live.index(ticket) if ticket in live else 0
            if pos < slots:
                for i in range(slots):
                    f = open(lock_dir / f'{prefix}-{i}.lock', 'w')  # noqa: SIM115 - held open as the slot until the gate ends
                    try:
                        fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)
                        return f, round(time.monotonic() - start, 1)
                    except BlockingIOError:
                        f.close()
            if on_wait and pos != last:
                on_wait(pos + 1, len(live))
                last = pos
            time.sleep(float(os.environ.get('PSTACK_KITCHEN_SLOT_POLL_S', '2')))
    finally:
        ticket.unlink(missing_ok=True)


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
    path = roster_path()
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


def run_setup(root: Path, kitchen: Kitchen, role: str = 'verifier') -> dict:
    """Prepare a bare worktree the repo's way: [scratch].setup, in order, inside the wrap entered
    once, from the repo root, as `role`. Fail-fast. No gate slot or retry; only a verifier's run
    is a timing sample, since it is the one the verifier's deadline budgets for."""
    log_dir = state_dir(root) / 'logs'
    log_dir.mkdir(parents=True, exist_ok=True)
    log = log_dir / f'setup-{time.strftime("%Y%m%dT%H%M%S")}-{os.getpid()}.log'
    if not kitchen.scratch_setup:
        return {'passed': True, 'commands': kitchen.scratch_setup, 'exit': 0, 'seconds': 0.0, 'log': None, 'tail': []}
    script = 'set -e\n' + ''.join(f'echo {shlex.quote("+ " + c)}\n{c}\n' for c in kitchen.scratch_setup)
    inner = f'bash -c {shlex.quote(script)}'
    start = time.monotonic()
    with open(log, 'w') as out:
        code = subprocess.run(['bash', '-c', f'{kitchen.wrap} {inner}' if kitchen.wrap else inner], cwd=root, stdout=out,
                              stderr=subprocess.STDOUT, env={**os.environ, ROLE: role}, check=False).returncode
    seconds = round(time.monotonic() - start, 1)
    if role == 'verifier':
        record_setup_timing(root, code == 0, seconds)
    return {'passed': code == 0, 'commands': kitchen.scratch_setup, 'exit': code, 'seconds': seconds,
            'log': str(log), 'tail': [] if code == 0 else log.read_text(errors='replace').splitlines()[-20:]}


TIMINGS = 'timings.tsv'


def record_timing(root: Path, profile: str, stage: str, role: str, g: dict) -> None:
    """One row per whole gate run, so verify can size its timeout."""
    secs = round(sum(c['seconds'] for c in g['commands']), 1)
    row = [str(int(time.time())), profile, stage, role, 'pass' if g['passed'] else 'fail', str(secs),
           str(round(g.get('waited', 0.0), 1))]
    try:
        with open(state_dir(root) / TIMINGS, 'a') as f:
            f.write('\t'.join(row) + '\n')
    except OSError:
        pass


def deadline_text(r: dict) -> str:
    gate = f'3 x {r["gate_seconds"] / 60:.0f}m gates' if r['gate_seconds'] else '3 x 0m gates (none measured)'
    setup = ''
    if r['setup_measured']:
        setup = f' + {r["setup_seconds"] / 60:.0f}m setup'
    elif r['setup_measured'] is False:
        setup = ' + setup unmeasured'
    load = f', x{r["factor"]:g} for load {r["load1"]:g} on {r["cores"]} cores' if r['factor'] > 1 else f', load {r["load1"]:g} on {r["cores"]} cores'
    floor = f' (floor {r["floor"]}m)' if r['minutes'] == r['floor'] else ''
    return f'deadline {r["minutes"]}m{floor}: {gate}{setup}{load}'


def record_setup_timing(root: Path, passed: bool, seconds: float) -> None:
    """A setup run is its own row kind (profile "-", stage setup), so no gate sample ever includes it."""
    row = [str(int(time.time())), '-', 'setup', 'verifier', 'pass' if passed else 'fail', str(seconds)]
    try:
        with open(state_dir(root) / TIMINGS, 'a') as f:
            f.write('\t'.join(row) + '\n')
    except OSError:
        pass


def setup_timing(root: Path) -> float | None:
    """The latest passing, nonempty setup run in seconds, or None when none was recorded."""
    path = state_dir(root) / TIMINGS
    last = None
    if path.exists():
        for line in path.read_text().splitlines():
            f = line.split('\t')
            if len(f) >= 6 and f[1] == '-' and f[2] == 'setup' and f[4] == 'pass':
                last = float(f[5])
    return last


def host_load() -> tuple[float, int]:
    """One-minute load and cores; PSTACK_KITCHEN_LOAD="<load1> <cores>" overrides both (tests)."""
    raw = os.environ.get('PSTACK_KITCHEN_LOAD')
    if raw:
        parts = raw.split()
        try:
            if len(parts) != 2 or float(parts[0]) < 0 or int(parts[1]) < 1:
                raise ValueError
            return float(parts[0]), int(parts[1])
        except ValueError:
            raise ConfigError('PSTACK_KITCHEN_LOAD: expected "<load1> <cores>", such as "22 16"') from None
    try:
        return os.getloadavg()[0], os.cpu_count() or 1
    except OSError:
        return 0.0, os.cpu_count() or 1


def verify_deadline(root: Path, profiles: list[str], with_setup: bool) -> dict:
    """The default verifier deadline in minutes and the parts it came from:
    max(45, ceil((3 x gate seconds + setup seconds) x min(3, max(1, load1 / cores)) / 60))."""
    gates = gate_timing(root, profiles, 'behavioral')
    setup = (setup_timing(root) or 0.0) if with_setup else 0.0
    load1, cores = host_load()
    factor = min(3.0, max(1.0, load1 / cores))
    raw = (3 * gates['seconds'] + setup) * factor / 60
    minutes = max(45, math.ceil(raw))
    return {'minutes': minutes, 'floor': 45, 'gate_seconds': gates['seconds'], 'setup_seconds': setup,
            'setup_measured': setup_timing(root) is not None if with_setup else None,
            'load1': round(load1, 1), 'cores': cores, 'factor': round(factor, 2), 'unmeasured': gates['unmeasured']}


def gate_timing(root: Path, profiles: list[str], stage: str, last: int = 10) -> dict:
    """The slowest of each profile's last passing runs of a stage, and their sum:
    a verifier runs the profiles one after another."""
    runs: dict[str, list[float]] = {p: [] for p in profiles}
    path = state_dir(root) / TIMINGS
    if path.exists():
        for line in path.read_text().splitlines():
            f = line.split('\t')
            if len(f) >= 6 and f[1] in runs and f[2] == stage and f[4] == 'pass':
                runs[f[1]].append(float(f[5]))
    slowest = {p: max(r[-last:]) for p, r in runs.items() if r}
    return {'stage': stage, 'profiles': slowest, 'seconds': round(sum(slowest.values()), 1),
            'unmeasured': [p for p in profiles if p not in slowest]}


def _run_gate(root: Path, kitchen: Kitchen, p: Profile, profile: str, stage: str, commands: list, log_dir: Path,
              keep_going: bool, only: int | None, result: Path | None, role: str, inside: bool, wrap: str) -> dict:
    pool, waited = (None, 0.0)
    if commands and not inside:
        slots = machine_gate_slots()
        def queued(pos, n):
            print(f'kitchen: queued {pos} of {n} for {slots} machine gate slot{"s" if slots > 1 else ""}',
                  file=sys.stderr, flush=True)
        pool, waited = acquire_slot(state_dir(root).parent, 'gate', slots, queued)
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


def doctor(root: Path, kitchen: Kitchen, source: Source, run: bool) -> list[dict]:
    checks = []
    builtins = shell_builtins()

    def add(name: str, status: str, detail: str = '', items: list | None = None):
        checks.append({'check': name, 'status': status, 'detail': detail, 'items': items or []})

    # A repo kitchen that is not committed is a half state: this checkout reads
    # it, but verify reads the kitchen at each unit's commit and the verifier's
    # scratch is built from one, so neither sees it.
    _, host = host_kitchen(root)
    if source.kind == 'repo' and (root / CONFIG).is_file() and subprocess.run(
            ['git', '-C', str(root), 'ls-files', '--error-unmatch', CONFIG], capture_output=True, check=False).returncode:
        ignored = subprocess.run(['git', '-C', str(root), 'check-ignore', '-q', CONFIG], check=False).returncode == 0
        add('kitchen', 'fail', f'{CONFIG} is {"ignored or excluded" if ignored else "untracked"}: verify and the verifier '
            f'never see it; commit it, or move it to the host path {host} (kitchen.py where --host)')
    elif source.kind == 'repo' and host.is_file():
        add('kitchen', 'warn', f'{source.label}; the host kitchen {host} is shadowed by it and unused')
    else:
        add('kitchen', 'ok', f'{source.kind} {source.label}')
    add('lessons', *lessons_doctor(lessons_path(root, source), state_dir(root) / 'ledger.tsv'))

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
    manifests = [m for m, locks in (('package.json', ('bun.lock', 'bun.lockb', 'pnpm-lock.yaml', 'package-lock.json', 'yarn.lock')),
                                    ('pyproject.toml', ('uv.lock', 'poetry.lock')))
                 if (root / m).exists() and any((root / x).exists() for x in locks)]
    if kitchen.scratch_setup:
        add('scratch setup', 'ok', '; '.join(kitchen.scratch_setup))
    elif manifests:
        add('scratch setup', 'warn', f'none, but the repo root has {", ".join(manifests)} with a lockfile: a bare verifier '
            'worktree may need [scratch].setup (the install command, without the wrap)')
    else:
        add('scratch setup', 'ok', 'none')
    _, vr = roster_data()
    routine = vr['verifier']['routine']
    add('verifier routine', 'ok', describe_verifier(routine))
    add('verifier fallback', 'ok', describe_verifier({**routine['fallback'], 'source': routine['source']}) if routine['fallback'] else 'none')
    add('verifier escalated', 'ok', describe_verifier(vr['verifier']['escalated']) + '; also used by verify --landing')
    if kitchen.review['engine']:
        engine = kitchen.review['engine']
        found = shutil.which(f'{engine}-dev') or shutil.which(engine)
        add('review engine', 'ok' if found else 'warn',
            f'{engine} ({found}); land-check requires each accepted unit\'s review note to cite a run' if found
            else f'{engine} is required by [review].engine, but neither {engine}-dev nor {engine} is on PATH')
    if kitchen.review['legacy']:
        add('review', 'warn', f'review.{", review.".join(kitchen.review["legacy"])} tuned a reviewer the kitchen no longer '
            'runs; remove them from kitchen.toml')
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


def roster_data() -> tuple[Path, dict]:
    path = roster_path()
    data = tomllib.loads(path.read_text()) if path.exists() else {}
    out = {}
    for role in ('sidekick', 'consultant'):
        t = data.get(role, {})
        out[role] = {'kind': t.get('kind', ''), 'args': [str(a) for a in t.get('args', [])]}
        if role in ('sidekick', 'consultant'):
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
    return path, out


def roster(as_json: bool) -> int:
    path, out = roster_data()
    emit(out, as_json, f'{path}: ' + ', '.join(f'{r} {v["kind"] or "unset"}' for r, v in out.items() if 'kind' in v)
         + f', verifier {out["verifier"]["routine"]["kind"]}/{out["verifier"]["escalated"]["kind"]}')
    return 0


def describe_verifier(e: dict | None) -> str:
    """One resolved verifier entry as doctor prints it: the kind, its model arguments, and where it came from."""
    if not e:
        return 'none'
    if e['kind'] == 'sidekick':
        return "the run's current sidekick (source sidekick: its kind and arguments are read from the run)"
    if e['kind'] == 'master':
        return f"the master's own kind (source {e['source']})"
    args = ' '.join(shlex.quote(a) for a in e['args']) or '(model unspecified)'
    return f"{e['kind']} {args} (source {e['source']})"


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
    attempts = [{'agent': _header(v, 'verifier-agent') or 'unknown', 'class': _header(v, 'verifier-class') or 'unknown',
                 'outcome': _header(v, 'verifier-outcome') or 'unknown'}
                for v in sorted((store / 'verdicts').glob('*-packet.md'))]
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
        'verifier_attempts': attempts,
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


# The repo's ledger: one row per class of trouble a run met (a failed gate, a
# rejected verdict, a steer, a flaky gate, a catch). area and finding say
# where and what, and match names the trouble within its class (the gate check
# or policy rule that failed, the steer's kind), so a later run can tell one
# repeated problem from several that share a kind. Rows from before those
# columns have five, or eight.
LEDGER_HEAD = ('ts', 'run', 'kind', 'class', 'detail', 'unit', 'area', 'finding', 'match')
TEST_DIR = re.compile(r'(^|/)(tests?|specs?|__tests__|testdata)(/|$)')
DOC_DIR = re.compile(r'(^|/)(docs?|adrs?|documentation)(/|$)')


def _cell(text: str, limit: int = 200) -> str:
    text = ' '.join(text.replace('\t', ' ').split())
    return text if len(text) <= limit else text[:limit - 1] + '…'


def unit_brief(store: Path, unit: str) -> Path | None:
    """A unit (`001`, or a brief's name) to its brief, the first attempt's when several."""
    seq = unit[:3]
    briefs = sorted((store / 'briefs').glob(f'{seq}-*.md'), key=lambda p: (len(p.name), p.name))
    return briefs[0] if briefs else None


def brief_scope(brief: Path) -> list[str]:
    """A brief's `may write:` entries, as the kitchen reads them."""
    out, on = [], False
    try:
        lines = brief.read_text().splitlines()
    except OSError:
        return out
    for line in lines:
        if line.startswith('may write:'):
            on = True
        elif line.startswith('must not write:') or line.startswith('## '):
            on = False
        elif on and line.startswith('- '):
            # As pair-core's scope_entries: a backquoted entry is kept whole,
            # else a " — " (or – or --) annotation and a trailing (...) note go.
            e = line[2:]
            if e.startswith('`'):
                e = e[1:].split('`', 1)[0]
            else:
                e = re.sub(r' +\(.*\)$', '', re.sub(r' +(—|–|--) .*$', '', e))
            if e:
                out.append(e)
    return out


AREA_DEPTH = 2


def scope_area(globs: list[str]) -> list[str]:
    """The repo directories a scope writes, at most AREA_DEPTH deep, tests
    and docs left out unless the unit writes nothing else (a code unit's ADR
    is not where its trouble was): `src/api/**` and `src/api/x.py` are both
    `src/api`; a file at the root is `.`. Paths outside the repo (the run's
    own reports) are no area."""
    def dir_of(g: str) -> str:
        cut = min([i for i in (g.find(c) for c in '*?[{') if i >= 0], default=len(g))
        head = g[:cut]
        # What follows the last slash is a file name, or part of one.
        parts = [p for p in head.rsplit('/', 1)[0].split('/') if p] if '/' in head else []
        return '/'.join(parts[:AREA_DEPTH]) or '.'
    globs = [g for g in globs if not g.startswith(('/', '~', '../'))]
    code = [g for g in globs if not TEST_DIR.search(g) and not DOC_DIR.search(g)]
    docs = [g for g in globs if not TEST_DIR.search(g)]
    return sorted({dir_of(g) for g in (code or docs or globs)})


def unit_area(store: Path, units: list[str]) -> str:
    globs: list[str] = []
    for u in units:
        b = unit_brief(store, u)
        if b:
            globs += brief_scope(b)
    return ','.join(scope_area(globs)) if globs else ''


def _section(path: Path, title: str) -> str:
    """The first line of a markdown section's text, list markers dropped."""
    try:
        lines = path.read_text().splitlines()
    except OSError:
        return ''
    on = False
    for line in lines:
        if line.startswith('## '):
            on = line[3:].strip().lower() == title
            continue
        text = re.sub(r'^\s*(?:\d+[.)]|[-*])\s+', '', line).strip()
        if on and text:
            return text
    return ''


GATE_FAIL = re.compile(r'^(\S+) (fast|behavioral|landing): FAIL')
GATE_EXIT = re.compile(r'^\s+exit [1-9]\d* \S+s (.+?)  log: ')
GATE_OUT = re.compile(r'^\s+\| ?(.*)$')
POLICY_LINE = re.compile(r'^\S+?(?::\d+)?: \[([a-z0-9-]+)\] ')
# A failing command's checks, from the task runner's own words: turbo's
# `Failed: pkg#task`, a package script's `error: script "x" exited`.
CHECK_NAMES = (re.compile(r'Failed:\s+\S+#(\S+)'), re.compile(r'error: script "([^"]+)" exited'))
RUNNER_NOISE = re.compile(r'script "[^"]+" exited|ERROR\s+run failed|"turbo" exited|build failed, waiting|'
                          r'^\s*Failed:|For more information about this error')


def gate_failures(store: Path, unit: str, sha: str) -> list[tuple[str, str, str]]:
    """What a failed step's gates said, one (class, match, finding) per failing
    check: class the profile (or `policy`), match the stage and check (or the
    policy rule), finding the first error line the check printed, else its
    command."""
    for out in sorted((store / 'steps/jobs').glob(f'{unit}-{sha}*/out')):
        try:
            lines = out.read_text().splitlines()
        except OSError:
            continue
        found: list[tuple[str, str, str]] = []
        policy: list[tuple[str, str, str]] = []
        profile = stage = ''
        cmds: list[tuple[str, str, str, list[str]]] = []
        for ln in lines:
            if m := GATE_FAIL.match(ln):
                profile, stage = m.groups()
            elif (m := GATE_EXIT.match(ln)) and profile:
                cmds.append((profile, stage, m.group(1), []))
            elif (m := GATE_OUT.match(ln)) and cmds:
                cmds[-1][3].append(m.group(1))
            elif m := POLICY_LINE.match(ln):
                policy.append(('policy', m.group(1), ln.strip()))
        for profile, stage, cmd, out_lines in cmds:
            checks = list(dict.fromkeys(n for rx in CHECK_NAMES for ln in out_lines for n in rx.findall(ln)))
            errors = [ln for ln in out_lines if re.search(r'\berror\b|\bFAIL\b|failed', ln, re.I) and not RUNNER_NOISE.search(ln)]
            for check in checks or [cmd]:
                mine = [ln for ln in errors if f':{check}:' in ln] or errors
                # A brief quotes the match, so it carries none of its own.
                found.append((profile, f'{stage} {_cell(check, 60)}'.replace('"', "'"), mine[0].strip() if mine else cmd))
        return list(dict.fromkeys(found + policy))
    return []


def retro_rows(store: Path, run: str, ts: str) -> list[tuple[str, ...]]:
    rows: list[tuple[str, ...]] = []
    try:
        gates = [ln.split('\t') for ln in (store / 'gates.tsv').read_text().splitlines()]
    except OSError:
        gates = []
    for g in gates:
        if len(g) >= 5 and g[3] == 'fail':
            area = unit_area(store, [g[1]])
            # Without the step's output, the profiles that ran stand for the check.
            for cls, match, finding in gate_failures(store, g[1], g[2]) or [(g[4], '', '')]:
                rows.append((ts, run, 'gate-fail', cls, f'{g[1]} {g[2]}', g[1][:3], area, finding, match))
    for v in sorted((store / 'verdicts').glob('*-v[0-9]*.md')):
        if 'packet' in v.name or _header(v, 'status').split(' ')[0] != 'reject':
            continue
        units = _header(v, 'units').split()
        rows.append((ts, run, 'reject', 'verify', v.stem, ' '.join(units), unit_area(store, units),
                     _section(v, 'findings'), ''))
    for s in sorted((store / 'steers').glob('*-s[0-9]*.md')):
        kind, direction = _header(s, 'kind'), _section(s, 'direction')
        rows.append((ts, run, 'steer', 'brief', s.stem, s.name[:3], unit_area(store, [s.name[:3]]),
                     f'{kind}: {direction}' if kind else direction, kind))
    try:
        events = [ln.split('\t') for ln in (store / 'events.tsv').read_text().splitlines()[1:]]
    except OSError:
        events = []
    for e in events:
        if len(e) >= 6 and e[3] == 'gate-flaky':
            unit = e[4] if re.match(r'\d{3}', e[4]) else ''
            rows.append((ts, run, 'gate-flaky', e[5], e[4], unit[:3], unit_area(store, [unit]) if unit else '', '', ''))
    return [tuple(_cell(c) for c in r) for r in rows]


def ledger_rows(ledger: Path) -> list[dict[str, str]]:
    try:
        lines = ledger.read_text().splitlines()
    except OSError:
        return []
    return [dict(zip(LEDGER_HEAD, ln.split('\t') + [''] * len(LEDGER_HEAD))) for ln in lines[1:] if ln]


def write_ledger(ledger: Path, rows: list[dict[str, str]]) -> None:
    tmp = ledger.with_name(ledger.name + '.tmp')
    tmp.write_text('\t'.join(LEDGER_HEAD) + '\n' + ''.join('\t'.join(r[k] for k in LEDGER_HEAD) + '\n' for r in rows))
    tmp.replace(ledger)


def ledger_lock(ledger: Path):
    """One writer at a time: runs in several worktrees share the ledger."""
    f = open(ledger.with_name(ledger.name + '.lock'), 'w')
    fcntl.flock(f, fcntl.LOCK_EX)
    return f


def ledger_retro(store: Path, ledger: Path, run: str, ts: str) -> int:
    """This run's rows replace any it wrote before (catches stay), so retro can run again."""
    with ledger_lock(ledger):
        return _ledger_retro(store, ledger, run, ts)


def _ledger_retro(store: Path, ledger: Path, run: str, ts: str) -> int:
    rows = [r for r in ledger_rows(ledger) if r['run'] != run or r['kind'] == 'catch']
    new = retro_rows(store, run, ts)
    catches = [tuple(r[k] for k in LEDGER_HEAD) for r in rows if r['run'] == run and r['kind'] == 'catch']
    new += lesson_rows(store, run, ts, new + catches)
    write_ledger(ledger, rows + [dict(zip(LEDGER_HEAD, r)) for r in new])
    return len(new)


def ledger_catch(store: Path, ledger: Path, run: str, ts: str, layer: str, text: str, unit: str | None) -> None:
    if unit and not unit_brief(store, unit):
        raise ConfigError(f'no brief for unit {unit} in {store}/briefs')
    with ledger_lock(ledger):
        rows = ledger_rows(ledger)
        rows.append(dict(zip(LEDGER_HEAD, (ts, run, 'catch', layer, _cell(text, 10_000), unit or '',
                                           unit_area(store, [unit]) if unit else '', _cell(text), ''))))
        write_ledger(ledger, rows)



# Lessons: a rule learned from trouble the ledger saw in one area across runs
# (or once, from a catch), staged before it becomes a check. The file holds
# the rule and its evidence and changes only when a lesson is added or moves
# status; how often a lesson held or was hit is counted in the host ledger
# (kind `lesson`, class `held` or `hit`, detail the id), so a run never dirties
# the repo. A repo kitchen keeps its lessons beside it in the repo; a host
# kitchen keeps them beside the host file.
LESSONS = '.agents/LESSONS.md'
LESSON_STATUS = ('proposed', 'active', 'promoted', 'retired')
LESSON_KINDS = ('gate-fail', 'gate-flaky', 'reject', 'steer', 'catch')
GATE_KINDS = ('gate-fail', 'gate-flaky')
# A steer is trouble when it turned the sidekick: a scope grant, news or a
# skipped step is the master's or the owner's, and no rule for the sidekick.
STEER_TROUBLE = ('redirect', 'narrow')
KIND_LAYER = {'gate-fail': 'gate', 'gate-flaky': 'gate', 'reject': 'verify', 'steer': 'brief'}
LESSON_FIELDS = ('status', 'kind', 'class', 'match', 'layer', 'area', 'since', 'active', 'note')
CANDIDATES_SHOWN = 5  # retro prints the strongest; lessons --all prints every one
# Runs a kind of trouble must recur in before it is a candidate. A failed gate
# costs the sidekick a step it fixes alone; a reject or a steer costs the
# master a wake; a catch is a miss that got past every layer.
CANDIDATE_RUNS = {'gate-fail': 3, 'catch': 1}
PROMOTE_AFTER = 3  # clean units in the area, with no hit, before a lesson can be promoted
LESSONS_HEAD = """# Kitchen lessons

Rules learned from trouble that repeated in one area across kitchen runs.
`kitchen.py lessons` proposes them from the run ledger, the master writes each
rule, and the human approves every promotion into a check or a standard.
How often each held or recurred is counted on the host, not here.
"""


@dataclass
class Lesson:
    id: str
    rule: str
    fields: dict[str, str]
    evidence: list[str]
    notes: list[str] = field(default_factory=list)  # lines a human added, kept as written


def lessons_path(root: Path, source: Source) -> Path:
    # An absolute --config is a unit's snapshot of the host kitchen (kitchen.sh
    # passes one at every step), so its lessons are the host file's, not the copy's.
    if source.kind == 'repo':
        return root / LESSONS
    return host_kitchen(root)[1].with_suffix('.lessons.md')


def read_lessons(path: Path) -> list[Lesson]:
    try:
        text = path.read_text()
    except OSError:
        return []
    out: list[Lesson] = []
    for m in re.finditer(r'^## (L\d{3,}): (.*)\n((?:(?!## ).*\n?)*)', text, re.M):
        fields, evidence, notes, on = {}, [], [], False
        for line in m.group(3).splitlines():
            if on and line.startswith('- '):
                evidence.append(line[2:].strip())
                continue
            on = False
            k = re.match(r'^([a-z-]+):\s*(.*)$', line)
            if k and k.group(1) == 'evidence':
                on = True
            elif k and k.group(1) in LESSON_FIELDS:
                fields[k.group(1)] = k.group(2).strip()
            else:
                notes.append(line)
        while notes and not notes[-1].strip():
            notes.pop()
        while notes and not notes[0].strip():
            notes.pop(0)
        out.append(Lesson(m.group(1), m.group(2).strip(), fields, evidence, notes))
    return out


def lessons_preamble(path: Path) -> str:
    """The file's text before its first lesson, as the human left it."""
    try:
        text = path.read_text()
    except OSError:
        return LESSONS_HEAD
    m = re.search(r'^## L\d{3,}: ', text, re.M)
    return (text[:m.start()] if m else text).rstrip('\n') + '\n'


def write_lessons(path: Path, lessons: list[Lesson]) -> None:
    head = lessons_preamble(path)
    body = []
    for x in lessons:
        body.append(f'## {x.id}: {x.rule}\n\n' + ''.join(f'{k}: {x.fields[k]}\n' for k in LESSON_FIELDS if k in x.fields)
                    + 'evidence:\n' + ''.join(f'- {e}\n' for e in x.evidence)
                    + (''.join(f'{n}\n' for n in ['', *x.notes]) if x.notes else ''))
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + '.tmp')
    tmp.write_text(head + ''.join('\n' + b for b in body))
    tmp.replace(path)


def covers(d: str, e: str) -> bool:
    """Directory d holds directory e (`.` holds only files at the root)."""
    return e == d or (d != '.' and e.startswith(d + '/'))


def overlaps(a: str, b: str) -> bool:
    return any(covers(x, y) or covers(y, x) for x in a.split(',') if x for y in b.split(',') if y)


def lesson_key(lid: str, active: str) -> str:
    """The ledger's name for one version of a lesson: its id and when it was
    last made active, which a brief carries from dispatch."""
    return f'{lid}@{active}' if active else lid


def lesson_scores(rows: list[dict[str, str]], x: Lesson) -> list[dict[str, str]]:
    """Held and hit rows for units briefed with this version of the lesson:
    a rewritten rule starts its count again."""
    active = x.fields.get('active', '')
    key = lesson_key(x.id, active)
    # Rows from before versions carry the bare id: they count from activation.
    return [r for r in rows if r['kind'] == 'lesson'
            and (r['detail'] == key or (r['detail'] == x.id and r['ts'] >= active))]


def promotable(x: Lesson, n: dict[str, int]) -> bool:
    return x.fields.get('status') == 'active' and n['held'] >= PROMOTE_AFTER and n['hits'] == 0


def lesson_counts(rows: list[dict[str, str]], x: Lesson) -> dict[str, int]:
    mine = lesson_scores(rows, x)
    return {'held': sum(r['class'] == 'held' for r in mine), 'hits': sum(r['class'] == 'hit' for r in mine)}


def row_match(r: dict[str, str]) -> str:
    """What a row's trouble was within its class. Steer rows from before the
    match column carry their kind at the head of the finding."""
    if r['match'] or r['kind'] != 'steer':
        return r['match']
    head = r['finding'].split(':', 1)[0]
    return head if ':' in r['finding'] and re.fullmatch(r'[a-z-]+', head) else ''


def is_trouble(r: dict[str, str]) -> bool:
    """A row a lesson could be learned from: it has an area, and a failed
    gate names its check (one without its step's output does not)."""
    if not r['area'] or r['kind'] not in LESSON_KINDS:
        return False
    if r['kind'] == 'steer':
        return row_match(r) in STEER_TROUBLE
    return r['kind'] != 'gate-fail' or bool(r['match'])


def same_trouble(kind: str, cls: str, match: str, r: dict[str, str]) -> bool:
    """A row is a lesson's trouble when kind and class agree and, where the
    lesson names a match, so does the row."""
    return r['kind'] == kind and r['class'] == cls and (not match or row_match(r) == match)


def evidence_line(r: dict[str, str]) -> str:
    return f'{r["ts"][:10]} {r["run"]} {r["unit"] or "-"}: {r["finding"] or r["detail"]}'


def lesson_candidates(rows: list[dict[str, str]], lessons: list[Lesson]) -> list[dict]:
    """(kind, class, match, area) seen in two runs or more, or once by a catch,
    in rows no open lesson already covers and no dismissal has seen. The most
    specific area that keeps every run wins; the most runs come first."""
    open_ = [x for x in lessons if x.fields.get('status') != 'retired']
    dismissed = [r for r in rows if r['kind'] == 'dismiss']

    def known(r: dict[str, str]) -> bool:
        return any(same_trouble(x.fields.get('kind', ''), x.fields.get('class', ''), x.fields.get('match', ''), r)
                   and all(covers(x.fields.get('area', ''), e) for e in r['area'].split(',') if e) for x in open_)
    trouble = [r for r in rows if is_trouble(r) and not known(r)]
    groups: dict[tuple[str, str, str], list[dict[str, str]]] = {}
    for r in trouble:
        groups.setdefault((r['kind'], r['class'], row_match(r)), []).append(r)
    out = []
    for (kind, cls, match), rs in sorted(groups.items()):
        found = []
        for d in sorted({d for r in rs for d in r['area'].split(',') if d}):
            m = [r for r in rs if any(covers(d, e) for e in r['area'].split(','))]
            runs = sorted({r['run'] for r in m})
            # A dismissal holds until trouble newer than it comes back.
            if any(x['class'] == kind and x['detail'] == cls and x['match'] == match and covers(x['area'], d)
                   and x['ts'] >= max(r['ts'] for r in m) for x in dismissed):
                continue
            if len(runs) >= CANDIDATE_RUNS.get(kind, 2):
                found.append({'kind': kind, 'class': cls, 'match': match, 'area': d, 'runs': runs, 'rows': m})
        for c in found:
            if any(o is not c and covers(c['area'], o['area']) and o['runs'] == c['runs'] for o in found):
                continue
            out.append({k: c[k] for k in ('kind', 'class', 'match', 'area', 'runs')}
                       | {'evidence': list(dict.fromkeys(evidence_line(r) for r in c['rows']))[:5]})
    return sorted(out, key=lambda c: -len(c['runs']))


def lessons_report(path: Path, ledger: Path) -> dict:
    rows, lessons = ledger_rows(ledger), read_lessons(path)
    listed = []
    for x in lessons:
        n = lesson_counts(rows, x)
        listed.append({'id': x.id, 'rule': x.rule, **x.fields, **n,
                       'promotable': promotable(x, n)})
    return {'path': str(path), 'lessons': listed, 'candidates': lesson_candidates(rows, lessons)}


def candidate_args(c: dict) -> str:
    """The candidate as `lessons add` and `lessons dismiss` take it."""
    return ' '.join(shlex.quote(a) for a in (c['kind'], c['class'], c['area'])) + (
        f' --match {shlex.quote(c["match"])}' if c['match'] else '')


def lessons_text(r: dict, every: bool = False) -> str:
    lines = [f'lessons: {r["path"]}']
    for x in r['lessons']:
        what = f'{x.get("kind", "")} {x.get("class", "")}' + (f' "{x["match"]}"' if x.get('match') else '')
        lines.append(f'  {x["id"]} {x.get("status", "?"):8} held {x["held"]} hits {x["hits"]}  [{what} '
                     f'in {x.get("area", "")}] {x["rule"]}' + ('  (promotable)' if x['promotable'] else ''))
    if not r['lessons']:
        lines.append('  none')
    shown = r['candidates'] if every else r['candidates'][:CANDIDATES_SHOWN]
    lines.append('candidates: write the rule and stage it (kitchen.py lessons add <args> "<rule>"), or, when the '
                 'evidence shares no cause, dismiss it (kitchen.py lessons dismiss <args> --note "<why>"):')
    for c in shown:
        lines.append(f'  {len(c["runs"])} runs ({", ".join(c["runs"])}): {candidate_args(c)}')
        lines += [f'    {e}' for e in c['evidence']]
    if not r['candidates']:
        lines.append('  none')
    elif len(shown) < len(r['candidates']):
        lines.append(f'  {len(r["candidates"]) - len(shown)} more with fewer runs: kitchen.py lessons --all')
    return '\n'.join(lines)


def norm_area(area: str) -> str:
    area = re.sub(r'^\./', '', area.strip()).rstrip('/') or '.'
    if ',' in area or area.startswith(('/', '..')):
        raise ConfigError('an area is one repo directory, like src/lib (or . for the root)')
    return area


def lessons_add(path: Path, ledger: Path, kind: str, cls: str, area: str, rule: str, layer: str | None,
                today: str, match: str = '') -> Lesson:
    rule = ' '.join(rule.split())
    if not rule or len(rule) > 200:
        raise ConfigError('a rule is one sentence of at most 200 characters')
    area = norm_area(area)
    if '"' in match:
        raise ConfigError('a match has no double quotes; copy it from the candidate')
    evidence = [r for r in ledger_rows(ledger) if same_trouble(kind, cls, match, r) and r['area']
                and any(covers(area, e) for e in r['area'].split(','))]
    if not evidence:
        raise ConfigError(f'no ledger row for {kind} {cls}{" " + match if match else ""} in {area}: '
                          'a lesson needs evidence')
    lessons = read_lessons(path)
    n = max([int(x.id[1:]) for x in lessons], default=0) + 1
    fields = {'status': 'proposed', 'kind': kind, 'class': cls, 'match': match,
              'layer': layer or ('policy' if kind == 'gate-fail' and cls == 'policy' else KIND_LAYER.get(kind, cls)),
              'area': area, 'since': today}
    x = Lesson(f'L{n:03d}', rule, {k: v for k, v in fields.items() if v},
               list(dict.fromkeys(evidence_line(r) for r in evidence))[:5])
    write_lessons(path, lessons + [x])
    return x


def lessons_dismiss(ledger: Path, kind: str, cls: str, area: str, match: str, note: str, now: str) -> None:
    """A candidate whose evidence shares no cause stays hidden until trouble
    newer than the dismissal comes back."""
    if not note.strip():
        raise ConfigError('dismiss needs --note: why the evidence shares no cause')
    area = norm_area(area)
    with ledger_lock(ledger):
        rows = ledger_rows(ledger)
        if not any(same_trouble(kind, cls, match, r) and r['area'] and any(covers(area, e) for e in r['area'].split(','))
                   for r in rows):
            raise ConfigError(f'no ledger row for {kind} {cls}{" " + match if match else ""} in {area}')
        rows.append(dict(zip(LEDGER_HEAD, (now, '-', 'dismiss', kind, cls, '', area, _cell(note), match))))
        write_ledger(ledger, rows)


def lessons_set(path: Path, lid: str, status: str, rule: str | None, note: str | None, now: str) -> Lesson:
    lessons = read_lessons(path)
    x = next((x for x in lessons if x.id == lid), None)
    if not x:
        raise ConfigError(f'no lesson {lid} in {path}')
    if status in ('promoted', 'retired') and not note:
        raise ConfigError(f'{status} needs --note: what enforces it now (commit and check), or why it is retired')
    rule = ' '.join(rule.split()) if rule else None
    # A new version starts when a lesson becomes active or its rule changes;
    # set active again with the same rule keeps its count.
    if status == 'active' and (x.fields.get('status') != 'active' or (rule and rule != x.rule)):
        x.fields['active'] = now
    x.fields['status'] = status
    if rule:
        x.rule = rule
    if note:
        x.fields['note'] = ' '.join(note.split())
    write_lessons(path, lessons)
    return x


# Promotion turns a lesson that held into a check, and the human decides each
# one. The proposal names the cheapest layer that would have caught every
# piece of evidence and why; the master fills in the example, the proof and
# the false-positive scan before asking.
PROMOTE_TO = {
    'gate': ('a lint rule, or a fast-gate command in profile `{cls}` ([profiles.{cls}] in kitchen.toml), '
             'through the correct skill',
             'gates run at every step, so the sidekick meets the error, with its fix, before any verifier'),
    'policy': ('a [[policy.forbid]] rule in kitchen.toml whose message names the fix',
               'policy checks every added line at every step and costs no test time'),
    'verify': ('kitchen.toml: a behavioral command for the profile that covers `{area}`, `require_tests`, or '
               '`{area}/**` in escalate.paths',
               'a verifier caught it, so the gates miss it; encoded, every unit in the area proves it'),
    'brief': ('a standing-orders or plan-template line, or a lint when the steer is mechanical',
              'the master kept steering the same decision; the brief should carry it'),
    'code': ('a lint, test or type through the correct skill; else a CODE_STANDARD.md section listed in '
             'review.standards',
             'review caught it by reading; a check catches it without a reader, and a standard is the fallback '
             'when no check can'),
}
PROMOTE_TO['escalation'] = PROMOTE_TO['verify']


def promotion_draft(path: Path, ledger: Path, lid: str) -> str:
    x = next((x for x in read_lessons(path) if x.id == lid), None)
    if not x:
        raise ConfigError(f'no lesson {lid} in {path}')
    rows = ledger_rows(ledger)
    n = lesson_counts(rows, x)
    f = x.fields
    ready = promotable(x, n)
    why_not = [] if ready else ([f'status is {f.get("status")}, not active'] * (f.get('status') != 'active')
                                + [f'held {n["held"]} of {PROMOTE_AFTER}'] * (n['held'] < PROMOTE_AFTER)
                                + [f'{n["hits"]} hits'] * (n['hits'] > 0))
    layer = f.get('layer', '')
    target, why = PROMOTE_TO.get(layer, PROMOTE_TO['code'])
    if f.get('kind') == 'gate-flaky':
        target, why = (f'related tests per step and the full suite in behavioral for profile `{f.get("class")}`',
                       'the suite fails under load at the fast stage; moving it keeps every step deterministic')
    target = target.format(cls=f.get('class', ''), area=f.get('area', ''))
    source = [r for r in rows if same_trouble(f.get('kind', ''), f.get('class', ''), f.get('match', ''), r) and r['area']
              and any(covers(f.get('area', '.'), e) for e in r['area'].split(','))]
    scored = lesson_scores(rows, x)
    refs = list(dict.fromkeys(f'{r["run"]} {r["detail"]}' for r in source))
    return '\n'.join([
        f'# Promote {lid}: {x.rule}', '',
        f'lesson: {path}',
        f'kind: {f.get("kind")} {f.get("class")}' + (f' "{f["match"]}"' if f.get('match') else '')
        + f', layer {layer}, area {f.get("area")}',
        f'counters: held {n["held"]}, hits {n["hits"]} (promote after {PROMOTE_AFTER} held and no hit)',
        f'promotable: {"yes" if ready else "no (" + "; ".join(why_not) + ")"}', '',
        '## Evidence', '',
        *[f'- {e}' for e in x.evidence],
        *([''] + [f'ledger refs (run, then the unit, verdict or steer to open): {", ".join(refs)}'] if refs else []),
        *([''] + ['held or hit in: ' + ', '.join(f'{r["run"]} {r["unit"]} {r["class"]}' for r in scored)] if scored else []),
        '', '## Proposed check', '',
        f'target: {target}',
        f'why this layer: {why}',
        '<the exact rule, command or section to add, and where>', '',
        '## Example', '',
        '<the offending hunk from an evidence commit (before) and its fix (after)>', '',
        '## Proof', '',
        '<the new check failing on the evidence commit and passing on HEAD, output verbatim; the gate time it adds>', '',
        '## False positives', '',
        '<the check over recent history (git log, or kitchen.py history --last 30 for a kitchen.toml rule): each hit '
        'and whether it is real>', '',
        '## Decision', '',
        f'<the human: approve | edit the rule | keep active | retire. On approve, land the check, then '
        f'kitchen.py lessons set {lid} promoted --note "<commit> <check>">', ''])


def lessons_doctor(path: Path, ledger: Path) -> tuple[str, str, list[str]]:
    lessons = read_lessons(path)
    if not lessons:
        return 'ok', f'no lessons yet ({path})', []
    rows = ledger_rows(ledger)
    items = []
    for x in lessons:
        f, n = x.fields, lesson_counts(rows, x)
        missing = [k for k in ('status', 'kind', 'class', 'layer', 'area') if not f.get(k)]
        if missing or f.get('status') not in LESSON_STATUS:
            items.append(f'{x.id}: unreadable ({", ".join(missing) or "status " + f.get("status", "")}); fix it by hand')
        elif f.get('status') == 'active' and n['hits'] >= 2:
            items.append(f'{x.id}: hit {n["hits"]} times while active; rewrite the rule or retire it')
        elif promotable(x, n):
            items.append(f'{x.id}: promotable (held {n["held"]}); kitchen.py lessons promote {x.id}')
    by = {s: sum(x.fields.get('status') == s for x in lessons) for s in LESSON_STATUS}
    detail = ', '.join(f'{v} {k}' for k, v in by.items() if v) + f' ({path})'
    return ('warn' if items else 'ok'), detail, items


# At dispatch a brief carries the active lessons whose area meets its scope,
# as a Lessons section the kitchen owns; the verifier packet reads them back
# from it, so a unit is held to the lessons of the moment it was briefed.
# Lessons for the layers that verify are extra acceptance; the rest are
# coding pitfalls, which the verifier checks only after its own pass.
VERIFY_LAYERS = ('verify', 'escalation')
BRIEF_LESSONS = 5
LESSON_LINE = re.compile(r'^- (L\d{3,}) \((\S+) (\S+)(?: "([^"]*)")?, layer (\S+), in ([^,)]*)(?:, active (\S+))?\): (.*)$')


def brief_lessons(brief: Path) -> list[dict[str, str]]:
    try:
        lines = brief.read_text().splitlines()
    except OSError:
        return []
    out, on = [], False
    for line in lines:
        if line.startswith('## '):
            on = line[3:].strip() == 'Lessons'
            continue
        m = LESSON_LINE.match(line) if on else None
        if m:
            out.append(dict(zip(('id', 'kind', 'class', 'match', 'layer', 'area', 'active', 'rule'), m.groups())))
            out[-1]['active'] = out[-1]['active'] or ''
            out[-1]['match'] = out[-1]['match'] or ''
    return out


def stamp_lessons(brief: Path, path: Path) -> list[Lesson]:
    """Replace the brief's Lessons section with the active lessons for its scope."""
    globs = brief_scope(brief)
    dirs = ','.join(sorted({d for g in globs for d in scope_area([g])}))
    picked = [x for x in read_lessons(path) if x.fields.get('status') == 'active'
              and overlaps(x.fields.get('area', ''), dirs)][:BRIEF_LESSONS]
    before = brief.read_text()
    text = re.sub(r'\n*^## Lessons\n(?:(?!## ).*\n?)*', '\n', before, flags=re.M).rstrip('\n') + '\n'
    if picked:
        text += ('\n## Lessons\n\nTrouble this area met in earlier runs (kitchen.py lessons). Follow each; the\n'
                 'verifier checks them and reports each one held or hit.\n\n'
                 + ''.join(f'- {x.id} ({x.fields.get("kind")} {x.fields.get("class")}'
                           + (f' "{x.fields["match"]}"' if x.fields.get('match') else '')
                           + f', layer {x.fields.get("layer")}, in {x.fields.get("area")}' + (f', active {x.fields["active"]}' if x.fields.get('active') else '')
                           + f'): {x.rule}\n' for x in picked))
    if text != before and (picked or '## Lessons' in before):
        brief.write_text(text)
    return picked


def lesson_packet(briefs: list[Path]) -> str:
    seen: dict[str, dict[str, str]] = {}
    for b in briefs:
        for x in brief_lessons(b):
            seen.setdefault(x['id'], x)
    if not seen:
        return ''
    check = [x for x in seen.values() if x['layer'] in VERIFY_LAYERS]
    after = [x for x in seen.values() if x['layer'] not in VERIFY_LAYERS]
    text = '## Lessons\n\n'
    if check:
        text += ('Prove these as Acceptance lines too: each is trouble a verifier met here\nbefore.\n\n'
                 + ''.join(f'- {x["id"]}: {x["rule"]}\n' for x in check) + '\n')
    if after:
        text += ('Only after your own pass, check the diff against these; a breach is a\nfinding when it breaks '
                 'Acceptance, and a hit either way.\n\n' + ''.join(f'- {x["id"]}: {x["rule"]}\n' for x in after) + '\n')
    return text + ('In the verdict\'s Lessons section write one line per lesson: `L001: held`, or\n'
                   '`L001: hit <what recurred>`.\n')


def verdict_lessons(verdict: Path) -> dict[str, str]:
    """Lesson id to `held` or `hit <what>`, from a verdict's Lessons section."""
    out: dict[str, str] = {}
    on = False
    try:
        lines = verdict.read_text().splitlines()
    except OSError:
        return out
    for line in lines:
        if line.startswith('## '):
            on = line[3:].strip() == 'Lessons'
            continue
        m = re.match(r'^\W*(L\d{3,})\W*:?\s*(held|hit)\b\W*(.*)$', line) if on else None
        if m:
            out[m.group(1)] = m.group(2) + (f' {m.group(3).strip()}' if m.group(3).strip() else '')
    return out


def lesson_rows(store: Path, run: str, ts: str, trouble: list[tuple[str, ...]]) -> list[tuple[str, ...]]:
    """Each lesson a unit was briefed with: hit when a verdict says so, or its
    kind of trouble came back in that unit and no verdict spoke for it; held
    when a verdict says so, or the unit passed what checks that lesson (a
    verifier, or gates for a gate lesson). An unverified unit scores nothing."""
    def order(v: Path) -> tuple[str, int]:
        m = re.match(r'^(.*)-v(\d+)$', v.stem)
        return (m.group(1), int(m.group(2))) if m else (v.stem, 0)
    # Oldest first (v10 after v2), so a later held never hides an earlier hit.
    verdicts = [(v, _header(v, 'status').split(' ')[0], _header(v, 'units').split(), _header(v, 'verifier') == 'gates')
                for v in sorted((store / 'verdicts').glob('*-v[0-9]*.md'), key=order) if 'packet' not in v.name]
    by_unit: dict[str, list[dict[str, str]]] = {}
    for b in sorted((store / 'briefs').glob('[0-9][0-9][0-9]-*.md')):
        for x in brief_lessons(b):
            if x['id'] not in {y['id'] for y in by_unit.setdefault(b.name[:3], [])}:
                by_unit[b.name[:3]].append(x)
    rows = []
    seen = [dict(zip(LEDGER_HEAD, t)) for t in trouble]
    for unit, lessons in sorted(by_unit.items()):
        mine = [v for v in verdicts if unit in v[2]]
        # A gates-only verdict proves only what gates check: no one read the
        # unit for the other lessons.
        clean_by_verifier = any(s == 'clean' and not gates for _, s, _, gates in mine)
        clean_by_gates = any(s == 'clean' for _, s, _, _ in mine)
        said: dict[str, str] = {}
        for v, _, _, _ in mine:
            for lid, w in verdict_lessons(v).items():
                # A hit stands: the trouble came back in this unit, even if a
                # later verdict found it fixed.
                if not said.get(lid, '').startswith('hit'):
                    said[lid] = w
        for x in lessons:
            key = lesson_key(x['id'], x['active'])
            back = [t for t in seen if same_trouble(x['kind'], x['class'], x['match'], t) and unit in t['unit'].split()]
            word = said.get(x['id'], '')
            # The verifier's word on a lesson beats a reject or catch of the same
            # kind, which may be about something else; gates speak for themselves.
            if word.startswith('hit'):
                rows.append((ts, run, 'lesson', 'hit', key, unit, x['area'], word[4:], ''))
            elif back and not word:
                rows.append((ts, run, 'lesson', 'hit', key, unit, x['area'], back[0]['finding'] or back[0]['detail'], ''))
            elif word == 'held' or (clean_by_gates if x['kind'] in GATE_KINDS else clean_by_verifier):
                rows.append((ts, run, 'lesson', 'held', key, unit, x['area'], '', ''))
    return [tuple(_cell(c) for c in r) for r in rows]


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

    OUTCOMES = ('clean', 'reject', 'inconclusive', 'invalid', 'provider', 'stalled', 'missing', 'start-failed')
    vrows: dict[tuple[str, str], dict] = {}
    for r in rows:
        for a in r['verifier_attempts']:
            v = vrows.setdefault((a['agent'], a['class']), {'agent': a['agent'], 'class': a['class'], 'started': 0,
                                                            **{o: 0 for o in OUTCOMES}, 'running': 0, 'unknown': 0})
            v['started'] += 1
            key = a['outcome'] if a['outcome'] in OUTCOMES else 'running' if a['outcome'] in ('prepared', 'running') else 'unknown'
            v[key] += 1
    vlist = sorted(vrows.values(), key=lambda v: (v['agent'] == 'unknown', v['agent'], v['class']))

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
    lines.append('')
    lines.append('verifier attempts by configured agent and class (reported outcomes on different workloads, not model accuracy;')
    lines.append('the agent is what the CLI was asked for; attempts from before the packet fields count as unknown)')
    lines.append(f'{"agent":38} {"class":9} {"start":>5} {"clean":>5} {"rej":>3} {"incon":>5} {"inval":>5} {"prov":>4} {"stall":>5} {"miss":>4} {"sfail":>5} {"run":>3} {"unk":>3}')
    for v in vlist:
        lines.append(f'{v["agent"][:38]:38} {v["class"]:9} {v["started"]:>5} {v["clean"]:>5} {v["reject"]:>3} {v["inconclusive"]:>5} '
                     f'{v["invalid"]:>5} {v["provider"]:>4} {v["stalled"]:>5} {v["missing"]:>4} {v["start-failed"]:>5} {v["running"]:>3} {v["unknown"]:>3}')
    emit({'runs': rows, 'builds': brows, 'verifiers': vlist}, as_json, '\n'.join(lines))
    return 0


def emit(obj, as_json: bool, text: str) -> None:
    print(json.dumps(obj, indent=2) if as_json else text)


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(prog='kitchen.py', description=__doc__.split('\n\n')[0])
    ap.add_argument('--repo', help='repository (default: the current directory)')
    ap.add_argument('--config', help=f'kitchen file: relative to the repo, or absolute (default {CONFIG}, '
                    'else the host kitchen for this repo)')
    ap.add_argument('--at', help='read the kitchen (and, for --paths, the files) at this revision')
    ap.add_argument('--json', action='store_true', help='machine-readable output')
    sub = ap.add_subparsers(dest='cmd', required=True)
    sub.add_parser('validate', help='parse and check kitchen.toml')
    w = sub.add_parser('where', help='which kitchen file this repo uses, and the host path for one kept off the repo')
    w.add_argument('--host', action='store_true', help='print only the host path (it need not exist yet)')
    sn = sub.add_parser('snapshot', help='copy a host kitchen into DIR, named by its content, and print the copy '
                        '(nothing for a repo kitchen, which git versions)')
    sn.add_argument('dir', type=Path)
    su = sub.add_parser('setup', help='run [scratch].setup in the repo root, inside the wrap')
    su.add_argument('--role', choices=('verifier', 'sidekick'), default='verifier')
    c = sub.add_parser('classify', help='profiles, risk class, and verify settings for a change')
    p = sub.add_parser('policy', help='forbid rules on added lines, and test-touch')
    for s in (c, p):
        s.add_argument('--base')
        s.add_argument('--head')
        s.add_argument('--working-tree', action='store_true')
    c.add_argument('--paths', nargs='+', metavar='GLOB', help="a brief's Scope, expanded against tracked files")
    c.add_argument('--escalate', action='append', default=[], metavar='REASON',
                   help='an escalation the paths do not show, such as an escalated plan')
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
    sub.add_parser('roster', help='the host roster: which agents fill the roles (no repo needed)')
    f = sub.add_parser('fleet', help='every run on the host and each skills build (no repo needed, read-only)')
    f.add_argument('--since', metavar='YYYY-MM-DD', help='only runs that started on or after this date')
    f.add_argument('--runs', type=Path, help='runs directory (default: the host kitchen runs)')
    c = sub.add_parser('counters', help="one run store's counters as JSON (no repo needed, read-only)")
    c.add_argument('store', type=Path)
    lr = sub.add_parser('ledger-retro', help="write a run's rows to the repo ledger, replacing its earlier ones (no repo needed)")
    lr.add_argument('store', type=Path)
    lr.add_argument('ledger', type=Path)
    lr.add_argument('--run', required=True)
    lr.add_argument('--ts', required=True)
    lc = sub.add_parser('ledger-catch', help='add a catch to the repo ledger (no repo needed)')
    lc.add_argument('store', type=Path)
    lc.add_argument('ledger', type=Path)
    lc.add_argument('layer')
    lc.add_argument('text')
    lc.add_argument('--run', required=True)
    lc.add_argument('--ts', required=True)
    lc.add_argument('--unit', help='the unit whose scope is the area (e.g. 003)')
    ls = sub.add_parser('lessons', help="the repo's lessons with their counters, and candidates from the ledger")
    ls.add_argument('--all', action='store_true', help=f'every candidate, not the {CANDIDATES_SHOWN} with the most runs')
    lsub = ls.add_subparsers(dest='lessons_cmd')
    la = lsub.add_parser('add', help='stage a proposed lesson for a candidate, with the rule the master wrote')
    la.add_argument('kind', choices=LESSON_KINDS)
    la.add_argument('cls', metavar='class')
    la.add_argument('area')
    la.add_argument('rule')
    la.add_argument('--match', default='', help="the candidate's match: the gate check, policy rule or steer kind")
    la.add_argument('--layer', help='the layer that should catch it (default: from the kind)')
    ld = lsub.add_parser('dismiss', help='hide a candidate whose evidence shares no cause, until newer trouble comes back')
    ld.add_argument('kind', choices=LESSON_KINDS)
    ld.add_argument('cls', metavar='class')
    ld.add_argument('area')
    ld.add_argument('--match', default='')
    ld.add_argument('--note', required=True, help='why the evidence shares no cause')
    lst = lsub.add_parser('stamp', help="write the active lessons for a brief's scope into its Lessons section")
    lst.add_argument('brief', type=Path)
    lpr = lsub.add_parser('promote', help="draft a lesson's promotion proposal for the human (writes nothing in the repo)")
    lpr.add_argument('id')
    lpr.add_argument('--out', type=Path, help='write the draft here instead of stdout')
    lt = lsub.add_parser('set', help="move a lesson's status: proposed, active, promoted, retired")
    lt.add_argument('id')
    lt.add_argument('status', choices=LESSON_STATUS)
    lt.add_argument('--rule', help='rewrite the rule')
    lt.add_argument('--note', help='promoted: the commit and check that enforce it; retired: why')
    lp = sub.add_parser('lesson-packet', help="the verifier packet's Lessons section for these briefs (no repo needed)")
    lp.add_argument('briefs', type=Path, nargs='+')
    sub.add_parser('statedir', help="this repo's kitchen state directory")
    t = sub.add_parser('timing', help="the slowest recent passing run of each profile's stage, and their sum")
    t.add_argument('profiles', nargs='*')
    t.add_argument('--stage', choices=STAGES, default='behavioral')
    t.add_argument('--deadline', action='store_true', help='the default verifier deadline and its parts')
    t.add_argument('--with-setup', action='store_true', help='with --deadline: count the last recorded setup run')
    args = ap.parse_args(argv)

    if args.cmd == 'roster':
        return roster(args.json)
    if args.cmd == 'fleet':
        return fleet(args.runs or pstack_state() / 'kitchen/runs', args.since, args.json)
    if args.cmd == 'counters':
        print(json.dumps(run_counters(args.store)))
        return 0
    if args.cmd == 'ledger-retro':
        ledger_retro(args.store, args.ledger, args.run, args.ts)
        return 0
    if args.cmd == 'lesson-packet':
        sys.stdout.write(lesson_packet(args.briefs))
        return 0
    if args.cmd == 'ledger-catch':
        try:
            ledger_catch(args.store, args.ledger, args.run, args.ts, args.layer, args.text, args.unit)
        except ConfigError as e:
            print(f'kitchen: {e}', file=sys.stderr)
            return 1
        return 0
    try:
        if args.cmd == 'statedir':
            print(state_dir(repo_root(args.repo)))
            return 0
        root = repo_root(args.repo)
        if args.cmd == 'timing' and args.deadline:
            r = verify_deadline(root, args.profiles, args.with_setup)
            emit(r, args.json, deadline_text(r))
            return 0
        if args.cmd == 'timing':
            r = gate_timing(root, args.profiles, args.stage)
            emit(r, args.json, f'{args.stage}: {r["seconds"]}s'
                 + ''.join(f'\n  {p} {s}s' for p, s in r['profiles'].items())
                 + (f'\n  unmeasured: {", ".join(r["unmeasured"])}' if r['unmeasured'] else ''))
            return 0
        if args.cmd == 'where':
            kind, path = host_kitchen(root)
            if args.host:
                print(path)
                return 0
            try:
                src = locate(root, args.at, args.config)
                used = {'source': src.kind, 'path': src.label}
            except ConfigError:
                used = {'source': None, 'path': None}
            emit({**used, 'host': {'source': kind, 'path': str(path), 'exists': path.is_file()}}, args.json,
                 (f'{used["source"]}: {used["path"]}' if used['source'] else 'no kitchen')
                 + f'\nhost ({kind}): {path}' + ('' if path.is_file() else ' (absent)'))
            return 0
        kitchen, source = load(root, args.at, args.config)
        INVOCATION[:] = ['--repo', str(root)] + (['--config', args.config] if args.config else []) \
            + (['--at', args.at] if args.at else [])
        if kitchen.verify and args.cmd in ('validate', 'doctor'):
            print(f'kitchen: warning: [verify] {", ".join(sorted(kitchen.verify))} moved to the host roster\'s '
                  '[verifier]; remove it from kitchen.toml', file=sys.stderr)
        if kitchen.review['legacy'] and args.cmd in ('validate', 'doctor'):
            print(f'kitchen: warning: review.{", review.".join(kitchen.review["legacy"])} are ignored: the kitchen tunes no '
                  'reviewer; remove them from kitchen.toml', file=sys.stderr)
        if args.cmd == 'lessons':
            path, ledger = lessons_path(root, source), state_dir(root) / 'ledger.tsv'
            today = time.strftime('%Y-%m-%d', time.gmtime())
            if args.lessons_cmd == 'add':
                x = lessons_add(path, ledger, args.kind, args.cls, args.area, args.rule, args.layer, today, args.match)
                emit({'id': x.id, 'path': str(path)}, args.json, f'{x.id} proposed in {path}: {x.rule}')
            elif args.lessons_cmd == 'dismiss':
                lessons_dismiss(ledger, args.kind, args.cls, args.area, args.match, args.note,
                                time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()))
                emit({'dismissed': True}, args.json, 'dismissed until newer trouble of this kind comes back')
            elif args.lessons_cmd == 'promote':
                draft = promotion_draft(path, ledger, args.id)
                if args.out:
                    args.out.parent.mkdir(parents=True, exist_ok=True)
                    args.out.write_text(draft)
                    print(args.out)
                else:
                    sys.stdout.write(draft)
            elif args.lessons_cmd == 'stamp':
                picked = stamp_lessons(args.brief, path)
                if picked or args.json:
                    emit({'lessons': [x.id for x in picked]}, args.json, f'lessons: {" ".join(x.id for x in picked)}')
            elif args.lessons_cmd == 'set':
                x = lessons_set(path, args.id, args.status, args.rule, args.note,
                                time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()))
                emit({'id': x.id, 'status': args.status, 'path': str(path)}, args.json, f'{x.id} {args.status}: {x.rule}')
            else:
                r = lessons_report(path, ledger)
                emit(r, args.json, lessons_text(r, args.all))
            return 0
        if args.cmd == 'snapshot':
            if source.kind in ('user', 'roster'):
                args.dir.mkdir(parents=True, exist_ok=True)
                snap = args.dir / f'{hashlib.sha256(source.text.encode()).hexdigest()[:12]}.toml'
                if not snap.exists():
                    with tempfile.NamedTemporaryFile('w', dir=args.dir, delete=False) as f:
                        f.write(source.text)
                    os.replace(f.name, snap)
                print(snap.resolve())
            return 0
        if args.cmd == 'validate':
            emit({'ok': True, 'source': source.kind, 'path': source.label, 'profiles': list(kitchen.profiles),
                  'self': kitchen.review['self'], 'review_engine': kitchen.review['engine'] or None,
                  'landing': kitchen.landing, 'setup': kitchen.scratch_setup}, args.json,
                 f'ok: {len(kitchen.profiles)} profiles ({", ".join(kitchen.profiles)})\nsource: {source.kind} {source.label}'
                 + (f'\nreview engine: {kitchen.review["engine"]} (required: each accepted unit\'s review note cites a run)'
                    if kitchen.review['engine'] else ''))
            return 0
        if args.cmd == 'setup':
            r = run_setup(root, kitchen, args.role)
            emit(r, args.json, (f'setup: ok ({len(r["commands"])} commands' + (f', log {r["log"]}' if r['log'] else '') + ')')
                 if r['passed'] else f'setup: FAIL exit {r["exit"]} (log {r["log"]})\n' + '\n'.join(f'  | {t}' for t in r['tail']))
            return 0 if r['passed'] else 2
        if args.cmd == 'classify':
            if not args.paths:
                args.paths = None
            changed = changes(root, args)
            r = classify(kitchen, changed, getattr(args, 'outside', []), args.escalate)
            text = [f'risk: {r["risk"]}', f'profiles: {", ".join(r["profiles"]) or "none"}',
                    f'diff_lines: {r["diff_lines"]}',
                    f'verify: {r["verify"]["mode"]} by {r["verify"]["kind"]} verifier', f'sample: {r["sample"]}']
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
            checks = doctor(root, kitchen, source, args.run)
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
