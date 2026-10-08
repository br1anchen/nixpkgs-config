"""kitchen.py against a throwaway repo: the kitchen.toml schema, classify,
gate, policy, and doctor, end to end through the command line."""
import json
import os
import re
import subprocess
import sys
import tempfile
import textwrap
import time
import unittest
from pathlib import Path

import tomllib

root = Path(__file__).resolve().parents[1]
skill = root / 'config/pstack/skills/pstack-kitchen'
script = skill / 'scripts/kitchen.py'
sys.path.insert(0, str(script.parent))
import kitchen

KITCHEN = textwrap.dedent('''\
    version = 1

    [profile.app]
    paths = ["src/**", "tests/**"]
    fast = ["test -f src/app.py"]
    behavioral = ["true"]
    tests = ["tests/**"]
    require_tests = true
    sample = 0.2

    [profile.docs]
    paths = ["docs/**", "**/*.md"]
    fast = ["test -d docs"]
    verify = "gates"
    sample = 0.0

    [profile.contracts]
    paths = ["contracts/**"]
    fast = ["true"]
    verify = "unit"

    [escalate]
    paths = ["contracts/**"]
    manifests = ["requirements.txt"]
    max_profiles = 1
    max_diff_lines = 50

    [[policy.forbid]]
    id = "no-print"
    pattern = '\\bprint\\('
    paths = ["src/**"]
    message = "use the logger"
    source = "AGENTS.md#logging"

    [coverage]
    ignore = [".agents/**", "requirements.txt"]
    ''')

FILES = {
    'src/app.py': 'def main():\n    return 1\n',
    'src/util.py': 'X = 1\n',
    'tests/test_app.py': 'def test_main():\n    assert True\n',
    'docs/guide.md': '# Guide\n',
    'contracts/api.json': '{}\n',
    'README.md': '# Demo\n',
    'requirements.txt': 'requests\n',
}


class KitchenTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.repo = Path(self.tmp.name) / 'repo'
        self.env = {**{k: v for k, v in os.environ.items() if k != 'PSTACK_PLACEMENT'}, 'XDG_STATE_HOME': str(Path(self.tmp.name) / 'state'),
                    'PSTACK_KITCHEN_ROSTER': str(Path(self.tmp.name) / 'no-roster.toml'),
                    'GIT_AUTHOR_NAME': 't', 'GIT_AUTHOR_EMAIL': 't@t',
                    'GIT_COMMITTER_NAME': 't', 'GIT_COMMITTER_EMAIL': 't@t'}
        self.repo.mkdir()
        self.git('init', '-q')
        for path, text in {**FILES, '.agents/kitchen.toml': KITCHEN}.items():
            self.write(path, text)
        self.base = self.commit('init')

    def git(self, *args):
        return subprocess.run(['git', *args], cwd=self.repo, env=self.env, check=True,
                              capture_output=True, text=True).stdout.strip()

    def write(self, path, text):
        f = self.repo / path
        f.parent.mkdir(parents=True, exist_ok=True)
        f.write_text(text)

    def commit(self, message):
        self.git('add', '-A')
        self.git('commit', '-q', '-m', message)
        return self.git('rev-parse', 'HEAD')

    def run_kitchen(self, *args, code=0):
        result = subprocess.run([sys.executable, str(script), *args], cwd=self.repo, env=self.env,
                                capture_output=True, text=True, check=False)
        self.assertEqual(result.returncode, code, result.stdout + result.stderr)
        self.stdout = result.stdout
        return result.stdout + result.stderr

    def data(self, *args, code=0):
        self.run_kitchen('--json', *args, code=code)
        return json.loads(self.stdout)

    def change(self, files):
        for path, text in files.items():
            self.write(path, text)
        return self.commit('change')

    def classify(self, files):
        head = self.change(files)
        return self.data('classify', '--base', self.base, '--head', head)


class GlobTests(unittest.TestCase):
    def test_globs_cross_directories_only_with_double_star(self):
        cases = [
            ('*.md', 'README.md', True), ('*.md', 'docs/a.md', False),
            ('**/*.md', 'README.md', True), ('**/*.md', 'docs/x/a.md', True),
            ('src/**', 'src/a/b.py', True), ('src/**', 'srcx/a.py', False),
            ('a/**/b.py', 'a/b.py', True), ('a/**/b.py', 'a/x/y/b.py', True),
            ('crates/*/Cargo.toml', 'crates/core/Cargo.toml', True),
            ('crates/*/Cargo.toml', 'crates/a/b/Cargo.toml', False), ('?.py', 'a.py', True),
        ]
        for pattern, path, expected in cases:
            with self.subTest(pattern=pattern, path=path):
                self.assertEqual(bool(kitchen.glob_regex(pattern).match(path)), expected)


class SchemaTests(KitchenTests):
    def test_reference_example_is_valid(self):
        k = kitchen.parse(tomllib.loads((skill / 'references/kitchen-example.toml').read_text()))
        self.assertEqual(list(k.profiles), ['ui', 'engine', 'docs'])
        self.assertEqual(k.review['escalated']['budget'], 8)
        self.assertTrue(k.review['landing']['walkthrough'])
        self.assertEqual(k.scratch_setup, ['pnpm install --frozen-lockfile'])

    def test_validate_names_the_bad_key(self):
        cases = [
            ('fast =', 'fsat =', 'profile.app: unknown key fsat'),
            ('tests = ["tests/**"]\n', '', 'require_tests needs tests globs'),
            ("pattern = '\\bprint\\('", "pattern = '('", 'policy.forbid[0].pattern'),
            ('verify = "unit"', 'verify = "sometimes"', 'profile.contracts.verify: expected one of gates, batch, unit'),
            ('version = 1', 'version = 2', 'version: expected 1'),
        ]
        for old, new, message in cases:
            with self.subTest(new=new):
                self.assertIn(old, KITCHEN)
                self.write('.agents/kitchen.toml', KITCHEN.replace(old, new, 1))
                self.assertIn(message, self.run_kitchen('validate', code=1))
        self.write('.agents/kitchen.toml', KITCHEN + '\n[[policy.forbid]]\nid = "no-print"\npattern = "x"\nmessage = "m"\n')
        self.assertIn('policy.forbid[1].id', self.run_kitchen('validate', code=1))

    def test_missing_kitchen_points_at_setup(self):
        (self.repo / '.agents/kitchen.toml').unlink()
        self.assertIn('pstack-kitchen-setup', self.run_kitchen('validate', code=1))


class ClassifyTests(KitchenTests):
    def test_routine_change_takes_its_profile_settings(self):
        r = self.classify({'src/util.py': 'X = 2\n', 'tests/test_app.py': 'def test_main():\n    assert 1\n'})
        self.assertEqual((r['risk'], r['profiles'], r['escalate']), ('routine', ['app'], []))
        self.assertEqual(r['verify'], {'mode': 'batch', 'kind': 'routine'})
        self.assertEqual(r['sample'], 0.2)
        self.assertEqual((r['review']['engine'], r['review']['style'], r['review']['budget']), ('none', 'standard', 4))

    def test_docs_only_change_needs_no_verifier(self):
        r = self.classify({'docs/guide.md': '# Guide\n\nMore.\n'})
        self.assertEqual((r['risk'], r['verify']['mode'], r['sample']), ('routine', 'gates', 0.0))

    def test_each_escalation_reason(self):
        cases = [
            ({'contracts/api.json': '{"a": 1}\n'}, 'escalate path: contracts/api.json'),
            ({'requirements.txt': 'requests\nhttpx\n'}, 'dependency manifest: requirements.txt'),
            ({'src/util.py': 'X = 3\n', 'docs/guide.md': '# G\n'}, '2 profiles touched: app, docs (max 1)'),
            ({'src/big.py': 'x = 1\n' * 60}, '60 diff lines (max 50)'),
            ({'tools/gen.py': 'pass\n'}, '1 files no profile covers: tools/gen.py'),
        ]
        for files, reason in cases:
            with self.subTest(reason=reason):
                r = self.classify(files)
                self.assertEqual(r['risk'], 'escalated')
                self.assertIn(reason, r['escalate'])
                self.assertEqual(r['verify'], {'mode': 'unit', 'kind': 'escalated'})
                self.assertEqual((r['sample'], r['review']['style']), (1.0, 'thorough'))
                self.base = self.git('rev-parse', 'HEAD')

    def test_scope_globs_expand_against_tracked_files(self):
        r = self.data('classify', '--paths', 'src/**', 'src/new.py')
        self.assertEqual([f['path'] for f in r['files']], ['src/app.py', 'src/util.py', 'src/new.py'])
        self.assertEqual(r['profiles'], ['app'])

    def test_scope_glob_for_a_new_directory_maps_to_its_profile(self):
        r = self.data('classify', '--paths', 'src/newpkg/**', 'contracts/v2/*.json')
        self.assertEqual([f['path'] for f in r['files']], ['src/newpkg/x', 'contracts/v2/x.json'])
        self.assertEqual((r['profiles'], r['risk']), (['app', 'contracts'], 'escalated'))
        self.assertEqual((r['behavioral'], r['max_batch_diff']), (['app'], 800))

    def test_scope_outside_the_repo_is_bookkeeping(self):
        r = self.data('classify', '--paths', '/elsewhere/store/reports/007-x.md', f'{self.repo}/src/util.py')
        self.assertEqual(([f['path'] for f in r['files']], r['outside'], r['risk']),
                         (['src/util.py'], ['/elsewhere/store/reports/007-x.md'], 'routine'))
        r = self.data('classify', '--paths', '/elsewhere/store/reports/007-x.md')
        self.assertEqual((r['risk'], r['bookkeeping'], r['escalate'], r['verify']['mode']), ('routine', True, [], 'gates'))

    def test_statedir_is_shared_by_worktrees_and_keeps_the_old_ledger(self):
        main = self.run_kitchen('statedir').strip()
        wt = Path(self.tmp.name) / 'wt'
        self.git('worktree', 'add', '-q', '--detach', str(wt), 'HEAD')
        self.assertEqual(self.run_kitchen('--repo', str(wt), 'statedir').strip(), main)
        # A ledger under the older per-checkout key moves to the shared one.
        import hashlib
        old = Path(self.tmp.name) / 'state/pstack/kitchen/repos' / f"wt-{hashlib.sha256(str(wt).encode()).hexdigest()[:8]}"
        old.mkdir(parents=True)
        (old / 'ledger.tsv').write_text('ts\trun\tkind\tclass\tdetail\n')
        Path(main, 'ledger.tsv').unlink(missing_ok=True)
        self.run_kitchen('--repo', str(wt), 'statedir')
        self.assertTrue(Path(main, 'ledger.tsv').exists())

    def test_roster_and_statedir(self):
        roster = Path(self.tmp.name) / 'roster.toml'
        roster.write_text('[sidekick]\nkind = "pi"\nargs = ["--model", "devin/swe-2"]\n'
                          '[sidekick.fallback]\nkind = "devin"\n[consultant]\nkind = "codex"\n')
        self.env['PSTACK_KITCHEN_ROSTER'] = str(roster)
        r = self.data('roster')
        self.assertEqual(r['sidekick'], {'kind': 'pi', 'args': ['--model', 'devin/swe-2'],
                                         'fallback': {'kind': 'devin', 'args': []}})
        self.assertEqual(r['consultant']['kind'], 'codex')
        self.assertIn('pstack/kitchen/repos/repo-', self.run_kitchen('statedir'))

    def test_roster_verifier_defaults(self):
        roster = Path(self.tmp.name) / 'roster.toml'
        roster.write_text('[sidekick]\nkind = "pi"\n')
        self.env['PSTACK_KITCHEN_ROSTER'] = str(roster)
        v = self.data('roster')['verifier']
        self.assertEqual(v['routine'], {'kind': 'sidekick', 'args': [], 'fallback': None, 'source': 'sidekick'})
        self.assertEqual(v['escalated'], {'kind': 'claude', 'args': ['--model', 'claude-opus-5-5'],
                                          'fallback': None, 'source': 'default'})

    def test_roster_verifier_entries_and_master_sentinel(self):
        roster = Path(self.tmp.name) / 'roster.toml'
        roster.write_text('[verifier]\nkind = "pi"\nargs = ["--model", "m"]\n'
                          '[verifier.fallback]\nkind = "claude"\nargs = ["--model", "s"]\n'
                          '[verifier.escalated]\nkind = "master"\n')
        self.env['PSTACK_KITCHEN_ROSTER'] = str(roster)
        v = self.data('roster')['verifier']
        self.assertEqual(v['routine'], {'kind': 'pi', 'args': ['--model', 'm'],
                                        'fallback': {'kind': 'claude', 'args': ['--model', 's']}, 'source': 'roster'})
        self.assertEqual(v['escalated'], {'kind': 'master', 'args': [], 'fallback': None, 'source': 'roster'})

    def test_repo_verify_kinds_warn_only_when_set(self):
        self.assertNotIn('moved to the host roster', self.run_kitchen('validate'))
        self.write('.agents/kitchen.toml', KITCHEN + '\n[verify]\nescalated_kind = "master"\n')
        self.assertIn('moved to the host roster', self.run_kitchen('validate'))
        self.assertTrue(self.data('validate')['ok'])

    def test_working_tree_counts_untracked_files(self):
        self.write('docs/new.md', 'a\nb\n')
        self.write('docs/guide.md', '# Guide\nmore\n')
        r = self.data('classify', '--working-tree')
        self.assertEqual(sorted(f['path'] for f in r['files']), ['docs/guide.md', 'docs/new.md'])
        self.assertEqual(r['diff_lines'], 3)

    def test_at_reads_the_kitchen_of_that_revision(self):
        self.change({'.agents/kitchen.toml': KITCHEN.replace('max_diff_lines = 50', 'max_diff_lines = 5')})
        head = self.change({'src/util.py': 'X = 1\nY = 2\nZ = 3\nW = 4\nV = 5\nU = 6\n',
                            'tests/test_app.py': 'def test_main():\n    assert 2\n'})
        now = self.data('classify', '--base', f'{head}~1', '--head', head)
        then = self.data('--at', self.base, 'classify', '--base', f'{head}~1', '--head', head)
        self.assertEqual((now['risk'], then['risk']), ('escalated', 'routine'))


class HistoryTests(KitchenTests):
    def test_history_classifies_each_commit_with_its_findings(self):
        self.change({'src/util.py': 'print(1)\n', 'tests/test_app.py': 'x = 2\n'})
        self.change({'contracts/api.json': '{"b": 2}\n'})
        rows = self.data('history', '--last', '5')['commits']
        self.assertEqual([(r['risk'], r['profiles'], r['findings']) for r in rows], [
            ('escalated', ['contracts'], []), ('routine', ['app'], ['no-print'])])
        self.assertIn('1 of 2 escalated; 1 with policy findings', self.run_kitchen('history'))


class GateTests(KitchenTests):
    def test_passing_gate_and_logs(self):
        r = self.data('gate', 'app', 'fast')
        self.assertTrue(r['passed'])
        self.assertTrue(Path(r['commands'][0]['log']).exists())
        self.assertEqual(self.data('gate', 'app', 'landing'), {'profile': 'app', 'stage': 'landing', 'role': 'sidekick',
                                                                'passed': True, 'commands': [], 'waited': 0.0})

    def test_failing_gate_stops_prints_the_log_tail_and_exits_2(self):
        self.write('.agents/kitchen.toml', KITCHEN.replace(
            'fast = ["test -f src/app.py"]', 'fast = ["echo boom; exit 3", "echo second"]'))
        out = self.run_kitchen('gate', 'app', 'fast', code=2)
        self.assertIn('app fast: FAIL', out)
        self.assertIn('exit 3', out)
        self.assertIn('| boom', out)
        self.assertNotIn('echo second', out)
        self.assertEqual([c['exit'] for c in self.data('gate', 'app', 'fast', '--keep-going', code=2)['commands']], [3, 0])
        only = self.data('gate', 'app', 'fast', '--only', '1')['commands']
        self.assertEqual([(c['command'], c['log'].endswith('app-fast-1.log')) for c in only], [('echo second', True)])
        self.assertIn('--only 2: app.fast has 2 commands', self.run_kitchen('gate', 'app', 'fast', '--only', '2', code=1))

    def test_heavy_gate_releases_its_slot(self):
        self.write('.agents/kitchen.toml', KITCHEN.replace('sample = 0.2', 'sample = 0.2\nheavy = true'))
        self.data('gate', 'app', 'fast')
        self.data('gate', 'app', 'fast')
        locks = list((Path(self.tmp.name) / 'state/pstack/kitchen/repos').glob('heavy-*.lock'))
        self.assertEqual([p.name for p in locks], ['heavy-0.lock'])

    def test_commands_see_the_role_they_run_for(self):
        self.write('.agents/kitchen.toml', KITCHEN.replace('fast = ["test -f src/app.py"]',
                                                           'fast = ["test \\"$PSTACK_KITCHEN_ROLE\\" = sidekick"]'))
        self.assertTrue(self.data('gate', 'app', 'fast')['passed'])
        self.data('gate', 'app', 'fast', '--role', 'verifier', code=2)
        self.env['PSTACK_KITCHEN_ROLE'] = 'verifier'
        self.assertEqual(self.data('gate', 'app', 'fast', code=2)['role'], 'verifier')

    def test_each_gate_gets_its_own_short_tmpdir_removed_after(self):
        seen = Path(self.tmp.name) / 'seen-tmpdir'
        base = Path(self.tmp.name) / 'gt'
        base.mkdir()
        dead, live = base / 'kg-999999999-dead', base / f'kg-{os.getpid()}-live'
        dead.mkdir(), live.mkdir()
        self.env['PSTACK_KITCHEN_GATE_TMP'] = str(base)
        self.write('.agents/kitchen.toml', KITCHEN.replace(
            'fast = ["test -f src/app.py"]', f'fast = ["echo \\"$TMPDIR\\" > {seen} && touch \\"$TMPDIR/leftover\\""]'))
        self.assertTrue(self.data('gate', 'app', 'fast')['passed'])
        used = Path(seen.read_text().strip())
        self.assertEqual(used.parent, base)
        self.assertTrue(used.name.startswith('kg-'))
        self.assertFalse(used.exists())
        self.assertFalse(dead.exists())
        self.assertTrue(live.exists())

    def test_a_failure_under_load_is_rerun_once_and_marked_flaky(self):
        mark = Path(self.tmp.name) / 'ran-once'
        self.write('.agents/kitchen.toml', KITCHEN.replace(
            'fast = ["test -f src/app.py"]', f'fast = ["test -e {mark} || {{ touch {mark}; exit 1; }}"]'))
        self.env['PSTACK_KITCHEN_RETRY_LOAD'] = '-1'
        r = self.data('gate', 'app', 'fast')
        c = r['commands'][0]
        self.assertTrue(r['passed'])
        self.assertTrue(c['flaky'])
        self.assertEqual(c['retried']['first_exit'], 1)
        self.assertTrue(Path(c['retried']['first_log']).exists())
        mark.unlink()
        out = self.run_kitchen('gate', 'app', 'fast')
        self.assertIn('flaky under load: app fast', out)
        self.assertIn('after exit 1', out)
        mark.unlink()
        self.env['PSTACK_KITCHEN_RETRY_LOAD'] = 'off'
        self.assertNotIn('retried', self.data('gate', 'app', 'fast', code=2)['commands'][0])

    def test_gate_tmpdirs_default_to_slash_tmp(self):
        os.environ.pop('PSTACK_KITCHEN_GATE_TMP', None)
        self.assertEqual(kitchen.gate_tmp_base(), Path('/tmp'))
        # mbx nests nix-shell.XXXXXX/mbx-session-XXXXXX/cache-agent.sock (52 bytes)
        # under it; a socket path must fit in 104 bytes on macOS.
        self.assertLess(len('/tmp/kg-4194304-abcdefgh/') + 52, 104)

    def test_gates_share_the_machine_slots(self):
        self.write('.agents/kitchen.toml', KITCHEN.replace('fast = ["test -f src/app.py"]', 'fast = ["sleep 2"]'))
        env = {**self.env, 'PSTACK_KITCHEN_GATE_SLOTS': '1'}
        procs = [subprocess.Popen([sys.executable, str(script), '--json', 'gate', 'app', 'fast'], cwd=self.repo,
                                  env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True) for _ in range(2)]
        results = [json.loads(p.communicate()[0]) for p in procs]
        self.assertEqual(sorted(r['waited'] >= 1.5 for r in results), [False, True])

    def test_unknown_profile(self):
        self.assertIn('no profile web', self.run_kitchen('gate', 'web', 'fast', code=1))


class WrapTests(KitchenTests):
    def setUp(self):
        super().setUp()
        # A wrap like `nix develop --command`: noise on stdout, a tool only it
        # puts on PATH, and a count of how often it is entered.
        self.write('wrap/bin/inner-tool', '#!/bin/sh\nexit 0\n')
        (self.repo / 'wrap/bin/inner-tool').chmod(0o755)
        self.write('wrap/enter.sh', '#!/usr/bin/env bash\necho "shell hook says hi"\n'
                   'echo x >> "$(dirname "$0")/entered"\nPATH="$(dirname "$0")/bin:$PATH" exec "$@"\n')
        (self.repo / 'wrap/enter.sh').chmod(0o755)
        self.entered = self.repo / 'wrap/entered'

    def kitchen(self, extra='', fast='["inner-tool", "test \\"$KITCHEN_WRAPPED\\" = 1"]'):
        self.write('.agents/kitchen.toml', KITCHEN.replace('fast = ["test -f src/app.py"]', f'fast = {fast}')
                   .replace('[coverage]', '[run]\nwrap = "wrap/enter.sh"\n\n[coverage]') + extra)

    def test_gate_enters_the_wrap_once_and_keeps_per_command_logs(self):
        self.kitchen()
        r = self.data('gate', 'app', 'fast')
        self.assertTrue(r['passed'], r)
        self.assertEqual([c['exit'] for c in r['commands']], [0, 0])
        self.assertEqual(self.entered.read_text(), 'x\n')

    def test_a_failing_wrap_is_a_failed_gate_with_its_log(self):
        self.kitchen()
        self.write('wrap/enter.sh', '#!/usr/bin/env bash\necho "no devshell"; exit 7\n')
        r = self.data('gate', 'app', 'fast', code=2)
        self.assertEqual((r['commands'][0]['exit'], r['commands'][0]['tail']), (7, ['no devshell']))

    def test_profile_wrap_can_opt_out(self):
        self.kitchen(fast='["test -z \\"$KITCHEN_WRAPPED\\""]')
        self.write('.agents/kitchen.toml', (self.repo / '.agents/kitchen.toml').read_text()
                   .replace('require_tests = true', 'require_tests = true\nwrap = ""'))
        self.assertTrue(self.data('gate', 'app', 'fast')['passed'])
        self.assertFalse(self.entered.exists())

    def scratch(self, setup, wrap=True):
        self.kitchen()
        text = (self.repo / '.agents/kitchen.toml').read_text()
        if not wrap:
            text = text.replace('[run]\nwrap = "wrap/enter.sh"\n\n', '')
        self.write('.agents/kitchen.toml', text + '\n[scratch]\nsetup = ' + json.dumps(setup) + '\n')

    def test_a_setup_run_is_its_own_timing_row_never_a_gate_sample(self):
        self.scratch(['true'])
        self.data('setup')
        state_dir = Path(subprocess.run([sys.executable, str(script), '--repo', str(self.repo), 'statedir'],
                                        env=self.env, capture_output=True, text=True, check=True).stdout.strip())
        rows = [line.split('\t') for line in (state_dir / 'timings.tsv').read_text().splitlines()]
        self.assertEqual([(r[1], r[2], r[3], r[4]) for r in rows], [('-', 'setup', 'verifier', 'pass')])
        self.assertEqual(self.data('timing', 'app', '--stage', 'behavioral')['seconds'], 0)

    def test_two_run_slugs_reach_setup_the_wrap_and_gate_commands(self):
        self.kitchen(fast='["printf \'%s\' \\"$PSTACK_KITCHEN_RUN\\" > gate-run"]')
        toml = self.repo / '.agents/kitchen.toml'
        toml.write_text(toml.read_text() + '\n[scratch]\nsetup = ["printf \'%s\' \\"$PSTACK_KITCHEN_RUN\\" > setup-run"]\n')
        for slug in ('alpha', 'beta'):
            with self.subTest(slug):
                self.env['PSTACK_KITCHEN_RUN'] = slug
                self.entered.unlink(missing_ok=True)
                self.assertTrue(self.data('setup')['passed'])
                self.assertTrue(self.data('gate', 'app', 'fast')['passed'])
                self.assertEqual(((self.repo / 'setup-run').read_text(), (self.repo / 'gate-run').read_text()), (slug, slug))
                self.assertTrue(self.entered.exists())

    def test_setup_with_nothing_declared_passes(self):
        self.kitchen()
        r = self.data('setup')
        self.assertEqual((r['passed'], r['commands'], r['log']), (True, [], None))
        self.assertFalse(self.entered.exists())

    def test_setup_runs_in_order_inside_the_wrap_entered_once_as_the_verifier(self):
        self.scratch(['echo one >> out', 'echo two >> out', 'printf "%s" "$PSTACK_KITCHEN_ROLE" > role',
                      'test "$KITCHEN_WRAPPED" = "" || true'])
        r = self.data('setup')
        self.assertTrue(r['passed'], r)
        self.assertEqual((self.repo / 'out').read_text(), 'one\ntwo\n')
        self.assertEqual((self.repo / 'role').read_text(), 'verifier')
        self.assertEqual(self.entered.read_text(), 'x\n')
        self.assertTrue(Path(r['log']).exists())

    def test_setup_stops_at_the_first_failure_with_the_log_tail(self):
        self.scratch(['true', 'echo boom; exit 3', 'touch never'])
        r = self.data('setup', code=2)
        self.assertEqual((r['passed'], r['exit']), (False, 3))
        self.assertIn('boom', r['tail'])
        self.assertFalse((self.repo / 'never').exists())
        self.assertIn('setup: FAIL exit 3', self.run_kitchen('setup', code=2))

    def test_a_failing_wrap_fails_setup_with_its_output(self):
        self.scratch(['touch ran'])
        self.write('wrap/enter.sh', '#!/usr/bin/env bash\necho "no devshell"; exit 7\n')
        r = self.data('setup', code=2)
        self.assertEqual((r['exit'], r['tail']), (7, ['no devshell']))
        self.assertFalse((self.repo / 'ran').exists())

    def test_setup_without_a_wrap_runs_from_the_repo_root(self):
        self.scratch(['pwd > where'], wrap=False)
        self.assertTrue(self.data('setup')['passed'])
        self.assertEqual((self.repo / 'where').read_text().strip(), str(self.repo.resolve()))

    def test_scratch_setup_is_validated(self):
        self.kitchen(extra='\n[scratch]\nsetup = "bun install"\n')
        self.assertIn('scratch.setup: expected a list of non-empty strings', self.run_kitchen('validate', code=1))
        self.kitchen(extra='\n[scratch]\ninstall = []\n')
        self.assertIn('scratch: unknown key install', self.run_kitchen('validate', code=1))

    def doctor_scratch(self):
        r = subprocess.run([sys.executable, str(script), '--json', 'doctor'], cwd=self.repo, env=self.env,
                           capture_output=True, text=True, check=False)
        return {x['check']: x for x in json.loads(r.stdout)['checks']}['scratch setup']

    def test_doctor_reports_setup_and_warns_only_for_a_lockfile_without_it(self):
        self.kitchen()
        self.assertEqual(self.doctor_scratch()['status'], 'ok')
        self.assertEqual(self.doctor_scratch()['detail'], 'none')
        self.write('package.json', '{}\n')
        self.assertEqual(self.doctor_scratch()['status'], 'ok')
        self.write('bun.lock', '{}\n')
        c = self.doctor_scratch()
        self.assertEqual(c['status'], 'warn')
        self.assertIn('package.json with a lockfile', c['detail'])
        self.scratch(['bun install --frozen-lockfile'])
        c = self.doctor_scratch()
        self.assertEqual((c['status'], c['detail']), ('ok', 'bun install --frozen-lockfile'))
        self.kitchen()
        for f in ('package.json', 'bun.lock'):
            (self.repo / f).unlink()
        self.write('pyproject.toml', '[project]\n')
        self.write('uv.lock', '\n')
        self.assertEqual(self.doctor_scratch()['status'], 'warn')

    def test_doctor_resolves_commands_inside_the_wrap(self):
        self.kitchen()
        self.write('.agents/kitchen.toml', (self.repo / '.agents/kitchen.toml').read_text()
                   .replace('fast = ["true"]', 'fast = ["nosuchtool"]'))
        c = {x['check']: x for x in self.data('doctor', code=3)['checks']}
        self.assertEqual(c['commands']['items'], ['contracts.fast: nosuchtool (inside wrap)'])
        self.assertEqual(self.entered.read_text(), 'x\n')


class PolicyTests(KitchenTests):
    def test_forbid_rule_on_added_lines_with_allow(self):
        head = self.change({
            'src/app.py': 'def main():\n    print("x")\n    print("y")  # kitchen-allow: no-print, CLI output\n',
            'docs/guide.md': '# Guide\nprint(1)\n',
            'tests/test_app.py': 'def test_main():\n    assert 2\n',
        })
        r = self.data('policy', '--base', self.base, '--head', head, code=2)
        self.assertEqual([(f['rule'], f['path'], f['line']) for f in r['findings']], [('no-print', 'src/app.py', 2)])
        self.assertEqual(r['findings'][0]['source'], 'AGENTS.md#logging')

    def test_test_touch(self):
        head = self.change({'src/util.py': 'X = 5\n'})
        r = self.data('policy', '--base', self.base, '--head', head, code=2)
        self.assertEqual([(f['rule'], f['profile']) for f in r['findings']], [('test-touch', 'app')])
        self.assertIn('src/util.py: [test-touch] profile app', self.run_kitchen('policy', '--base', self.base, '--head', head, code=2))
        self.assertEqual(self.data('history', '--last', '1')['commits'][0]['findings'], ['test-touch(app)'])
        head2 = self.change({'tests/test_app.py': 'def test_main():\n    assert 3\n'})
        self.assertEqual(self.data('policy', '--base', self.base, '--head', head2), {'findings': []})

    def test_working_tree(self):
        self.write('src/app.py', 'print(1)\n')
        self.write('tests/test_app.py', 'x = 1\n')
        r = self.data('policy', '--working-tree', code=2)
        self.assertEqual([f['rule'] for f in r['findings']], ['no-print'])


class DoctorTests(KitchenTests):
    def checks(self, *args, code=0):
        return {c['check']: c for c in self.data('doctor', *args, code=code)['checks']}

    def test_clean_kitchen(self):
        c = self.checks()
        self.assertEqual({k: v['status'] for k, v in c.items()}, {
            'coverage': 'ok', 'profiles': 'ok', 'commands': 'ok', 'fast gates': 'ok',
            'features': 'ok', 'verification skill': 'warn', 'scratch setup': 'ok',
            'verifier routine': 'ok', 'verifier fallback': 'ok', 'verifier escalated': 'ok'})

    def test_doctor_names_the_resolved_verifier_for_each_class(self):
        c = self.checks()
        self.assertIn("the run's current sidekick (source sidekick", c['verifier routine']['detail'])
        self.assertEqual(c['verifier fallback']['detail'], 'none')
        self.assertEqual(c['verifier escalated']['detail'],
                         'claude --model claude-opus-5-5 (source default); also used by verify --landing')
        roster = Path(self.tmp.name) / 'roster.toml'
        roster.write_text('[verifier]\nkind = "pi"\nargs = ["--model", "devin/swe-2", "--thinking", "high"]\n'
                          '[verifier.fallback]\nkind = "claude"\nargs = ["--model", "claude-haiku-5-5"]\n'
                          '[verifier.escalated]\nkind = "claude"\nargs = ["--model", "claude-sonnet-5-5"]\n')
        self.env['PSTACK_KITCHEN_ROSTER'] = str(roster)
        c = self.checks()
        self.assertEqual(c['verifier routine']['detail'], 'pi --model devin/swe-2 --thinking high (source roster)')
        self.assertEqual(c['verifier fallback']['detail'], 'claude --model claude-haiku-5-5 (source roster)')
        self.assertIn('claude --model claude-sonnet-5-5 (source roster)', c['verifier escalated']['detail'])
        roster.write_text('[verifier.escalated]\nkind = "master"\n[verifier]\nkind = "devin"\n')
        c = self.checks()
        self.assertEqual(c['verifier routine']['detail'], 'devin (model unspecified) (source roster)')
        self.assertIn("the master's own kind (source roster)", c['verifier escalated']['detail'])

    def test_problems_fail(self):
        self.change({'tools/gen.py': 'pass\n'})
        self.write('.agents/kitchen.toml', KITCHEN.replace('fast = ["true"]', 'fast = ["cd src && nosuchtool --x"]')
                   .replace('verify = "unit"', 'verify = "unit"\nfeatures = ["missing.md"]'))
        c = self.checks(code=3)
        self.assertEqual(c['coverage']['items'], ['tools/gen.py'])
        self.assertEqual(c['commands']['status'], 'ok')  # cd is a builtin; only the first word counts
        self.assertEqual(c['features']['items'], ['contracts: missing.md'])
        self.write('.agents/kitchen.toml', KITCHEN.replace('fast = ["true"]', 'fast = ["nosuchtool --x"]'))
        self.assertEqual(self.checks(code=3)['commands']['items'], ['contracts.fast: nosuchtool'])

    def test_verification_skill_and_review_engine(self):
        self.write('.agents/skills/verify-demo/SKILL.md', '---\nname: verify-demo\n---\n')
        self.write('.agents/kitchen.toml', KITCHEN + '\n[review]\nengine = "joo"\n')
        c = self.checks()
        self.assertEqual(c['verification skill'], {'check': 'verification skill', 'status': 'ok',
                                                   'detail': '.agents/skills/verify-demo', 'items': []})
        self.assertIn(c['review engine']['status'], ('ok', 'warn'))

    def test_run_records_a_baseline_and_fails_on_red(self):
        c = self.checks('--run')
        self.assertEqual(c['fast gates on HEAD']['status'], 'ok')
        self.assertIn('doctor: app pass in ', self.run_kitchen('doctor', '--run'))
        baseline = json.loads(next((Path(self.tmp.name) / 'state').rglob('baseline.json')).read_text())
        self.assertEqual(baseline['head'], self.base)
        self.assertEqual(sorted(baseline['profiles']), ['app', 'contracts', 'docs'])
        (self.repo / 'docs/guide.md').unlink()
        (self.repo / 'docs').rmdir()
        c = self.checks('--run', code=3)
        self.assertEqual(c['fast gates on HEAD']['status'], 'fail')
        self.assertEqual(c['baseline']['status'], 'warn')


if __name__ == '__main__':
    unittest.main()


class FleetTests(unittest.TestCase):
    """kitchen.py fleet and counters over fixture run stores."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.t = Path(self.tmp.name)
        self.runs = self.t / 'state/pstack/kitchen/runs'
        self.env = {k: v for k, v in os.environ.items() if k != 'PSTACK_PLACEMENT'} | {'XDG_STATE_HOME': str(self.t / 'state')}

    def store(self, name, pair=None, events=(), briefs=(), reports=(), verdicts=()):
        d = self.runs / name
        for sub in ('briefs', 'reports', 'verdicts', 'steers'):
            (d / sub).mkdir(parents=True)
        if pair is not None:
            (d / 'pair.json').write_text(json.dumps(pair))
        if events:
            rows = ['ts\tepoch\tactor\tevent\tunit\tdetail'] + [f'x\t{e}\t{a}\t{v}\t-\t{det}' for e, a, v, det in events]
            (d / 'events.tsv').write_text('\n'.join(rows) + '\n')
        for b in briefs:
            (d / 'briefs' / f'{b}.md').write_text('# Brief\n')
        for r, status in reports:
            (d / 'reports' / f'{r}.md').write_text(f'# Report\n\nstatus: {status}\n')
        for name_, status, units in verdicts:
            (d / 'verdicts' / f'{name_}.md').write_text(f'# Verdict\n\nstatus: {status}\nunits: {units}\n')
        return d

    def fleet(self, *args):
        r = subprocess.run([sys.executable, str(script), '--json', 'fleet', '--runs', str(self.runs), *args],
                           env=self.env, capture_output=True, text=True, check=True)
        out = json.loads(r.stdout)
        return {x['run']: x for x in out['runs']}, {x['build']: x for x in out['builds']}

    def test_verified_units_are_the_union_over_clean_non_landing_verdicts(self):
        self.store('a', pair={'git_root': str(self.t), 'sidekick': {'failovers': [{}, {}]},
                              'skill_builds': [{'path': '/s/one'}]},
                   events=[(100, 'master', 'init', ''), (160, 'master', 'wake', 'x'), (220, 'master', 'wake', 'verify:provider'),
                           (300, 'master', 'catch', 'gate'), (400, 'sidekick', 'gate-flaky', 'app')],
                   briefs=['001-a', '002-b', '003-c', '004-d'],
                   reports=[('001-a', 'done'), ('002-b', 'done'), ('003-c', 'done'), ('004-d', 'partial')],
                   verdicts=[('002-b-v1', 'clean', '001 002'), ('003-c-v1', 'reject', '003'), ('003-c-v2', 'clean', '003'),
                             ('003-c-v3', 'clean', '003'), ('005-e-v1', 'clean (gates only: docs)', '005'),
                             ('landing-v1', 'clean', 'landing'), ('002-b-v1-packet', 'clean', '999')])
        (self.t / 'state/pstack/builds.tsv').write_text('1\tabc123\t/s/one\n')
        runs, builds = self.fleet()
        a = runs['a']
        self.assertEqual((a['done_units'], a['verified_units'], a['gates_only_units'], a['landing']), (3, 4, 1, 'clean'))
        self.assertEqual((a['wakes'], a['wakes_per_verified'], a['failovers']), (2, 0.5, 2))
        self.assertEqual((a['verify_provider'], a['verify_missing'], a['gate_flaky'], a['catches']), (1, 0, 1, {'gate': 1}))
        self.assertEqual((a['clean_first_try'], a['build'], a['started'], a['last']), (2, 'abc123', 100, 400))
        self.assertEqual(builds['abc123']['runs'], 1)

    def test_mixed_and_unstamped_runs_get_their_own_build_rows(self):
        self.store('m', pair={'skill_builds': [{'path': '/s/one'}, {'path': '/s/two'}]}, events=[(10, 'master', 'wake', '')])
        self.store('u', pair={}, events=[(20, 'master', 'wake', '')])
        self.store('empty')
        runs, builds = self.fleet()
        self.assertEqual((runs['m']['build'], runs['u']['build'], runs['empty']['build']), ('mixed', 'unknown', 'unknown'))
        self.assertEqual(set(builds), {'mixed', 'unknown'})
        self.assertEqual(builds['unknown']['runs'], 2)
        self.assertEqual(builds['unknown']['eligible_runs'], 0)
        e = runs['empty']
        self.assertEqual((e['done_units'], e['verified_units'], e['wakes'], e['wakes_per_verified'], e['failovers'], e['started']),
                         (0, 0, 0, None, 0, None))

    def packet(self, run, name, agent=None, cls=None, outcome=None):
        lines = ['# Verify x', '', 'verdict: v']
        lines += [f'verifier-agent: {agent}'] if agent else []
        lines += [f'verifier-class: {cls}'] if cls else []
        lines += [f'verifier-outcome: {outcome}'] if outcome else []
        (self.runs / run / 'verdicts' / f'{name}-packet.md').write_text('\n'.join(lines) + '\n')

    def fleet_verifiers(self):
        r = subprocess.run([sys.executable, str(script), '--json', 'fleet', '--runs', str(self.runs)],
                           env=self.env, capture_output=True, text=True, check=True)
        return {(v['agent'], v['class']): v for v in json.loads(r.stdout)['verifiers']}, r.stdout

    def test_fleet_counts_verifier_attempts_by_agent_class_and_outcome(self):
        self.store('a', pair={}, events=[(10, 'master', 'init', '')])
        for n, o in [(1, 'provider'), (2, 'clean'), (3, 'reject'), (4, 'invalid'), (5, 'missing'), (6, 'start-failed'),
                     (7, 'running'), (8, 'prepared'), (9, 'inconclusive')]:
            self.packet('a', f'00{n}-x-v1', 'pi --model devin/swe-2', 'routine', o)
        self.packet('a', '010-x-v1', 'claude --model claude-sonnet-5-5', 'landing', 'clean')
        self.packet('a', '011-x-v1')
        self.store('b', pair={}, events=[(20, 'master', 'init', '')])
        self.packet('b', '001-x-v1', 'pi --model devin/swe-2', 'routine', 'clean')
        v, _ = self.fleet_verifiers()
        pi = v[('pi --model devin/swe-2', 'routine')]
        self.assertEqual((pi['started'], pi['clean'], pi['reject'], pi['inconclusive'], pi['invalid']), (10, 2, 1, 1, 1))
        self.assertEqual((pi['provider'], pi['missing'], pi['start-failed'], pi['running'], pi['unknown']), (1, 1, 1, 2, 0))
        self.assertEqual(v[('claude --model claude-sonnet-5-5', 'landing')]['clean'], 1)
        self.assertEqual(v[('unknown', 'unknown')]['unknown'], 1)

    def test_fleet_text_carries_the_caveat_and_gates_only_verdicts_make_no_attempt(self):
        self.store('a', pair={}, events=[(10, 'master', 'init', '')], verdicts=[('001-a-v1', 'clean (gates only; mode gates)', '001')])
        r = subprocess.run([sys.executable, str(script), 'fleet', '--runs', str(self.runs)], env=self.env,
                           capture_output=True, text=True, check=True)
        self.assertIn('reported outcomes on different workloads, not model accuracy', r.stdout)
        v, _ = self.fleet_verifiers()
        self.assertEqual(v, {})

    def test_since_filters_by_the_first_event_and_fleet_writes_nothing(self):
        self.store('old', pair={}, events=[(1_000_000_000, 'master', 'init', '')])
        self.store('new', pair={}, events=[(1_790_000_000, 'master', 'init', '')])
        before = sorted(str(p) for p in self.t.rglob('*'))
        runs, _ = self.fleet('--since', '2026-01-01')
        self.assertEqual(list(runs), ['new'])
        self.assertEqual(sorted(str(p) for p in self.t.rglob('*')), before)


class KitchenScriptTests(unittest.TestCase):
    """kitchen.sh against a fake herdr, a fake joo-dev, and a real repo and kitchen.py."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        t = Path(self.tmp.name)
        self.fake, self.repo = t / 'fake', t / 'repo'
        self.fake.mkdir()
        self.repo.mkdir()
        roster = t / 'roster.toml'
        roster.write_text('[sidekick]\nkind = "pi"\nargs = ["--model", "devin/swe-2"]\n'
                          '[sidekick.fallback]\nkind = "devin"\n[consultant]\nkind = "codex"\n')
        self.env = {**{k: v for k, v in os.environ.items() if k != 'PSTACK_PLACEMENT'}, 'FAKE': str(self.fake), 'PSTACK_KITCHEN_ROSTER': str(roster),
                    'PATH': f'{root / "tests/pstack-pair/bin"}:{os.environ["PATH"]}',
                    'HOME': str(t / 'home'), 'XDG_STATE_HOME': str(t / 'state'),
                    'HERDR_ENV': '1', 'HERDR_PANE_ID': 'p0', 'PAIR_SETTLE_HOLD': '0',
                    'PAIR_SUBMIT_CHECK_S': '0', 'KITCHEN_QUIET_MAX_S': '20', 'PSTACK_KITCHEN_LOAD': '1 8',
                    'GIT_AUTHOR_NAME': 't', 'GIT_AUTHOR_EMAIL': 't@t',
                    'GIT_COMMITTER_NAME': 't', 'GIT_COMMITTER_EMAIL': 't@t'}
        self.env.pop('CLAUDE_CODE_SESSION_ID', None)
        self.git('init', '-q')
        kitchen_toml = KITCHEN.replace('fast = ["test -f src/app.py"]', 'fast = ["test ! -e FAIL"]') \
            + '\n[review]\nengine = "joo"\nself = ["no-comments"]\n'
        for path, text in {**FILES, '.agents/kitchen.toml': kitchen_toml}.items():
            self.write(path, text)
        self.commit('init')
        self.script = skill / 'scripts/kitchen.sh'
        self.store = t / 'state/pstack/kitchen/runs/demo'
        self.run_sh('init', 'demo')
        hook = self.fake / 'hook'
        hook.write_text(f'''#!/usr/bin/env bash
case "$2" in
Load*VERIFY*)
  packet="${{2##* VERIFY }}"
  verdict="$(sed -n 's/^verdict: //p' "$packet")"
  units="$(sed -n 's/^units: //p' "$packet")"
  mode="$(cat "$FAKE/verdict-mode" 2>/dev/null || echo clean)"
  case "$mode" in slow | grace-writes) exit 0 ;; esac
  # devin-working: the verifier is busy on a command when the deadline comes.
  [ "$mode" = devin-working ] && {{ printf 'working devin\n' >"$FAKE/agents/$1"; exit 0; }}
  # ratelimit-live: a pi verifier hit its provider but its pane is still up.
  if [ "$mode" = ratelimit-live ] && [ "$(cut -d' ' -f2 "$FAKE/agents/$1")" = pi ]; then
    printf '{{"type":"message","message":{{"role":"assistant","stopReason":"error","errorMessage":"Reached free model rate limit. Your limit will reset in 50 minutes (at 11:26 UTC)."}}}}\n' >>"$(cat "$FAKE/sessions/$1")"
    exit 0
  fi
  # gone: the verifier exits without a verdict and without a provider error.
  [ "$mode" = gone ] && {{ rm -f "$FAKE/agents/$1"; exit 0; }}
  [ "$mode" = blocked ] && {{ printf 'blocked %s\\n' "$(cut -d' ' -f2 "$FAKE/agents/$1")" >"$FAKE/agents/$1"; exit 0; }}
  # ratelimit: a pi verifier stops on its provider and exits; another kind works.
  # ratelimit-all: every kind does.
  if {{ [ "$mode" = ratelimit ] && [ "$(cut -d' ' -f2 "$FAKE/agents/$1")" = pi ]; }} || [ "$mode" = ratelimit-all ]; then
    printf '{{"type":"message","message":{{"role":"assistant","stopReason":"error","errorMessage":"Reached free model rate limit. Your limit will reset in 50 minutes (at 11:26 UTC)."}}}}\n' >>"$(cat "$FAKE/sessions/$1")"
    rm -f "$FAKE/agents/$1"; exit 0
  fi
  case "$mode" in clean | ratelimit | ratelimit-live) status=clean ;; inconclusive) status=inconclusive ;; *) status=reject ;; esac
  {{ printf '# Verdict\\n\\nstatus: %s\\nunits: %s\\n\\n## Findings\\n\\n' "$status" "$units"
     [ "$status" = reject ] && printf '1. Acceptance broke: add returns 0\\n'
     printf '\\n## Evidence\\n\\n'
     [ "$mode" = noevidence ] || printf '```\\n$ python3 -c "print(1)"\\n1\\n```\\n'
  }} >"$verdict"
  ;;
Deadline*)
  # The grace prompt: write the inconclusive verdict it names, complete, when the mode says so.
  verdict="$(sed -n 's/^Deadline reached: write \\(.*\\) now with status.*/\\1/p' <<<"$2")"
  [ "$(cat "$FAKE/verdict-mode" 2>/dev/null)" = grace-writes ] && printf '# Verdict\\n\\nstatus: inconclusive\\nunits: 001\\n\\n## Findings\\n\\nran out of time\\n\\n## Evidence\\n\\n```\\n$ ls\\nok\\n```\\n' >"$verdict"
  ;;
Load*) printf 'status: done\\n' >'{self.store}/reports/000-ready.md' ;;
esac
''')
        hook.chmod(0o755)
        self.run_sh('spawn', str(self.store))

    def git(self, *args):
        return subprocess.run(['git', *args], cwd=self.repo, env=self.env, check=True,
                              capture_output=True, text=True).stdout.strip()

    def write(self, path, text):
        f = self.repo / path
        f.parent.mkdir(parents=True, exist_ok=True)
        f.write_text(text)

    def commit(self, message):
        self.git('add', '-A')
        self.git('commit', '-q', '-m', message)
        return self.git('rev-parse', 'HEAD')

    def run_sh(self, *args, code=0):
        result = subprocess.run([str(self.script), *args], cwd=self.repo, env=self.env,
                                capture_output=True, text=True, check=False)
        self.assertEqual(result.returncode, code, result.stdout + result.stderr)
        return result.stdout + result.stderr

    def state(self):
        return json.loads((self.store / 'pair.json').read_text())

    def brief(self, seq, slug, scope, playbook='feature', plan='none'):
        path = self.store / 'briefs' / f'{seq}-{slug}.md'
        text = (skill / 'references/brief-template.md').read_text()
        text = text.replace('{{SEQ}}', seq).replace('{{SLUG}}', slug).replace('{{STORE}}', str(self.store))
        lines = []
        for line in text.splitlines():
            if line.startswith('playbook:'):
                line = f'playbook: {playbook}'
            elif line.startswith('plan:'):
                line = f'plan: {plan}'
            elif line.startswith('commit:'):
                line = 'commit: yes'
            elif line.startswith('timebox:'):
                line = 'timebox: 30'
            lines.append(line)
        text = '\n'.join(lines) + '\n'
        text = text.replace('- {{one repo-relative path or glob per line, in full (never relative to the line above); `quote` a path that contains a comma; a note may follow after " — ". The kitchen classifies the unit from these lines.}}',
                            '\n'.join(f'- {g} — scope' for g in scope))
        text = re.sub(r'\{\{[^}]*\}\}', 'x', text, flags=re.DOTALL)
        path.write_text(text)
        return path

    def dispatch(self, brief, code=4):
        return self.run_sh('dispatch', str(self.store), str(brief), '--timeout', '1', code=code)

    def done(self, brief, head):
        (self.store / 'reports' / brief.name).write_text(f'# Report\n\nstatus: done\nhead: {head}\n')

    def test_init_puts_the_kitchen_in_the_standing_orders(self):
        orders = (self.store / 'standing-orders.md').read_text()
        self.assertIn('runs these skills on its diff and fixes what they find: no-comments', orders)
        self.assertIn('Landing goes as far as `commit`', orders)
        self.run_sh('init', 'demo')
        self.assertEqual((self.store / 'standing-orders.md').read_text(), orders)

    def test_spawn_takes_the_roster_and_classify_stamps_the_brief(self):
        sidekick = self.state()['sidekick']
        self.assertEqual((sidekick['kind'], sidekick['fallback']['kind']), ('pi', 'devin'))
        self.assertEqual(sidekick['start_args'][-2:], ['--model', 'devin/swe-2'])
        b = self.brief('001', 'util', ['src/util.py'])
        out = self.run_sh('classify', str(self.store), str(b))
        self.assertIn('risk: routine', out)
        text = b.read_text()
        self.assertIn('risk: routine\nprofiles: app\nverify: batch by routine verifier\n', text)
        e = self.brief('002', 'api', ['contracts/**'])
        out = self.run_sh('classify', str(self.store), str(e))
        self.assertIn('escalate: escalate path: contracts/api.json', out)
        self.assertIn('next: kitchen.sh consultant', out)

    def test_escalated_units_need_an_agreed_plan_and_routine_ones_do_not(self):
        self.dispatch(self.brief('001', 'util', ['src/util.py']))
        self.dispatch(self.brief('002', 'api', ['contracts/**']), code=6)

    def test_step_records_only_after_gates_and_policy_pass(self):
        b = self.brief('001', 'util', ['src/**', 'tests/**'])
        self.dispatch(b)
        self.write('src/util.py', 'X = 2\n')
        self.write('tests/test_app.py', 'x = 2\n')
        sha = self.commit('step 1')
        self.assertIn('gates: pass (app)', self.run_sh('step', str(self.store), sha, 'util two'))
        steps = (self.store / 'steps/001-util.tsv').read_text().splitlines()
        self.assertEqual(len(steps), 1)
        self.write('notes.txt', 'x\n')
        out = self.run_sh('step', str(self.store), self.commit('unmapped'), 'notes')
        self.assertIn('gates: none ran; no profile covers notes.txt', out)
        # A routine unit's steps never wake the master; its gates proved them.
        (self.fake / 'agents/demo-sidekick').write_text('working pi\n')
        out = self.run_sh('wait', str(self.store), '--timeout', '1', code=4)
        self.assertIn('check-in: 001-util.md', out)
        self.assertNotIn('to review on', out)
        self.write('FAIL', 'x\n')
        self.write('src/util.py', 'print(3)\n')
        sha = self.commit('step 2')
        out = self.run_sh('step', str(self.store), sha, 'util three', code=2)
        self.assertIn('[no-print]', out)
        self.assertIn('next: fix it in a new commit', out)
        out = self.run_sh('step', str(self.store), sha, 'util three', code=2)
        self.assertIn('2 failed checks in a row; write the report as blocked', out)
        self.assertEqual(len((self.store / 'steps/001-util.tsv').read_text().splitlines()), 2)

    def test_step_gates_see_the_run_and_role(self):
        b = self.brief('001', 'util', ['src/**', 'tests/**'])
        self.dispatch(b)
        toml = self.repo / '.agents/kitchen.toml'
        toml.write_text(toml.read_text().replace('fast = ["test ! -e FAIL"]',
                                                 'fast = ["printf \'%s|%s\' \\"$PSTACK_KITCHEN_RUN\\" \\"$PSTACK_KITCHEN_ROLE\\" > lane.txt"]'))
        self.write('src/util.py', 'X = 2\n')
        self.write('tests/test_app.py', 'x = 2\n')
        sha = self.commit('step 1')
        self.assertIn('gates: pass (app)', self.run_sh('step', str(self.store), sha, 'util two'))
        self.assertEqual((self.repo / 'lane.txt').read_text(), 'demo|sidekick')

    def test_a_resumed_units_commit_is_checked_against_its_own_diff(self):
        self.write('src/util.py', 'X = 3\n')
        self.write('tests/test_app.py', 'x = 3\n')
        sha = self.commit('made before the brief')
        self.dispatch(self.brief('001', 'resume', ['src/**', 'tests/**']))
        self.assertIn('gates: pass (app)', self.run_sh('step', str(self.store), sha, 'resumed'))
        self.write('notes.txt', 'x\n')
        out = self.run_sh('step', str(self.store), self.commit('unmapped'), 'notes')
        self.assertIn('gates: none ran', out)
        rows = [r.split('\t') for r in (self.store / 'gates.tsv').read_text().splitlines()]
        self.assertEqual([(r[3], r[4]) for r in rows], [('pass', 'app'), ('none', '')])

    def test_step_returns_while_checks_run_and_resumes(self):
        self.write('.agents/kitchen.toml', (self.repo / '.agents/kitchen.toml').read_text()
                   .replace('fast = ["test ! -e FAIL"]', 'fast = ["sleep 5"]'))
        self.commit('slow gate')
        self.dispatch(self.brief('001', 'util', ['src/**', 'tests/**']))
        self.write('src/util.py', 'X = 4\n')
        self.write('tests/test_app.py', 'x = 4\n')
        sha = self.commit('step')
        self.env['KITCHEN_STEP_SLICE_S'] = '1'
        out = self.run_sh('step', str(self.store), sha, 'slow', code=4)
        self.assertIn('gates: still running', out)
        self.assertIn(f'kitchen.sh step {self.store} {sha} "slow"', out)
        self.env['KITCHEN_STEP_SLICE_S'] = '30'
        self.assertIn('gates: pass (app)', self.run_sh('step', str(self.store), sha, 'slow'))
        self.assertEqual(len((self.store / 'gates.tsv').read_text().splitlines()), 1)

    def test_quiet_wait_skips_unflagged_check_ins(self):
        self.dispatch(self.brief('001', 'util', ['src/**', 'tests/**']))
        (self.fake / 'agents/demo-sidekick').write_text('working pi\n')
        self.env['KITCHEN_QUIET_MAX_S'] = '3'
        out = self.run_sh('wait', str(self.store), '--timeout', '1', code=4)
        self.assertIn('quiet: 0m with nothing flagged', out)
        checkins = [l for l in (self.store / 'events.tsv').read_text().splitlines() if l.endswith('\tcheckin')]
        self.assertGreater(len(checkins), 1)
        self.write('elsewhere.txt', 'x\n')
        out = self.run_sh('wait', str(self.store), '--timeout', '1', code=4)
        self.assertIn('outside scope: 1', out)
        self.assertNotIn('quiet:', out)

    def test_gates_see_the_step_base(self):
        self.write('.agents/kitchen.toml', (self.repo / '.agents/kitchen.toml').read_text()
                   .replace('fast = ["test ! -e FAIL"]', 'fast = ["git cat-file -e \\"$PSTACK_KITCHEN_STEP_BASE^{commit}\\""]'))
        base = self.commit('kitchen sees the base')
        self.dispatch(self.brief('001', 'util', ['src/**', 'tests/**']))
        self.write('src/util.py', 'X = 11\n')
        self.commit('one')
        self.write('tests/test_app.py', 'x = 11\n')
        sha = self.commit('two')
        self.assertIn('gates: pass (app)', self.run_sh('step', str(self.store), sha, 'two commits'))
        job = next((self.store / 'steps/jobs').iterdir())
        self.assertEqual((job / 'base').read_text().strip(), base)

    def test_a_squash_is_verified_against_what_it_carries(self):
        self.write('src/util.py', 'X = 21\n')
        self.write('tests/test_app.py', 'x = 21\n')
        self.commit('step one')
        self.write('src/util.py', 'X = 22\n')
        tip = self.commit('step two')
        squash = self.brief('001', 'squash', ['src/**', 'tests/**'], playbook='refactoring')
        self.dispatch(squash)
        self.git('reset', '--soft', 'HEAD~2')
        self.done(squash, self.commit('squashed'))
        self.assertEqual(self.git('rev-parse', 'HEAD^{tree}'), self.git('rev-parse', f'{tip}^{{tree}}'))
        out = self.run_sh('verify', str(self.store), '001')
        self.assertNotIn('gates only', out)
        self.assertIn('verifier demo-verifier', out)

    def test_a_blocked_unit_can_still_be_verified(self):
        b = self.brief('001', 'util', ['src/**', 'tests/**'])
        self.dispatch(b)
        self.write('src/util.py', 'X = 31\n')
        self.write('tests/test_app.py', 'x = 31\n')
        head = self.commit('util')
        (self.store / 'reports' / b.name).write_text(f'# Report\n\nstatus: blocked\nhead: {head}\n')
        out = self.run_sh('verify', str(self.store), '001')
        self.assertIn("note: unit 001's report is blocked; checking the head it names", out)
        self.assertIn('status: clean', out)

    def test_landing_review_starts_where_the_stack_leaves_trunk(self):
        b = self.brief('001', 'util', ['src/**', 'tests/**'])
        self.dispatch(b)
        old_base = self.git('rev-parse', 'HEAD')
        self.write('docs/trunk.md', '# moved on\n')
        trunk = self.commit('trunk moved')
        self.git('update-ref', 'refs/remotes/origin/main', trunk)
        self.write('src/util.py', 'X = 41\n')
        self.write('tests/test_app.py', 'x = 41\n')
        self.done(b, self.commit('stacked on the new trunk'))
        (self.fake / 'joo-artifact.json').write_text(json.dumps({'kind': 'review-artifact', 'findings': []}))
        out = self.run_sh('review', str(self.store), '--landing')
        self.assertIn('landing base: merge-base of remotes/origin/main and HEAD', out)
        log = (self.fake / 'joo.log').read_text()
        self.assertIn(f'--range {trunk}..', log)
        self.assertNotIn(f'--range {old_base}..', log)
        self.run_sh('review', str(self.store), '--landing', '--base', old_base)
        self.assertIn(f'--range {old_base}..', (self.fake / 'joo.log').read_text())

    def test_gates_mode_verifies_without_a_verifier(self):
        b = self.brief('001', 'docs', ['docs/**'])
        self.dispatch(b)
        self.write('docs/guide.md', '# Guide\nmore\n')
        head = self.commit('docs')
        self.done(b, head)
        out = self.run_sh('verify', str(self.store), '001')
        self.assertIn('status: clean (gates only', out)
        self.assertNotIn('agent start demo-verifier', (self.fake / 'calls.log').read_text())

    def verify_app_unit(self, mode, code, stall=False):
        b = self.brief('001', 'util', ['src/**', 'tests/**'])
        self.dispatch(b)
        self.write('src/util.py', 'X = 9\n')
        self.write('tests/test_app.py', 'x = 9\n')
        head = self.commit('util')
        self.done(b, head)
        (self.fake / 'verdict-mode').write_text(mode)
        if stall:
            (self.fake / 'stall').touch()
        return b, self.run_sh('verify', str(self.store), '001', code=code)

    def test_verifier_pane_writes_a_clean_verdict_then_goes(self):
        _, out = self.verify_app_unit('clean', 0)
        self.assertIn('verifier demo-verifier (pi --model devin/swe-2) in ', out)
        self.assertIn('status: clean\n', out)
        self.assertRegex(out, r'audit: (yes|no)')
        calls = (self.fake / 'calls.log').read_text()
        self.assertIn('agent start demo-verifier --kind pi', calls)
        self.assertIn('agent prompt demo-verifier /quit', calls)
        self.assertRegex(calls, r'pane close p\d')
        self.assertEqual(list((self.store / 'scratch').iterdir()), [])
        packet = (self.store / 'verdicts/001-util-v1-packet.md').read_text()
        self.assertIn(f'scratch: {self.repo.resolve()}/.git/pstack-scratch/', packet)
        self.assertIn('gate app behavioral', packet)
        self.assertIn('## Acceptance', packet)

    def test_scratch_lives_inside_the_repo_git_dir_and_leaves_no_trace(self):
        path = Path(self.run_sh('scratch', str(self.store), '001-x-review').splitlines()[0])
        git_dir = self.repo / '.git' / 'pstack-scratch'
        self.assertEqual(path.parent.parent, git_dir)
        self.assertEqual((self.store / 'scratch/001-x-review').resolve(), path.resolve())
        self.assertTrue((path / 'calc.py').exists() or (path / 'src/app.py').exists())
        self.assertEqual(self.git('status', '--porcelain'), '')
        self.run_sh('scratch', str(self.store), '001-x-review', '--remove')
        self.assertFalse(path.exists())
        self.assertFalse((self.store / 'scratch/001-x-review').is_symlink())
        self.assertEqual(list(git_dir.iterdir()), [])

    def test_a_trust_dialog_is_declined_not_answered(self):
        (self.fake / 'agents/demo-consultant').unlink(missing_ok=True)
        (self.fake / 'trust-dialog').touch()
        out = self.run_sh('consultant', str(self.store), '--reason', 'contract', '--kind', 'claude', code=5)
        self.assertIn('claude asks whether to trust', out)
        self.assertIn('decision is yours', out)
        calls = (self.fake / 'calls.log').read_text()
        self.assertRegex(calls, r'pane send-keys p\d+ esc')
        self.assertNotRegex(calls, r'send-keys \S+ enter')

    def test_spawned_claude_agents_load_no_mcp_servers(self):
        (self.fake / 'agents/demo-consultant').unlink(missing_ok=True)
        # The fake writes no advice/000-ready.md, so the bootstrap ends 4; the start line is what matters.
        self.run_sh('consultant', str(self.store), '--reason', 'contract', '--kind', 'claude', code=4)
        start = [line for line in (self.fake / 'calls.log').read_text().splitlines()
                 if line.startswith('agent start demo-consultant')][-1]
        self.assertIn('--strict-mcp-config --mcp-config', start)
        self.assertIn('references/no-mcp.json', start)
        self.set_roster('[verifier.escalated]\nkind = "claude"\nargs = ["--model", "m", "--mcp-config", "mine.json"]\n')
        out = self.verify_landing()
        (vstart,) = self.verifier_starts()
        self.assertIn('--mcp-config mine.json', vstart)
        self.assertNotIn('--strict-mcp-config', vstart)
        self.assertIn('verifier demo-verifier (claude --model m)', out)

    def test_close_ends_the_roles_and_closes_their_panes(self):
        state = self.state()
        state['verifying'] = {'verdict': 'x', 'units': '001'}
        (self.store / 'pair.json').write_text(json.dumps(state))
        self.assertIn('a verification is open', self.run_sh('close', str(self.store), code=5))
        del state['verifying']
        (self.store / 'pair.json').write_text(json.dumps(state))
        out = self.run_sh('close', str(self.store))
        self.assertIn('closed sidekick demo-sidekick', out)
        calls = (self.fake / 'calls.log').read_text()
        self.assertIn('agent prompt demo-sidekick /quit', calls)
        self.assertRegex(calls, r'pane close p\d')
        self.assertFalse((self.fake / 'agents/demo-sidekick').exists())
        self.assertTrue(self.state()['sidekick']['closed'])
        self.assertIn('close\tsidekick:pi', (self.store / 'events.tsv').read_text().replace('\t-\t', '\t'))
        self.assertEqual(self.run_sh('close', str(self.store)), '')

    def test_verify_prompt_left_typed_is_submitted(self):
        _, out = self.verify_app_unit('clean', 0, stall=True)
        self.assertIn('status: clean', out)
        self.assertIn('send-keys demo-verifier enter', (self.fake / 'calls.log').read_text())

    def test_tab_placement_gives_the_verifier_a_tab(self):
        state = json.loads((self.store / 'pair.json').read_text())
        state['placement'] = 'tab'
        (self.store / 'pair.json').write_text(json.dumps(state))
        self.verify_app_unit('clean', 0)
        calls = (self.fake / 'calls.log').read_text()
        self.assertIn('--label demo-verifier --no-focus', calls)
        self.assertRegex(calls, r'pane close t\d')

    def test_a_fix_is_verified_with_the_unit_it_fixes(self):
        first = self.brief('001', 'util', ['src/**', 'tests/**'])
        self.dispatch(first)
        self.write('src/util.py', 'X = 5\n')
        self.write('tests/test_app.py', 'x = 5\n')
        self.commit('first')
        (self.store / 'reports' / first.name).write_text('# Report\n\nstatus: partial\nhead: x\n')
        fix = self.brief('002', 'util-fix', ['src/**', 'tests/**'], playbook='bug-fix')
        self.dispatch(fix)
        self.write('src/util.py', 'X = 6\n')
        self.write('tests/test_app.py', 'x = 6\n')
        self.done(fix, self.commit('fix'))
        out = self.run_sh('verify', str(self.store), '002', '--covers', '001')
        self.assertIn('status: clean', out)
        packet = (self.store / 'verdicts/002-util-fix-v1-packet.md').read_text()
        self.assertIn('units: 001 002', packet)
        self.assertIn('Unit 002 fixes unit 001', packet)
        self.assertIn('--role verifier', packet)
        for name in ('001-util', '002-util-fix'):
            (self.store / f'reviews/{name}.md').write_text('verdict: accept\n')
        self.assertIn('land-check: pass', self.run_sh('land-check', str(self.store)))

    def three_units(self, scope=('src/**', 'tests/**')):
        heads = []
        for n in (1, 2, 3):
            b = self.brief(f'00{n}', f'u{n}', list(scope))
            self.dispatch(b)
            if scope[0].startswith('docs'):
                self.write('docs/guide.md', f'# Guide {n}\n')
            else:
                self.write('src/util.py', f'X = {n + 20}\n')
                self.write('tests/test_app.py', f'x = {n + 20}\n')
            heads.append(self.commit(f'u{n}'))
            self.done(b, heads[-1])
        return heads

    def test_covers_takes_a_comma_list_and_a_correct_order_passes(self):
        self.three_units()
        out = self.run_sh('verify', str(self.store), '003', '--covers', '001,002')
        self.assertIn('status: clean', out)
        packet = (self.store / 'verdicts/003-u3-v1-packet.md').read_text()
        self.assertIn('units: 001 002 003', packet)

    def test_a_fix_named_before_the_units_it_covers_is_refused_with_both_heads(self):
        heads = self.three_units()
        out = self.run_sh('verify', str(self.store), '003', '--covers', '001', '002', code=2)
        self.assertIn(f"unit 003's head {heads[2][:9]} is not in the checked-out head {heads[1][:9]} (unit 002)", out)
        self.assertIn('name the unit that carries all the others last', out)
        self.assertNotIn('verifier demo-verifier', out)
        self.assertNotIn('verifying', self.state())

    def test_the_head_check_runs_before_a_gates_only_verification(self):
        heads = self.three_units(scope=('docs/**',))
        out = self.run_sh('verify', str(self.store), '002', '--covers', '003', code=2)
        self.assertIn(f"unit 003's head {heads[2][:9]} is not in the checked-out head {heads[1][:9]} (unit 002)", out)
        self.assertNotIn('gates only', out)

    def test_a_covered_unit_without_a_usable_head_passes_with_a_note(self):
        self.three_units()
        (self.store / 'reports/001-u1.md').write_text('# Report\n\nstatus: partial\nhead: x\n')
        (self.store / 'reports/002-u2.md').unlink()
        out = self.run_sh('verify', str(self.store), '003', '--covers', '001,002')
        self.assertIn('note: unit 001 has no usable head; its inclusion was not checked', out)
        self.assertIn('note: unit 002 has no usable head; its inclusion was not checked', out)

    def test_covers_rejects_a_value_that_is_not_a_unit_number(self):
        self.three_units()
        self.assertIn("--covers takes unit numbers (NNN)", self.run_sh('verify', str(self.store), '003', '--covers', '001,x', code=1))

    def test_verify_returns_at_the_interval_and_resumes(self):
        b = self.brief('001', 'util', ['src/**', 'tests/**'])
        self.dispatch(b)
        self.write('src/util.py', 'X = 8\n')
        self.write('tests/test_app.py', 'x = 8\n')
        self.done(b, self.commit('util'))
        (self.fake / 'verdict-mode').write_text('slow')
        out = self.run_sh('verify', str(self.store), '001', '--every', '0', code=4)
        self.assertIn('verifying: units 001 by pi', out)
        self.assertIn(f'next: other work, then kitchen.sh verify {self.store} --wait', out)
        self.assertIn('a verification is open', self.run_sh('verify', str(self.store), '001', code=5))
        open_ = json.loads((self.store / 'pair.json').read_text())['verifying']
        Path(open_['verdict']).write_text('status: clean\nunits: 001\n\n## Evidence\n\n```\n$ true\n```\n')
        out = self.run_sh('verify', str(self.store), '--wait')
        self.assertIn('status: clean', out)
        self.assertNotIn('verifying', json.loads((self.store / 'pair.json').read_text()))
        self.assertEqual(list((self.store / 'scratch').iterdir()), [])
        self.assertIn('no verification is open', self.run_sh('verify', str(self.store), '--wait', code=5))

    def rate_limited_verifier(self):
        session = Path(self.tmp.name) / 'pi-session.jsonl'
        session.write_text('{"type":"session"}\n')
        (self.fake / 'sessions').mkdir()
        (self.fake / 'sessions/demo-verifier').write_text(str(session))

    def test_a_rate_limited_verifier_says_so_and_retries_on_the_fallback(self):
        self.rate_limited_verifier()
        _, out = self.verify_app_unit('ratelimit', 0)
        self.assertIn('status: inconclusive (the verifier hit its provider', out)
        self.assertIn('provider_error: Reached free model rate limit. Your limit will reset in 50 minutes', out)
        self.assertIn('retry: verifying again on the fallback, devin', out)
        self.assertIn('verifier demo-verifier (devin (model unspecified)) in ', out)
        self.assertIn('status: clean\n', out)
        starts = [line for line in (self.fake / 'calls.log').read_text().splitlines()
                  if line.startswith('agent start demo-verifier')]
        self.assertEqual(len(starts), 2)
        self.assertIn('--kind devin', starts[1])
        self.assertNotIn('devin/swe-2', starts[1])
        self.assertIn('verify:provider', (self.store / 'events.tsv').read_text())

    def set_roster(self, extra):
        Path(self.env['PSTACK_KITCHEN_ROSTER']).write_text(
            '[sidekick]\nkind = "pi"\nargs = ["--model", "devin/swe-2"]\n'
            '[sidekick.fallback]\nkind = "devin"\n[consultant]\nkind = "codex"\n' + extra)

    def verifier_starts(self):
        return [line for line in (self.fake / 'calls.log').read_text().splitlines()
                if line.startswith('agent start demo-verifier')]

    def verify_landing(self):
        self.git('update-ref', 'refs/remotes/origin/main', self.git('rev-list', '--max-parents=0', 'HEAD'))
        b = self.brief('001', 'util', ['src/**', 'tests/**'])
        self.dispatch(b)
        self.write('src/util.py', 'X = 3\n')
        self.write('tests/test_app.py', 'x = 3\n')
        self.done(b, self.commit('util'))
        return self.run_sh('verify', str(self.store), '--landing')

    def declare_setup(self):
        toml = self.repo / '.agents/kitchen.toml'
        toml.write_text(toml.read_text() + '\n[scratch]\nsetup = ["bun install --frozen-lockfile"]\n')
        self.commit('declare scratch setup')

    def prove_block(self, packet):
        return packet.read_text().split('## Prove', 1)[1].split('```bash\n', 1)[1].split('```', 1)[0].splitlines()

    def test_the_unit_packet_runs_setup_first_only_when_declared(self):
        self.verify_app_unit('clean', 0)
        plain = self.prove_block(self.store / 'verdicts/001-util-v1-packet.md')
        self.assertEqual(plain[0], 'export PSTACK_KITCHEN_ROLE=verifier PSTACK_KITCHEN_RUN=demo')
        self.assertIn(' gate app behavioral ', plain[1])
        self.assertFalse(any(' setup' in line for line in plain))

    def test_the_unit_packet_puts_setup_ahead_of_the_gates(self):
        self.declare_setup()
        self.verify_app_unit('clean', 0)
        block = self.prove_block(self.store / 'verdicts/001-util-v1-packet.md')
        self.assertEqual(block[0], 'export PSTACK_KITCHEN_ROLE=verifier PSTACK_KITCHEN_RUN=demo')
        self.assertRegex(block[1], r'^python3 \S+kitchen\.py --repo \S+/001-util-verify setup$')
        self.assertIn(' gate app behavioral ', block[2])

    def test_the_landing_packet_runs_setup_first_when_declared(self):
        self.declare_setup()
        self.verify_landing()
        block = self.prove_block(self.store / 'verdicts/landing-v1-packet.md')
        self.assertRegex(block[1], r'^python3 \S+kitchen\.py --repo \S+/000-landing-verify setup$')
        self.assertIn(' gate app behavioral ', block[2])

    def packet_fields(self, n='001-util-v1'):
        text = (self.store / f'verdicts/{n}-packet.md').read_text()
        return {k: v for k, v in (line.split(': ', 1) for line in text.splitlines() if line.startswith('verifier-'))}

    def test_the_packet_records_the_configured_agent_class_and_a_prepared_outcome(self):
        self.set_roster('[verifier]\nkind = "pi"\nargs = ["--approve", "--model", "devin/swe-2", "--thinking", "high"]\n')
        b = self.brief('001', 'util', ['src/**', 'tests/**'])
        self.dispatch(b)
        self.write('src/util.py', 'X = 9\n')
        self.write('tests/test_app.py', 'x = 9\n')
        self.done(b, self.commit('util'))
        (self.fake / 'verdict-mode').write_text('slow')
        self.run_sh('verify', str(self.store), '001', '--every', '0', code=4)
        self.assertEqual(self.packet_fields(), {'verifier-agent': 'pi --model devin/swe-2 --thinking high',
                                                'verifier-class': 'routine', 'verifier-outcome': 'running'})

    def test_every_attempt_ends_with_its_own_outcome(self):
        for mode, code, outcome in [('clean', 0, 'clean'), ('reject', 2, 'reject'), ('inconclusive', 2, 'inconclusive'),
                                    ('noevidence', 2, 'invalid'), ('gone', 4, 'missing')]:
            with self.subTest(mode):
                self.setUp()
                self.verify_app_unit(mode, code)
                self.assertEqual(self.packet_fields()['verifier-outcome'], outcome)
                self.assertNotIn('verifying', self.state())

    def test_a_provider_stop_then_a_clean_fallback_are_two_attempts(self):
        self.set_roster('[verifier]\nkind = "pi"\n[verifier.fallback]\nkind = "devin"\n')
        self.rate_limited_verifier()
        self.verify_app_unit('ratelimit', 0)
        self.assertEqual(self.packet_fields('001-util-v1')['verifier-outcome'], 'provider')
        self.assertEqual(self.packet_fields('001-util-v2')['verifier-outcome'], 'clean')
        self.assertEqual(self.packet_fields('001-util-v2')['verifier-agent'], 'devin (model unspecified)')

    def test_both_attempts_failing_are_both_recorded(self):
        self.set_roster('[verifier]\nkind = "pi"\n[verifier.fallback]\nkind = "devin"\n')
        self.rate_limited_verifier()
        self.verify_app_unit('ratelimit-all', 2)
        self.assertEqual([self.packet_fields(f'001-util-v{k}')['verifier-outcome'] for k in (1, 2)], ['provider', 'provider'])

    def test_a_failed_start_is_recorded_as_start_failed(self):
        b = self.brief('001', 'util', ['src/**', 'tests/**'])
        self.dispatch(b)
        self.write('src/util.py', 'X = 9\n')
        self.write('tests/test_app.py', 'x = 9\n')
        self.done(b, self.commit('util'))
        (self.fake / 'trust-dialog').touch()
        self.run_sh('verify', str(self.store), '001', code=5)
        self.assertEqual(self.packet_fields()['verifier-outcome'], 'start-failed')

    def test_landing_and_escalated_packets_name_their_class(self):
        self.verify_landing()
        self.assertEqual(self.packet_fields('landing-v1'), {'verifier-agent': 'claude --model claude-opus-5-5',
                                                            'verifier-class': 'landing', 'verifier-outcome': 'clean'})

    def deadline_verify(self, mode, *extra, code=0, every=None, prompts_fail=False):
        self.env.update({'KITCHEN_VERIFY_GRACE_S': '4', 'KITCHEN_VERIFY_GRACE_POLL_S': '1'})
        b = self.brief('001', 'util', ['src/**', 'tests/**'])
        self.dispatch(b)
        self.write('src/util.py', 'X = 9\n')
        self.write('tests/test_app.py', 'x = 9\n')
        self.done(b, self.commit('util'))
        (self.fake / 'verdict-mode').write_text(mode)
        if prompts_fail:
            (self.fake / 'prompt-fail').touch()
        return self.run_sh('verify', str(self.store), '001', '--timeout', '0', *(['--every', every] if every else []), *extra, code=code)

    def grace_prompts(self):
        return [line for line in (self.fake / 'calls.log').read_text().splitlines() if line.startswith('agent prompt demo-verifier Deadline reached')]

    def test_the_deadline_asks_once_for_an_inconclusive_verdict(self):
        out = self.deadline_verify('grace-writes', code=2)
        self.assertIn('status: inconclusive', out)
        self.assertEqual(len(self.grace_prompts()), 1)
        self.assertIn('write the file complete in one write', self.grace_prompts()[0])
        self.assertEqual(self.packet_fields()['verifier-outcome'], 'inconclusive')
        self.assertNotIn('verifying', self.state())

    def test_no_verdict_after_the_grace_is_missing(self):
        out = self.deadline_verify('slow', code=4)
        self.assertIn('no verdict at', out)
        self.assertEqual(len(self.grace_prompts()), 1)
        self.assertEqual(self.packet_fields()['verifier-outcome'], 'missing')

    def test_a_verdict_arriving_during_the_grace_wins(self):
        verdict = self.store / 'verdicts/001-util-v1.md'
        packet = self.store / 'verdicts/001-util-v1-packet.md'
        late = subprocess.Popen(['bash', '-c', f"until [ -f {packet} ]; do sleep 0.2; done; sleep 1.5; printf '# V\\n\\nstatus: reject\\nunits: 001\\n\\n## Findings\\n\\n1. x\\n\\n## Evidence\\n\\n```\\na\\n```\\n' >{verdict}"])
        self.addCleanup(late.wait)
        out = self.deadline_verify('slow', code=2)
        self.assertIn('status: reject', out)

    def test_a_later_wait_resumes_the_same_grace_and_never_prompts_again(self):
        self.env.update({'KITCHEN_VERIFY_GRACE_S': '8'})
        out = self.deadline_verify('slow', code=4, every='0')
        self.assertIn('past its deadline; grace', out)
        v = self.state()['verifying']
        self.assertEqual(v['grace_delivery'], 'prompted')
        until = v['grace_until']
        self.env['KITCHEN_VERIFY_GRACE_S'] = '600'
        out = self.run_sh('verify', str(self.store), '--wait', '--every', '0', code=4)
        self.assertIn('past its deadline; grace', out)
        self.assertEqual(self.state()['verifying']['grace_until'], until)
        self.assertEqual(len(self.grace_prompts()), 1)
        time.sleep(max(0, until - time.time()) + 1)
        out = self.run_sh('verify', str(self.store), '--wait', code=4)
        self.assertIn('no verdict at', out)
        self.assertEqual(len(self.grace_prompts()), 1)

    def test_a_failed_delivery_is_recorded_and_the_grace_still_runs_out(self):
        self.deadline_verify('slow', code=4, every='0', prompts_fail=True)
        self.assertEqual(self.state()['verifying']['grace_delivery'], 'skipped:prompt-failed')
        self.assertEqual(len(self.grace_prompts()), 1)

    def test_a_blocked_or_absent_verifier_gets_no_grace(self):
        for mode in ('blocked', 'gone'):
            with self.subTest(mode):
                self.setUp()
                out = self.deadline_verify(mode, code=4)
                self.assertIn('no verdict at', out)
                self.assertEqual(self.grace_prompts(), [])
                self.assertNotIn('past its deadline', out)

    def test_a_working_devin_is_not_prompted_but_the_grace_still_waits(self):
        self.set_roster('[verifier]\nkind = "devin"\n')
        self.env.update({'KITCHEN_VERIFY_GRACE_S': '8'})
        self.deadline_verify('devin-working', code=4, every='0')
        self.assertEqual(self.state()['verifying']['grace_delivery'], 'skipped:devin-working')
        self.assertEqual(self.grace_prompts(), [])

    def test_a_provider_error_at_the_deadline_takes_the_fallback_not_the_grace(self):
        self.set_roster('[verifier]\nkind = "pi"\n[verifier.fallback]\nkind = "devin"\n')
        self.rate_limited_verifier()
        out = self.deadline_verify('ratelimit-live', code=0)
        self.assertIn('retry: verifying again on the fallback, devin', out)
        self.assertEqual(self.grace_prompts(), [])

    def test_a_routine_verifier_defaults_to_the_sidekick(self):
        self.verify_app_unit('clean', 0)
        self.assertIn('--kind pi', self.verifier_starts()[0])
        self.assertIn('--model devin/swe-2', self.verifier_starts()[0])
        self.assertEqual(self.state()['verifier']['kind'], 'pi')

    def test_an_explicit_verifier_entry_wins_over_the_sidekick(self):
        self.set_roster('[verifier]\nkind = "devin"\nargs = ["--model", "swe-x"]\n')
        self.verify_app_unit('clean', 0)
        (start,) = self.verifier_starts()
        self.assertIn('--kind devin', start)
        self.assertIn('--model swe-x', start)
        self.assertNotIn('devin/swe-2', start)

    def test_landing_and_escalated_verifiers_default_to_claude_opus(self):
        self.verify_landing()
        (start,) = self.verifier_starts()
        self.assertIn('--kind claude', start)
        self.assertIn('--model claude-opus-5-5', start)

    def test_the_master_sentinel_starts_the_masters_own_kind(self):
        self.set_roster('[verifier.escalated]\nkind = "master"\n')
        self.verify_landing()
        (start,) = self.verifier_starts()
        self.assertIn('--kind claude', start)
        self.assertNotIn('claude-opus-5-5', start)

    def test_a_rate_limited_verifier_retries_on_the_roster_fallback_once(self):
        self.set_roster('[verifier]\nkind = "pi"\nargs = ["--model", "m"]\n'
                        '[verifier.fallback]\nkind = "devin"\nargs = ["--model", "fb"]\n')
        self.rate_limited_verifier()
        _, out = self.verify_app_unit('ratelimit', 0)
        self.assertIn('retry: verifying again on the fallback, devin', out)
        first, second = self.verifier_starts()
        self.assertIn('--kind pi', first)
        self.assertIn('--model m', first)
        self.assertIn('--kind devin', second)
        self.assertIn('--model fb', second)
        self.assertTrue(self.state()['verifier']['kind'] == 'devin')

    def test_a_fallback_that_hits_its_provider_too_is_not_retried_again(self):
        self.set_roster('[verifier]\nkind = "pi"\n[verifier.fallback]\nkind = "devin"\n')
        self.rate_limited_verifier()
        _, out = self.verify_app_unit('ratelimit-all', 2)
        self.assertIn('retry: verifying again on the fallback, devin', out)
        self.assertEqual(len(self.verifier_starts()), 2)
        self.assertIn(f'next: wait for the limit, or kitchen.sh verify {self.store} 001 --kind <another kind>', out)

    def test_a_fallback_of_the_failed_kind_is_not_retried(self):
        self.set_roster('[verifier]\nkind = "pi"\n[verifier.fallback]\nkind = "pi"\nargs = ["--model", "other"]\n')
        self.rate_limited_verifier()
        self.verify_app_unit('ratelimit', 2)
        self.assertEqual(len(self.verifier_starts()), 1)

    GAP = '## Gaps\n\n### 1. dispatch hid the rotation\n\nWhat happened: x\nWorkaround: none\nSuggestion: say so\nEvidence: events.tsv\n\n## What worked\n\n- gates\n'

    def feedback_dir(self):
        return Path(self.env['XDG_STATE_HOME']) / 'pstack/feedback'

    def gap_file(self, text=None, name='gaps.md'):
        f = Path(self.tmp.name) / name
        f.write_text(self.GAP if text is None else text)
        return f

    def file_feedback(self, text=None):
        out = self.run_sh('feedback', str(self.store), str(self.gap_file(text)))
        return out, Path(re.search(r'^filed: (.+)$', out, re.MULTILINE).group(1))

    def calls(self):
        return (self.fake / 'calls.log').read_text()

    def test_feedback_files_the_report_behind_a_header(self):
        out, path = self.file_feedback()
        self.assertEqual(path.parent, self.feedback_dir() / 'inbox')
        text = path.read_text()
        self.assertRegex(text, r'^# Kitchen feedback: demo \(repo\)\nid: \d{8}-repo-demo\nrun: demo   store: ')
        self.assertIn(f'master: demo-master (p0)\nbuild: unknown ({skill.parent.resolve()})\nretro: ', text)
        self.assertNotIn('filed with:', text)
        self.assertRegex(text, r'retro: run demo: 0 unit reports, 0 verified units \(0 clean verdicts on the first try\)')
        self.assertRegex(text, r'filed: \d{4}-\d\d-\d\dT[\d:]+Z\nstatus: open\n\n## Gaps\n\n### 1\. dispatch hid the rotation')
        self.assertIn('feedback\t', (self.store / 'events.tsv').read_text())
        self.assertIn('delivered: notification for the human (no maintainer is registered)', out)
        self.assertEqual(list(self.feedback_dir().glob('.filing-*')), [])

    def test_a_file_without_a_gap_files_nothing(self):
        out = self.run_sh('feedback', str(self.store), str(self.gap_file('## Gaps\n\nnothing\n')), code=1)
        self.assertIn('has no gap', out)
        self.assertFalse((self.feedback_dir() / 'inbox').exists() and list((self.feedback_dir() / 'inbox').iterdir()))

    def test_simultaneous_filings_get_distinct_ids(self):
        f = self.gap_file()
        procs = [subprocess.Popen([str(self.script), 'feedback', str(self.store), str(f)], cwd=self.repo, env=self.env,
                                  stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True) for _ in range(4)]
        outs = [p.communicate()[0] for p in procs]
        self.assertEqual([p.returncode for p in procs], [0] * 4, outs)
        ids = sorted(p.stem for p in (self.feedback_dir() / 'inbox').glob('*.md'))
        self.assertEqual(len(ids), 4)
        self.assertEqual(len(set(ids)), 4)
        for p in (self.feedback_dir() / 'inbox').glob('*.md'):
            self.assertIn(f'id: {p.stem}\n', p.read_text())

    def register_maintainer(self):
        out = self.run_sh('maintainer', 'on', '--pane', 'p0')
        self.assertIn('maintainer: demo-master on p0', out)

    def test_a_live_maintainer_gets_the_pointer(self):
        self.register_maintainer()
        out, path = self.file_feedback()
        self.assertIn('delivered: to maintainer demo-master', out)
        self.assertIn(f'agent prompt demo-master pstack-kitchen FEEDBACK {path}', self.calls())
        self.assertNotIn('notification show', self.calls())
        self.assertIn('live', self.run_sh('maintainer', 'status'))

    def test_every_broken_maintainer_falls_back_to_the_notification_with_the_report_filed(self):
        self.register_maintainer()
        reg = self.feedback_dir() / 'maintainer.json'
        good = reg.read_text()

        def stale_pane():
            reg.write_text(json.dumps({**json.loads(good), 'pane': 'p9'}))

        def replaced():
            reg.write_text(json.dumps({**json.loads(good), 'session': 'older-session'}))

        def blocked():
            (self.fake / 'agents/demo-master').write_text('blocked claude\n')

        def absent():
            (self.fake / 'agents/demo-master').unlink()

        def failed_prompt():
            (self.fake / 'prompt-fail').touch()

        for name, setup, why in [('stale pane', stale_pane, 'moved off pane p9'), ('replaced', replaced, 'different session'),
                                 ('blocked', blocked, 'is blocked'), ('absent', absent, 'is gone'),
                                 ('failed prompt', failed_prompt, 'prompt to the maintainer failed')]:
            with self.subTest(name):
                reg.write_text(good)
                (self.fake / 'agents/demo-master').write_text('idle claude\n')
                (self.fake / 'prompt-fail').unlink(missing_ok=True)
                (self.fake / 'calls.log').write_text('')
                setup()
                out, path = self.file_feedback()
                self.assertRegex(out, rf'delivered: notification for the human \([^)]*{why}')
                self.assertIn('notification show pstack-kitchen: feedback filed --body ' + str(path), self.calls())
                self.assertTrue(path.exists())

    def test_maintainer_off_and_status(self):
        self.assertIn('maintainer: none', self.run_sh('maintainer', 'status'))
        self.register_maintainer()
        self.assertEqual(json.loads((self.feedback_dir() / 'maintainer.json').read_text())['pane'], 'p0')
        self.assertIn('maintainer: none', self.run_sh('maintainer', 'off'))
        self.assertFalse((self.feedback_dir() / 'maintainer.json').exists())

    def test_inbox_lists_oldest_first_and_close_moves_the_report(self):
        _, first = self.file_feedback()
        text = first.read_text().replace('filed: ', 'filed: 2020-01-01T00:00:00Z\nold-filed: ')
        first.write_text(text)
        self.file_feedback(self.GAP + '\n### 2. second\n')
        lines = self.run_sh('feedback', '--inbox').strip().splitlines()
        self.assertEqual(len(lines), 2)
        self.assertTrue(lines[0].startswith(first.stem), lines)
        self.assertRegex(lines[0], r'demo\s+repo\s+unknown\s+1\s+\d+d')
        self.assertRegex(lines[1], r'demo\s+repo\s+unknown\s+2\s+\d+m')
        out = self.run_sh('feedback', '--close', first.stem, 'abc1234', 'fixed in the next build')
        self.assertIn(f'closed: {first.stem}', out)
        self.assertFalse(first.exists())
        done = (self.feedback_dir() / 'done' / first.name).read_text()
        self.assertIn('status: closed\n', done)
        self.assertIn('## Closed\n\nclosed: ', done)
        self.assertIn('commit: abc1234\nnote: fixed in the next build\n', done)
        self.assertEqual(len(self.run_sh('feedback', '--inbox').strip().splitlines()), 1)

    def test_closing_twice_prints_the_block_and_an_unknown_id_fails(self):
        _, path = self.file_feedback()
        self.run_sh('feedback', '--close', path.stem, 'none', 'wontfix')
        again = self.run_sh('feedback', '--close', path.stem, 'ffff', 'other note')
        self.assertIn('already closed', again)
        self.assertIn('note: wontfix', again)
        self.assertNotIn('ffff', (self.feedback_dir() / 'done' / path.name).read_text())
        self.assertIn('no feedback report', self.run_sh('feedback', '--close', 'nope', 'none', 'x', code=1))
        _, next_path = self.file_feedback()
        self.assertNotEqual(next_path.stem, path.stem)

    def write_builds(self, *rows):
        f = Path(self.env['XDG_STATE_HOME']) / 'pstack/builds.tsv'
        f.parent.mkdir(parents=True, exist_ok=True)
        f.write_text(''.join('\t'.join(r) + '\n' for r in rows))

    def test_init_stamps_the_skills_build_and_a_later_path_adds_a_row(self):
        here = str(skill.parent.resolve())
        builds = self.state()['skill_builds']
        self.assertEqual([b['path'] for b in builds], [here])
        self.run_sh('status', str(self.store))
        self.assertEqual(len(self.state()['skill_builds']), 1)
        state = self.state()
        state['skill_builds'][0]['path'] = '/old/skills'
        (self.store / 'pair.json').write_text(json.dumps(state))
        self.run_sh('status', str(self.store))
        self.assertEqual([b['path'] for b in self.state()['skill_builds']], ['/old/skills', here])

    def test_a_run_without_stamps_stays_unstamped(self):
        state = self.state()
        del state['skill_builds']
        (self.store / 'pair.json').write_text(json.dumps(state))
        self.run_sh('status', str(self.store))
        self.assertNotIn('skill_builds', self.state())

    def test_feedback_names_the_build_the_run_started_on_and_the_one_it_filed_with(self):
        here = str(skill.parent.resolve())
        self.write_builds(('1', 'abc123', '/old/skills'), ('2', 'def456', here))
        state = self.state()
        state['skill_builds'][0]['path'] = '/old/skills'
        (self.store / 'pair.json').write_text(json.dumps(state))
        _, path = self.file_feedback()
        text = path.read_text()
        self.assertIn('build: abc123 (/old/skills)\nfiled with: def456 (' + here + ')\n', text)

    def test_feedback_build_is_unknown_without_a_builds_file(self):
        _, path = self.file_feedback()
        self.assertIn('build: unknown (', path.read_text())

    def test_a_rate_limited_verifier_without_a_fallback_is_inconclusive(self):
        state = self.state()
        del state['sidekick']['fallback']
        (self.store / 'pair.json').write_text(json.dumps(state))
        self.rate_limited_verifier()
        _, out = self.verify_app_unit('ratelimit', 2)
        self.assertIn('provider_error: Reached free model rate limit', out)
        self.assertIn(f'next: wait for the limit, or kitchen.sh verify {self.store} 001 --kind <another kind>', out)
        self.assertNotIn('verify:missing', (self.store / 'events.tsv').read_text())

    def test_verify_deadline_scales_with_measured_gate_time(self):
        state_dir = Path(subprocess.run([sys.executable, str(script), '--repo', str(self.repo), 'statedir'],
                                        env=self.env, capture_output=True, text=True, check=True).stdout.strip())
        (state_dir / 'timings.tsv').write_text('1\tapp\tbehavioral\tverifier\tpass\t1190.5\n'
                                               '2\tapp\tbehavioral\tverifier\tfail\t9000\n')
        b = self.brief('001', 'util', ['src/**', 'tests/**'])
        self.dispatch(b)
        self.write('src/util.py', 'X = 7\n')
        self.write('tests/test_app.py', 'x = 7\n')
        self.done(b, self.commit('util'))
        (self.fake / 'verdict-mode').write_text('slow')
        self.run_sh('verify', str(self.store), '001', '--every', '0', code=4)
        v = self.state()['verifying']
        self.assertEqual(v['deadline'] - v['started'], 60 * 60)

    def deadline_fixture(self, *timings, setup=False):
        if setup:
            self.declare_setup()
        state_dir = Path(subprocess.run([sys.executable, str(script), '--repo', str(self.repo), 'statedir'],
                                        env=self.env, capture_output=True, text=True, check=True).stdout.strip())
        (state_dir / 'timings.tsv').write_text(''.join('\t'.join(t) + '\n' for t in timings))
        b = self.brief('001', 'util', ['src/**', 'tests/**'])
        self.dispatch(b)
        self.write('src/util.py', 'X = 7\n')
        self.write('tests/test_app.py', 'x = 7\n')
        self.done(b, self.commit('util'))
        (self.fake / 'verdict-mode').write_text('slow')

    def deadline_run(self, *extra):
        out = self.run_sh('verify', str(self.store), '001', '--every', '0', *extra, code=4)
        v = self.state()['verifying']
        return out, (v['deadline'] - v['started']) // 60

    def test_the_default_deadline_adds_setup_and_load_and_prints_its_parts(self):
        self.env['PSTACK_KITCHEN_LOAD'] = '22 16'
        self.deadline_fixture(('1', 'app', 'behavioral', 'verifier', 'pass', '1200'), ('2', '-', 'setup', 'verifier', 'pass', '600'),
                              setup=True)
        out, minutes = self.deadline_run()
        self.assertIn('deadline 97m: 3 x 20m gates + 10m setup, x1.38 for load 22 on 16 cores', out)
        self.assertEqual(minutes, 97)
        self.assertIn('deadline: 97m from now\n', (self.store / 'verdicts/001-u1-v1-packet.md').read_text() if False else
                      next((self.store / 'verdicts').glob('001-*-packet.md')).read_text())

    def test_the_load_factor_is_capped_and_a_setup_row_is_ignored_without_declared_setup(self):
        self.env['PSTACK_KITCHEN_LOAD'] = '100 8'
        self.deadline_fixture(('1', 'app', 'behavioral', 'verifier', 'pass', '1200'), ('2', '-', 'setup', 'verifier', 'pass', '600'))
        out, minutes = self.deadline_run()
        self.assertIn('deadline 180m: 3 x 20m gates, x3 for load 100 on 8 cores', out)
        self.assertEqual(minutes, 180)

    def test_an_unmeasured_setup_is_named_and_timeout_wins(self):
        self.deadline_fixture(('1', 'app', 'behavioral', 'verifier', 'pass', '1200'), setup=True)
        out, minutes = self.deadline_run()
        self.assertIn('deadline 60m: 3 x 20m gates + setup unmeasured, load 1 on 8 cores', out)
        self.setUp()
        self.deadline_fixture(('1', 'app', 'behavioral', 'verifier', 'pass', '1200'))
        out, minutes = self.deadline_run('--timeout', '5')
        self.assertIn('deadline 5m (--timeout)', out)
        self.assertEqual(minutes, 5)

    def test_a_malformed_load_override_is_refused(self):
        self.env['PSTACK_KITCHEN_LOAD'] = 'lots'
        self.deadline_fixture(('1', 'app', 'behavioral', 'verifier', 'pass', '60'))
        out = self.run_sh('verify', str(self.store), '001', '--every', '0', code=1)
        self.assertIn('PSTACK_KITCHEN_LOAD: expected "<load1> <cores>"', out)

    def test_dispatch_rotates_a_pi_sidekick_after_a_done_unit(self):
        state = self.state()
        state['sidekick']['rotation_required'] = True
        (self.store / 'pair.json').write_text(json.dumps(state))
        out = self.dispatch(self.brief('001', 'util', ['src/**', 'tests/**']))
        self.assertIn('rotated: the pi sidekick starts this brief in a fresh session', out)
        calls = (self.fake / 'calls.log').read_text()
        self.assertIn('agent prompt demo-sidekick /quit', calls)
        self.assertFalse(self.state()['sidekick'].get('rotation_required'))

    def test_a_running_command_is_not_a_stale_log(self):
        b = self.brief('001', 'util', ['src/**', 'tests/**'])
        self.dispatch(b)
        (self.fake / 'agents/demo-sidekick').write_text('working pi\n')
        prog = self.store / 'progress' / b.name
        prog.parent.mkdir(exist_ok=True)
        prog.write_text('- started\n')
        old = time.time() - 600
        os.utime(prog, (old, old))
        out = self.run_sh('wait', str(self.store), '--timeout', '1', '--max', '0', code=4)
        self.assertIn('STALE', out)
        self.assertNotIn('"error"', out)
        pane = self.state()['sidekick']['pane_id']
        test = subprocess.Popen(['sleep', '30'], cwd=self.repo, env={**self.env, 'HERDR_PANE_ID': pane})
        self.addCleanup(lambda: (test.kill(), test.wait()))
        time.sleep(1.1)
        out = self.run_sh('wait', str(self.store), '--timeout', '1', '--max', '0', code=4)
        self.assertIn('running: sleep for 0m', out)
        self.assertNotIn('STALE', out)

    def test_a_unit_rebased_onto_a_new_trunk_is_measured_from_it(self):
        init = self.git('rev-list', '--max-parents=0', 'HEAD')
        self.write('docs/a.md', '# A\n')
        self.commit('a, before the landing')
        b = self.brief('001', 'docs', ['docs/**'])
        self.dispatch(b)
        # The stack lands as a squash; the unit goes on from the new trunk.
        self.git('checkout', '-q', '-b', 'after-landing', init)
        self.write('docs/a.md', '# A\n')
        landed = self.commit('squash of the stack')
        self.git('update-ref', 'refs/remotes/origin/main', landed)
        self.write('docs/b.md', '# B\n')
        head = self.commit('b, on the new trunk')
        self.done(b, head)
        out = self.run_sh('verify', str(self.store), '001')
        self.assertIn("note: unit 001's recorded base", out)
        self.assertIn(f'measuring from {landed[:9]}', out)
        verdict = (self.store / 'verdicts/001-docs-v1.md').read_text()
        self.assertIn(f'range: {landed[:9]}..{head[:9]}', verdict)
        out = self.run_sh('verify', str(self.store), '001', '--base', init)
        self.assertIn(f'range: {init[:9]}..{head[:9]}', (self.store / 'verdicts/001-docs-v2.md').read_text())

    def test_land_check_reads_only_the_latest_review_round(self):
        joo = self.store / 'joo'
        joo.mkdir(exist_ok=True)
        high = {'id': 'f-old', 'severity': 'high', 'status': 'actionable', 'filePath': 'a', 'line': 1, 'summary': 's'}
        (joo / '001-util-r1.json').write_text(json.dumps({'findings': [high]}))
        self.assertIn('unresolved: f-old', self.run_sh('land-check', str(self.store), code=2))
        (joo / '001-util-r2.json').write_text(json.dumps({'findings': []}))
        out = self.run_sh('land-check', str(self.store))
        self.assertIn('land-check: pass', out)
        self.assertIn('landing verification: none', out)

    def test_a_pi_sidekick_that_exits_on_a_rate_limit_says_so(self):
        b = self.brief('001', 'util', ['src/**', 'tests/**'])
        self.dispatch(b)
        cwd = self.state()['cwd']
        logs = Path(self.env['HOME']) / '.pi/agent/sessions' / ('--' + cwd.lstrip('/').replace('/', '-') + '--')
        logs.mkdir(parents=True)
        (logs / 's.jsonl').write_text(
            '{"type":"message","message":{"role":"assistant","stopReason":"stop"}}\n'
            '{"type":"message","message":{"role":"assistant","stopReason":"error",'
            '"errorMessage":"Reached free model rate limit. Your limit will reset in 50 minutes (at 11:26 UTC)."}}\n')
        (self.fake / 'agents/demo-sidekick').unlink()
        out = self.run_sh('wait', str(self.store), '--timeout', '1', '--max', '0', code=4)
        self.assertIn('provider_error: the pi sidekick exited on: Reached free model rate limit', out)
        self.assertIn(f'next: pair.sh failover {self.store} --reason exited', out)

    def test_landing_verification_proves_the_stack_tip(self):
        init = self.git('rev-list', '--max-parents=0', 'HEAD')
        self.git('update-ref', 'refs/remotes/origin/main', init)
        b = self.brief('001', 'util', ['src/**', 'tests/**'])
        self.dispatch(b)
        self.write('src/util.py', 'X = 3\n')
        self.write('tests/test_app.py', 'x = 3\n')
        self.done(b, self.commit('util'))
        self.assertIn('name no units', self.run_sh('verify', str(self.store), '001', '--landing', code=1))
        out = self.run_sh('verify', str(self.store), '--landing')
        self.assertIn('landing base: merge-base of remotes/origin/main and HEAD', out)
        self.assertIn('verifier demo-verifier (claude --model claude-opus-5-5) in ', out)
        self.assertIn('status: clean', out)
        packet = (self.store / 'verdicts/landing-v1-packet.md').read_text()
        self.assertIn('units: landing', packet)
        self.assertIn(str(b), packet)
        self.assertIn('gate app behavioral', packet)
        self.assertIn('landing verification: clean', self.run_sh('land-check', str(self.store), code=0))

    def test_rejected_verdict_drafts_the_fix_brief(self):
        _, out = self.verify_app_unit('reject', 2)
        self.assertIn('Acceptance broke', out)
        verdict = self.store / 'verdicts/001-util-v1.md'
        self.assertIn(f'next: kitchen.sh revise {self.store} {verdict}, then verify the fix with --covers 001', out)
        fix = Path(self.run_sh('revise', str(self.store), str(verdict)).strip())
        text = fix.read_text()
        self.assertEqual(fix.name, '002-util-fix.md')
        self.assertIn(f'- verdict: {verdict}', text)
        self.assertIn('- src/** — scope', text)
        self.assertIn('playbook: bug-fix', text)

    def test_a_verdict_without_evidence_is_invalid(self):
        _, out = self.verify_app_unit('noevidence', 2)
        self.assertIn('status: invalid (no command output under Evidence)', out)

    def test_review_resolve_and_land_check(self):
        b = self.brief('001', 'util', ['src/**', 'tests/**'])
        self.dispatch(b)
        self.write('src/util.py', 'X = 4\n')
        self.write('tests/test_app.py', 'x = 4\n')
        head = self.commit('util')
        self.done(b, head)
        (self.fake / 'joo-artifact.json').write_text(json.dumps({'kind': 'review-artifact', 'findings': [
            {'id': 'finding-a', 'severity': 'high', 'status': 'actionable', 'filePath': 'src/util.py',
             'line': 1, 'summary': 'X changed meaning', 'category': 'correctness'},
            {'id': 'finding-b', 'severity': 'low', 'status': 'actionable', 'filePath': 'src/util.py',
             'line': 1, 'summary': 'name it better', 'category': 'naming'}]}))
        out = self.run_sh('review', str(self.store), '001', code=2)
        self.assertIn('finding-a high src/util.py:1 X changed meaning', out)
        self.assertNotIn('finding-b', out.split('blocking without a resolution:')[1])
        self.assertIn('--review-style standard --review-execution-budget 4 --no-second-reviewer --no-walkthrough',
                      (self.fake / 'joo.log').read_text())
        (self.store / 'reviews/001-util.md').write_text('verdict: accept\n')
        out = self.run_sh('land-check', str(self.store), code=2)
        self.assertIn('unverified: unit 001', out)
        self.assertIn('unresolved: finding-a', out)
        landing = self.brief('002', 'land', ['src/**'], playbook='opening-a-pr')
        self.assertIn('landing refused', self.dispatch(landing, code=2))
        self.run_sh('verify', str(self.store), '001')
        self.run_sh('resolve', str(self.store), 'finding-a', 'fixed', 'reverted in abc123')
        self.run_sh('resolve', str(self.store), 'finding-zzz', 'fixed', 'x', code=1)
        self.assertIn('land-check: pass (review engine: joo)', self.run_sh('land-check', str(self.store)))
        self.assertIn('blocking: none open', self.run_sh('review', str(self.store), '001'))

    def test_retro_and_counters_agree_on_verified_units(self):
        for n, status, units in [('001-a-v1', 'clean', '001 002'), ('003-c-v1', 'reject', '003'), ('003-c-v2', 'clean', '003')]:
            (self.store / 'verdicts' / f'{n}.md').write_text(f'# V\n\nstatus: {status}\nunits: {units}\n')
        out = self.run_sh('retro', str(self.store))
        self.assertIn('run demo: 0 unit reports, 3 verified units (1 clean verdicts on the first try)', out)
        counters = json.loads(subprocess.run([sys.executable, str(script), 'counters', str(self.store)], env=self.env,
                                             capture_output=True, text=True, check=True).stdout)
        self.assertEqual(counters['verified_units'], 3)

    def test_retro_counts_the_run_and_repeats_across_runs(self):
        b = self.brief('001', 'util', ['src/**', 'tests/**'])
        self.dispatch(b)
        self.write('FAIL', 'x\n')
        self.write('src/util.py', 'X = 7\n')
        sha = self.commit('broken')
        self.run_sh('step', str(self.store), sha, 'one', code=2)
        self.run_sh('step', str(self.store), sha, 'one', code=2)
        self.run_sh('catch', str(self.store), 'review', 'missed a caller in api.py')
        out = self.run_sh('retro', str(self.store))
        self.assertIn('run demo: 0 unit reports', out)
        self.assertRegex(out, r'2 gate-fail\s+app\s+in 1 runs')
        out = self.run_sh('retro', str(self.store))
        self.assertRegex(out, r'2 gate-fail\s+app\s+in 1 runs')
