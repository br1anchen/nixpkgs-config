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
                         ['--respect-workspace-trust', 'false', '--model', 'swe-2-high', '--permission-mode', 'smart'])
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
        args = ['--permission-mode', 'dangerous', '--respect-workspace-trust', 'false', '--model', 'swe-2-high']
        self.assertEqual(self.state()['sidekick']['permission_mode'], 'bypassPermissions')
        self.assertEqual(self.state()['sidekick']['start_args'], args)
        self.complete_task()
        self.run_command('rotate', str(self.store))
        self.assertEqual(self.state()['sidekick']['start_args'], args)

    def test_explicit_permission_overrides_default_bypass(self):
        for options, expected in [
            (['--permission', 'auto'], ['--permission-mode', 'smart', '--respect-workspace-trust', 'false']),
            (['--', '--permission-mode', 'smart'], ['--respect-workspace-trust', 'false', '--permission-mode', 'smart']),
            (['--permission', 'none', '--', '--model', 'swe-2-high'],
             ['--respect-workspace-trust', 'false', '--model', 'swe-2-high']),
            (['--', '--respect-workspace-trust', 'true'],
             ['--permission-mode', 'dangerous', '--respect-workspace-trust', 'true']),
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
        self.assertEqual(state['sidekick']['start_args'], ['--permission-mode', 'dangerous', '--respect-workspace-trust', 'false'])
        self.assertEqual(state['consultant']['permission_mode'], state['master']['permission_mode'])
        (self.fake / 'agents/permissions-sidekick').unlink()
        (self.fake / 'agents/permissions-consultant').unlink()
        self.run_command('spawn', str(self.store), '--sidekick', 'devin',
                         '--consultant', 'codex', '--permission', 'auto',
                         '--consultant-permission', 'plan')
        state = self.state()
        self.assertEqual(state['sidekick']['start_args'], ['--permission-mode', 'smart', '--respect-workspace-trust', 'false'])
        self.assertEqual(state['consultant']['start_args'],
                         ['-a', 'on-request', '-s', 'read-only'])


class PiSidekickTests(unittest.TestCase):
    """A pi sidekick, its print-mode preflight, and failover to a fallback kind."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.path = Path(self.tmp.name)
        self.fake = self.path / 'fake'
        self.fake.mkdir()
        repo = self.path / 'repo'
        repo.mkdir()
        self.cwd = repo
        self.env = {**os.environ, 'FAKE': str(self.fake),
                    'PATH': f'{here / "bin"}:{os.environ["PATH"]}',
                    'HOME': str(self.path / 'home'), 'XDG_STATE_HOME': str(self.path / 'state'),
                    'HERDR_ENV': '1', 'HERDR_PANE_ID': 'p0', 'PAIR_SETTLE_HOLD': '0'}
        self.env.pop('CLAUDE_CODE_SESSION_ID', None)
        self.script = skills / 'pstack-pair/scripts/pair.sh'
        self.store = self.path / 'state/pstack/pair/demo'
        self.run_command('init', 'demo')
        hook = self.fake / 'hook'
        hook.write_text(f'''#!/usr/bin/env bash
case "$2" in
Load*) printf 'status: done\\n' >'{self.store}/reports/000-ready.md' ;;
esac
''')
        hook.chmod(0o755)

    def run_command(self, *args, code=0):
        result = subprocess.run([self.script, *args], cwd=self.cwd, env=self.env,
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, code, result.stdout + result.stderr)
        return result.stdout + result.stderr

    def state(self):
        return json.loads((self.store / 'pair.json').read_text())

    def spawn_pi(self, *fallback, code=0):
        return self.run_command('spawn', str(self.store), '--kind', 'pi', '--permission', 'auto',
                                *fallback, '--', '--model', 'devin/swe-2', '--thinking', 'high', code=code)

    def dispatch(self):
        brief = self.store / 'briefs/001-first.md'
        brief.write_text('playbook: investigation\nplan: none\ntimebox: 30\n')
        return brief, self.run_command('dispatch', str(self.store), str(brief), '--timeout', '1', code=4)

    def test_pi_starts_with_approve_after_a_clean_preflight(self):
        self.spawn_pi()
        state = self.state()
        self.assertEqual(state['sidekick']['kind'], 'pi')
        self.assertEqual(state['sidekick']['start_args'],
                         ['--approve', '--model', 'devin/swe-2', '--thinking', 'high'])
        self.assertNotIn('failovers', state['sidekick'])
        preflight = (self.fake / 'pi.log').read_text().split('\n')[0]
        self.assertEqual(preflight, '--no-session --no-approve --no-context-files --no-skills -p '
                         '--model devin/swe-2 --thinking high Reply with exactly: OK')

    def test_failed_preflight_starts_the_fallback_with_its_own_args(self):
        (self.fake / 'pi-fail').write_text('Error: capacity issues with this serving model\n')
        out = self.spawn_pi('--fallback', 'devin', '--fallback-arg', '--model', '--fallback-arg', 'swe-2-high')
        self.assertIn('failover: pi -> devin', out)
        sidekick = self.state()['sidekick']
        self.assertEqual(sidekick['kind'], 'devin')
        self.assertEqual(sidekick['start_args'],
                         ['--permission-mode', 'dangerous', '--respect-workspace-trust', 'false', '--model', 'swe-2-high'])
        self.assertEqual(sidekick['failovers'][0]['from'], 'pi')
        self.assertIn('capacity issues', sidekick['failovers'][0]['reason'])
        self.assertIn('preflight: pi 1.0.2 at ', sidekick['failovers'][0]['reason'])

    def test_failed_preflight_without_fallback_starts_nothing(self):
        (self.fake / 'pi-fail').write_text('No API key found for devin.\n')
        self.spawn_pi(code=2)
        self.assertFalse((self.fake / 'agents/demo-sidekick').exists())

    def test_bootstrap_left_typed_by_a_first_run_screen_is_submitted(self):
        (self.fake / 'stall').touch()
        out = self.spawn_pi()
        self.assertIn('prompt looked stalled', out)
        self.assertIn('send-keys demo-sidekick enter', (self.fake / 'calls.log').read_text())
        self.assertFalse(self.state()['sidekick']['bootstrap_pending'])

    def test_done_brief_gets_a_fresh_pi_session_and_keeps_the_queue(self):
        self.spawn_pi()
        args = self.state()['sidekick']['start_args']
        brief, _ = self.dispatch()
        report = self.store / 'reports' / brief.name
        report.write_text('status: done\n')
        queued = self.store / 'briefs/002-next.md'
        queued.write_text('playbook: investigation\nplan: none\ntimebox: 30\n')
        (self.fake / 'agents/demo-sidekick').write_text('working pi\n')
        self.run_command('queue', str(self.store), str(queued))
        (self.fake / 'agents/demo-sidekick').write_text('idle pi\n')
        out = self.run_command('finish', str(self.store), str(report))
        self.assertIn('rotation: required before the next task', out)
        self.run_command('next', str(self.store), code=5)
        self.run_command('dispatch', str(self.store), str(queued), code=5)
        self.run_command('rotate', str(self.store))
        self.assertIn('agent prompt demo-sidekick /quit', (self.fake / 'calls.log').read_text())
        sidekick = self.state()['sidekick']
        self.assertEqual((sidekick['kind'], sidekick['generation'], sidekick['start_args']), ('pi', 2, args))
        self.assertFalse(sidekick['rotation_required'])
        self.assertTrue((self.store / 'queue').exists())
        self.run_command('dispatch', str(self.store), str(queued), '--timeout', '1', code=4)

    def test_pi_refuses_session_resume_args(self):
        out = self.run_command('spawn', str(self.store), '--kind', 'pi', '--', '--continue', code=5)
        self.assertIn('pi task sessions start fresh', out)

    def test_tab_placement_gives_the_sidekick_its_own_tab(self):
        self.run_command('spawn', str(self.store), '--kind', 'pi', '--tab', '--', '--model', 'devin/swe-2')
        calls = (self.fake / 'calls.log').read_text()
        self.assertRegex(calls, r'tab create --workspace p0 --cwd \S+ --label demo-sidekick --no-focus')
        self.assertNotIn('pane split', calls)
        state = self.state()
        self.assertEqual((state['placement'], state['sidekick']['pane_id'][:1]), ('tab', 't'))
        self.assertIn(f"take the sidekick role (generation 1, pane {state['sidekick']['pane_id']})", calls)

    def test_placement_defaults_from_the_environment_and_split_overrides(self):
        self.env['PSTACK_PLACEMENT'] = 'tab'
        self.spawn_pi()
        self.assertEqual(self.state()['placement'], 'tab')
        (self.fake / 'agents/demo-sidekick').unlink()
        self.run_command('spawn', str(self.store), '--kind', 'pi', '--split', '--', '--model', 'devin/swe-2')
        self.assertEqual(self.state()['placement'], 'split')

    def test_init_names_a_stale_pane_and_takes_pane(self):
        self.env['HERDR_PANE_ID'] = 'gone7'
        out = self.run_command('init', 'other', code=2)
        self.assertIn("pane gone7 is not a live Herdr pane", out)
        self.assertIn('--pane ID', out)
        self.run_command('init', 'other', '--pane', 'p0')
        master = json.loads((self.path / 'state/pstack/pair/other/pair.json').read_text())['master']
        self.assertEqual(master['pane_id'], 'p0')

    def test_live_pi_skips_the_preflight(self):
        self.spawn_pi()
        (self.fake / 'pi.log').unlink()
        self.spawn_pi()
        self.assertFalse((self.fake / 'pi.log').exists())

    def test_failover_swaps_kind_in_the_same_pane_once(self):
        self.spawn_pi('--fallback', 'devin')
        pane = self.state()['sidekick']['pane_id']
        brief, _ = self.dispatch()
        out = self.run_command('failover', str(self.store), '--reason', 'provider-error')
        self.assertIn('agent prompt demo-sidekick /quit', (self.fake / 'calls.log').read_text())
        sidekick = self.state()['sidekick']
        self.assertEqual((sidekick['kind'], sidekick['pane_id'], sidekick['generation']), ('devin', pane, 2))
        self.assertEqual(sidekick['failovers'][-1]['reason'], 'provider-error')
        self.assertIn(f'next: re-dispatch {brief}', out)
        self.assertIn('failovers: 1 (pi:devin)', self.run_command('metrics', str(self.store)))
        self.run_command('failover', str(self.store), code=5)

    def test_failover_needs_a_fallback_and_force_for_a_working_sidekick(self):
        self.spawn_pi()
        self.run_command('failover', str(self.store), code=5)
        (self.fake / 'agents/demo-sidekick').unlink()
        self.spawn_pi('--fallback', 'devin')
        (self.fake / 'agents/demo-sidekick').write_text('working pi\n')
        self.run_command('failover', str(self.store), code=5)
        self.run_command('failover', str(self.store), '--force')
        self.assertIn('send-keys demo-sidekick esc', (self.fake / 'calls.log').read_text())
        self.assertEqual(self.state()['sidekick']['kind'], 'devin')

    def test_missing_report_names_a_provider_error_and_the_failover(self):
        self.spawn_pi('--fallback', 'devin')
        screen = self.fake / 'screen'
        screen.mkdir()
        (screen / 'demo-sidekick').write_text(
            'Error: We are currently experiencing capacity issues with this serving model.\n')
        _, out = self.dispatch()
        self.assertIn('report: missing', out)
        self.assertIn('provider_error: Error: We are currently experiencing capacity issues', out)
        self.assertIn(f'pair.sh failover {self.store} --reason provider-error', out)

    def test_missing_report_without_provider_error_says_nothing_extra(self):
        self.spawn_pi('--fallback', 'devin')
        _, out = self.dispatch()
        self.assertIn('report: missing', out)
        self.assertNotIn('provider_error', out)


if __name__ == '__main__':
    unittest.main()
