"""Golden transcripts for the pstack-pair family's pair.sh.

tests/pstack-pair/scenario.sh drives each variant through every command
against a fake herdr and prints a normalized transcript: output, exit codes,
herdr calls, and the final store. The transcript must match the golden file.
After an intended change, regenerate with PSTACK_PAIR_UPDATE=1 and review the
golden diff. The permission mode comes from the agent above the test process,
so run this from a plain shell or a default-mode agent session.
"""
from pathlib import Path
import os
import json
import subprocess
import tempfile
import unittest

root = Path(__file__).resolve().parents[1]
here = root / 'tests/pstack-pair'
skills = root / 'config/pstack/skills'


class PairScriptTests(unittest.TestCase):
    def check(self, variant):
        out = subprocess.run([here / 'scenario.sh', skills, variant], capture_output=True, text=True, check=True).stdout
        golden = here / 'golden' / f'{variant}.txt'
        if os.environ.get('PSTACK_PAIR_UPDATE') == '1':
            golden.write_text(out)
        self.assertEqual(out, golden.read_text())

    def test_pair(self):
        self.check('pair')

    def test_guided(self):
        self.check('guided')

    def test_trio(self):
        self.check('trio')


class DevinSessionTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.path = Path(self.tmp.name)
        self.fake = self.path / 'fake'
        self.fake.mkdir()
        self.repo = self.path / 'repo'
        self.repo.mkdir()
        self.env = {**os.environ, 'FAKE': str(self.fake),
                    'PATH': f'{here / "bin"}:{os.environ["PATH"]}',
                    'HOME': str(self.path / 'home'), 'XDG_STATE_HOME': str(self.path / 'state'),
                    'HERDR_ENV': '1', 'HERDR_PANE_ID': 'p0'}
        self.env.pop('CLAUDE_CODE_SESSION_ID', None)
        self.script = skills / 'pstack-pair/scripts/pair.sh'
        self.store = self.path / 'state/pstack/pair/demo'
        self.run_command('init', 'demo')
        hook = self.fake / 'hook'
        hook.write_text(f'''#!/usr/bin/env bash
case "$2" in
Load*)
  [ -e "$FAKE/no-ready" ] || printf 'status: done\\n' >'{self.store}/reports/000-ready.md'
  ;;
esac
''')
        hook.chmod(0o755)
        self.run_command('spawn', str(self.store), '--kind', 'devin', '--',
                         '--model', 'swe-2-high', '--permission-mode', 'smart')

    def run_command(self, *args, code=0):
        result = subprocess.run([self.script, *args], cwd=self.repo, env=self.env,
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, code, result.stdout + result.stderr)
        return result.stdout + result.stderr

    def state(self):
        return json.loads((self.store / 'pair.json').read_text())

    def write_brief(self, name):
        brief = self.store / 'briefs' / name
        brief.write_text('playbook: investigation\nplan: none\ntimebox: 30\n')
        return brief

    def complete_task(self, status='done'):
        brief = self.write_brief('001-first.md')
        self.run_command('dispatch', str(self.store), str(brief), '--timeout', '1', code=4)
        report = self.store / 'reports' / brief.name
        report.write_text(f'status: {status}\n')
        queued = self.write_brief('002-next.md')
        (self.fake / 'agents/demo-sidekick').write_text('working devin\n')
        self.run_command('queue', str(self.store), str(queued))
        (self.fake / 'agents/demo-sidekick').write_text('idle devin\n')
        self.run_command('finish', str(self.store), str(report))
        return report, queued

    def test_done_requires_fresh_session_and_preserves_queue(self):
        report, queued = self.complete_task()
        self.run_command('next', str(self.store), code=5)
        self.run_command('dispatch', str(self.store), str(queued), code=5)
        self.assertEqual((self.store / 'queue').read_text().strip(), str(queued))
        self.assertEqual(self.state()['dispatch']['brief'], str(self.store / 'briefs/001-first.md'))
        self.run_command('rotate', str(self.store))
        state = self.state()
        self.assertEqual(state['sidekick']['generation'], 2)
        self.assertEqual(state['sidekick']['start_args'],
                         ['--model', 'swe-2-high', '--permission-mode', 'smart'])
        self.assertFalse(state['sidekick']['rotation_required'])
        self.assertTrue(report.exists())
        self.assertTrue((self.store / 'queue').exists())
        # A delayed finish from the previous generation cannot invalidate READY.
        self.run_command('finish', str(self.store), str(report))
        self.assertFalse(self.state()['sidekick']['rotation_required'])
        self.run_command('dispatch', str(self.store), str(queued), '--timeout', '1', code=4)
        self.assertFalse((self.store / 'queue').exists())

    def test_partial_task_keeps_session_and_queue(self):
        _, queued = self.complete_task(status='partial')
        self.run_command('rotate', str(self.store), code=5)
        self.assertEqual(self.state()['sidekick']['generation'], 1)
        self.assertEqual((self.store / 'queue').read_text().strip(), str(queued))

    def test_old_ready_cannot_satisfy_failed_bootstrap(self):
        self.complete_task()
        (self.fake / 'no-ready').touch()
        self.run_command('rotate', str(self.store), code=4)
        self.assertFalse((self.store / 'reports/000-ready.md').exists())
        self.assertTrue(self.state()['sidekick']['rotation_required'])
        self.assertTrue((self.store / 'sessions/sidekick-2-previous-ready.md').exists())

    def test_maintenance_pause_prevents_rotation_and_queue_pickup(self):
        self.complete_task()
        self.run_command('pause', str(self.store), '--reason', 'database maintenance')
        self.run_command('rotate', str(self.store), code=5)
        self.assertEqual(self.state()['sidekick']['generation'], 1)
        self.assertTrue((self.store / 'queue').exists())

    def test_late_ready_recovers_initial_and_rotated_bootstrap(self):
        for rotated in (False, True):
            with self.subTest(rotated=rotated):
                if rotated:
                    self.complete_task()
                else:
                    (self.fake / 'agents/demo-sidekick').unlink()
                (self.fake / 'no-ready').touch()
                if rotated:
                    self.run_command('rotate', str(self.store), code=4)
                else:
                    self.run_command('spawn', str(self.store), '--kind', 'devin', code=4)
                generation = self.state()['sidekick']['generation']
                self.run_command('spawn', str(self.store), '--kind', 'devin', code=4)
                brief = self.write_brief('002-next.md' if rotated else '003-after-ready.md')
                self.run_command('dispatch', str(self.store), str(brief), code=5)
                (self.store / 'reports/000-ready.md').write_text('status: done\n')
                (self.fake / 'no-ready').unlink()
                self.run_command('spawn', str(self.store), '--kind', 'devin')
                state = self.state()
                self.assertFalse(state['sidekick']['bootstrap_pending'])
                self.assertFalse(state['sidekick']['rotation_required'])
                self.assertEqual(state['sidekick']['generation'], generation)
                self.run_command('dispatch', str(self.store), str(brief), '--timeout', '1', code=4)

    def test_default_bypass_is_preserved_on_rotation(self):
        (self.fake / 'agents/demo-sidekick').unlink()
        self.run_command('spawn', str(self.store), '--kind', 'devin', '--',
                         '--model', 'swe-2-high')
        args = ['--permission-mode', 'dangerous', '--model', 'swe-2-high']
        self.assertEqual(self.state()['sidekick']['permission_mode'], 'bypassPermissions')
        self.assertEqual(self.state()['sidekick']['start_args'], args)
        self.complete_task()
        self.run_command('rotate', str(self.store))
        self.assertEqual(self.state()['sidekick']['start_args'], args)

    def test_explicit_permission_overrides_default_bypass(self):
        for options, expected in [
            (['--permission', 'auto'], ['--permission-mode', 'smart']),
            (['--', '--permission-mode', 'smart'], ['--permission-mode', 'smart']),
            (['--permission', 'none', '--', '--model', 'swe-2-high'],
             ['--model', 'swe-2-high']),
        ]:
            with self.subTest(options=options):
                (self.fake / 'agents/demo-sidekick').unlink()
                self.run_command('spawn', str(self.store), '--kind', 'devin', *options)
                self.assertEqual(self.state()['sidekick']['start_args'], expected)

    def test_trio_defaults_and_consultant_override_are_independent(self):
        self.script = skills / 'pstack-trio/scripts/pair.sh'
        self.store = self.path / 'state/pstack/trio/permissions'
        self.run_command('init', 'permissions')
        (self.fake / 'hook').write_text(f'''#!/usr/bin/env bash
case "$2" in
Load*)
  printf 'status: done\\n' >'{self.store}/reports/000-ready.md'
  printf 'status: answered\\n' >'{self.store}/advice/000-ready.md'
  ;;
esac
''')
        self.run_command('spawn', str(self.store), '--sidekick', 'devin',
                         '--consultant', 'codex')
        state = self.state()
        self.assertEqual(state['sidekick']['start_args'], ['--permission-mode', 'dangerous'])
        self.assertEqual(state['consultant']['permission_mode'], state['master']['permission_mode'])
        (self.fake / 'agents/permissions-sidekick').unlink()
        (self.fake / 'agents/permissions-consultant').unlink()
        self.run_command('spawn', str(self.store), '--sidekick', 'devin',
                         '--consultant', 'codex', '--permission', 'auto',
                         '--consultant-permission', 'plan')
        state = self.state()
        self.assertEqual(state['sidekick']['start_args'], ['--permission-mode', 'smart'])
        self.assertEqual(state['consultant']['start_args'],
                         ['-a', 'on-request', '-s', 'read-only'])


if __name__ == '__main__':
    unittest.main()
