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
import time
import unittest

root = Path(__file__).resolve().parents[1]
here = root / 'tests/pstack-pair'
skills = root / 'config/pstack/skills'


class PairScriptTests(unittest.TestCase):
    def check(self, variant):
        env = {k: v for k, v in os.environ.items() if k != 'PSTACK_PLACEMENT'}
        out = subprocess.run([here / 'scenario.sh', skills, variant], env=env, capture_output=True, text=True, check=True).stdout
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
        self.env = {**{k: v for k, v in os.environ.items() if k != 'PSTACK_PLACEMENT'}, 'FAKE': str(self.fake),
                    'PATH': f'{here / "bin"}:{os.environ["PATH"]}',
                    'HOME': str(self.path / 'home'), 'XDG_STATE_HOME': str(self.path / 'state'),
                    'HERDR_ENV': '1', 'HERDR_PANE_ID': 'p0', 'PAIR_SUBMIT_CHECK_S': '0'}
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
        report.write_text(f'status: {status}\nhead: abc123\n')
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


class ReadinessTests(unittest.TestCase):
    """A done report is a reply only when finish would accept it: no open notes, head at the last step."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.path = Path(self.tmp.name)
        self.fake = self.path / 'fake'
        self.fake.mkdir()
        self.cwd = self.path / 'repo'
        self.cwd.mkdir()
        self.env = {**{k: v for k, v in os.environ.items() if k != 'PSTACK_PLACEMENT'}, 'FAKE': str(self.fake),
                    'PATH': f'{here / "bin"}:{os.environ["PATH"]}',
                    'HOME': str(self.path / 'home'), 'XDG_STATE_HOME': str(self.path / 'state'),
                    'HERDR_ENV': '1', 'HERDR_PANE_ID': 'p0', 'PAIR_SUBMIT_CHECK_S': '0', 'PAIR_SETTLE_HOLD': '0',
                    'GIT_AUTHOR_NAME': 't', 'GIT_AUTHOR_EMAIL': 't@t', 'GIT_COMMITTER_NAME': 't', 'GIT_COMMITTER_EMAIL': 't@t'}
        self.env.pop('CLAUDE_CODE_SESSION_ID', None)
        self.script = skills / 'pstack-pair/scripts/pair.sh'
        self.store = self.path / 'state/pstack/pair/demo'
        self.git('init', '-q')
        self.commit('c0')
        self.run_command('init', 'demo')
        hook = self.fake / 'hook'
        hook.write_text(f"#!/usr/bin/env bash\ncase \"$2\" in\nLoad*) printf 'status: done\\n' >'{self.store}/reports/000-ready.md' ;;\nesac\n")
        hook.chmod(0o755)
        self.run_command('spawn', str(self.store), '--kind', 'pi', '--permission', 'auto', '--', '--model', 'm')
        self.brief = self.store / 'briefs/001-first.md'
        self.brief.write_text('playbook: investigation\nplan: none\ntimebox: 30\n')
        self.run_command('dispatch', str(self.store), str(self.brief), '--timeout', '1', code=4)
        (self.fake / 'agents/demo-sidekick').write_text('working pi\n')
        self.report = self.store / 'reports/001-first.md'

    def git(self, *args):
        return subprocess.run(['git', *args], cwd=self.cwd, env=self.env, check=True, capture_output=True, text=True).stdout.strip()

    def commit(self, message):
        (self.cwd / 'f.txt').write_text(message)
        self.git('add', 'f.txt')
        self.git('commit', '-q', '-m', message)
        return self.git('rev-parse', 'HEAD')

    def run_command(self, *args, code=0):
        r = subprocess.run([self.script, *args], cwd=self.cwd, env=self.env, capture_output=True, text=True, check=False)
        self.assertEqual(r.returncode, code, r.stdout + r.stderr)
        return r.stdout + r.stderr

    def step(self, sha, resolves=None):
        extra = ['--resolves', resolves] if resolves else []
        self.run_command('step', str(self.store), sha, 'a step', *extra)

    def note(self, k, status='blocking'):
        f = self.store / f'notes/001-first-n{k}.md'
        f.parent.mkdir(exist_ok=True)
        f.write_text(f'# Note\n\nstatus: {status}\n\n## Blocking\n\n1. fix it\n')

    def write_report(self, head, status='done'):
        self.report.write_text(f'# Report\n\nstatus: {status}\nhead: {head}\n')

    def wait(self, code):
        return self.run_command('wait', str(self.store), '--timeout', '1000', code=code)

    def test_a_done_report_over_an_open_note_is_not_a_reply(self):
        c1 = self.commit('one')
        self.step(c1)
        self.note(1)
        self.write_report(c1)
        out = self.wait(4)
        self.assertIn(f'report: {self.report} written but not ready: open blocking notes n1', out)
        self.assertNotIn('report_status', out)
        self.assertIn('report:unready', (self.store / 'events.tsv').read_text())

    def test_the_resolving_step_does_not_expose_the_old_report_until_it_is_rewritten(self):
        c1 = self.commit('one')
        self.step(c1)
        self.note(1)
        self.write_report(c1)
        c2 = self.commit('two')
        self.step(c2, 'n1')
        self.note(2, 'clear')
        out = self.wait(4)
        self.assertIn(f'written but not ready: the report\'s head {c1[:9]} predates step 2 {c2[:9]}', out)
        self.write_report(c2)
        out = self.wait(0)
        self.assertIn(f'report: {self.report}\nreport_status: done', out)

    def test_finish_refuses_a_report_that_is_not_ready(self):
        c1 = self.commit('one')
        self.step(c1)
        self.note(1)
        self.write_report(c1)
        self.assertIn('blocking review notes are still open', self.run_command('finish', str(self.store), str(self.report), code=7))
        c2 = self.commit('two')
        self.step(c2, 'n1')
        self.assertIn(f'predates step 2 {c2[:9]}', self.run_command('finish', str(self.store), str(self.report), code=7))
        self.write_report(c2)
        self.run_command('finish', str(self.store), str(self.report))

    def test_an_earlier_shown_reply_then_a_withheld_report_is_named_not_idle(self):
        c1 = self.commit('one')
        self.step(c1)
        self.write_report(c1)
        self.assertIn('report_status: done', self.wait(0))
        self.note(1)
        (self.fake / 'agents/demo-sidekick').write_text('idle pi\n')
        out = self.wait(4)
        self.assertIn('written but not ready: open blocking notes n1', out)
        self.assertNotIn('send the next message', out)

    def test_a_withheld_report_does_not_hide_reviewable_steps(self):
        c1 = self.commit('one')
        self.step(c1)
        self.note(1)
        c2 = self.commit('two')
        self.step(c2)
        self.write_report(c2)
        out = self.wait(0)
        self.assertIn('steps: 1 to review on 001-first', out)

    def test_an_earlier_unit_is_judged_by_its_own_notes_while_the_next_one_runs(self):
        c1 = self.commit('one')
        self.step(c1)
        self.note(1)
        self.write_report(c1)
        second = self.store / 'briefs/002-second.md'
        second.write_text('playbook: investigation\nplan: none\ntimebox: 30\n')
        state = json.loads((self.store / 'pair.json').read_text())
        state['dispatch']['brief'] = str(second)
        state['pending'] = [str(self.brief)]
        (self.store / 'pair.json').write_text(json.dumps(state))
        self.assertNotIn('report_status', self.wait(4))
        (self.store / 'notes/001-first-n1.md').write_text('# Note\n\nstatus: resolved\n')
        self.assertIn(f'report: {self.report}', self.wait(0))

    def quiet_log(self, minutes=20):
        prog = self.store / 'progress/001-first.md'
        prog.parent.mkdir(exist_ok=True)
        prog.write_text('- started\n')
        old = time.time() - minutes * 60
        os.utime(prog, (old, old))

    def age(self, name, seconds):
        t = time.time() - seconds
        os.utime(self.cwd / name, (t, t))

    def test_a_recent_edit_is_editing_not_stale(self):
        self.quiet_log()
        (self.cwd / 'f.txt').write_text('changed')
        out = self.wait(4)
        self.assertRegex(out, r'progress: \+1 lines \(last 20m ago\)  editing: last change 0m ago')
        self.assertNotIn('STALE', out)

    def test_old_files_and_no_command_is_stale(self):
        self.quiet_log()
        (self.cwd / 'f.txt').write_text('changed')
        self.age('f.txt', 3600)
        self.assertIn('STALE', self.wait(4))

    def test_a_recent_commit_counts_as_editing(self):
        self.quiet_log()
        self.commit('two')
        self.age('f.txt', 3600)
        self.assertIn('editing: last change', self.wait(4))

    def test_a_running_command_wins_over_editing(self):
        self.quiet_log()
        (self.cwd / 'f.txt').write_text('changed')
        pane = json.loads((self.store / 'pair.json').read_text())['sidekick']['pane_id']
        proc = subprocess.Popen(['sleep', '30'], cwd=self.cwd, env={**self.env, 'HERDR_PANE_ID': pane})
        self.addCleanup(lambda: (proc.kill(), proc.wait()))
        time.sleep(1.1)
        out = self.wait(4)
        self.assertIn('running: sleep for 0m', out)
        self.assertNotIn('editing:', out)

    def test_deleted_renamed_and_oddly_named_files_do_not_break_checkin(self):
        (self.cwd / 'a b.txt').write_text('x')
        self.git('add', 'a b.txt')
        self.env['GIT_COMMITTER_DATE'] = '2020-01-01T00:00:00'
        self.git('commit', '-q', '-m', 'add')
        del self.env['GIT_COMMITTER_DATE']
        self.git('mv', 'a b.txt', 'c d.txt')
        (self.cwd / 'f.txt').unlink()
        self.age('c d.txt', 3600)
        self.quiet_log()
        self.assertIn('STALE', self.wait(4))
        (self.cwd / 'c d.txt').write_text('edit')
        self.assertIn('editing: last change', self.wait(4))

    def test_a_future_mtime_does_not_keep_it_active(self):
        self.quiet_log()
        (self.cwd / 'f.txt').write_text('changed')
        self.age('f.txt', -7200)
        self.assertIn('STALE', self.wait(4))

    def test_partial_blocked_and_old_style_reports_are_unaffected(self):
        c1 = self.commit('one')
        self.step(c1)
        self.note(1)
        for status in ('partial', 'blocked', 'failed'):
            self.write_report(c1, status)
            self.assertIn(f'report_status: {status}', self.wait(0))
            state = json.loads((self.store / 'pair.json').read_text())
            state['sent'].pop('seen', None)
            state['pending'] = [str(self.brief)]
            (self.store / 'pair.json').write_text(json.dumps(state))
        (self.store / 'notes/001-first-n1.md').unlink()
        (self.store / 'steps/001-first.tsv').unlink()
        self.write_report('abc123')
        self.assertIn('report_status: done', self.wait(0))


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
        self.env = {**{k: v for k, v in os.environ.items() if k != 'PSTACK_PLACEMENT'}, 'FAKE': str(self.fake),
                    'PATH': f'{here / "bin"}:{os.environ["PATH"]}',
                    'HOME': str(self.path / 'home'), 'XDG_STATE_HOME': str(self.path / 'state'),
                    'HERDR_ENV': '1', 'HERDR_PANE_ID': 'p0', 'PAIR_SUBMIT_CHECK_S': '0', 'PAIR_SETTLE_HOLD': '0',
                    'PAIR_PREFLIGHT_RETRY_S': '0'}
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
        self.assertIn(', twice: exit 1 ', sidekick['failovers'][0]['reason'])

    def test_one_failed_preflight_is_retried_before_a_failover(self):
        (self.fake / 'pi-fail-once').touch()
        self.spawn_pi('--fallback', 'devin')
        self.assertEqual(self.state()['sidekick']['kind'], 'pi')
        self.assertNotIn('failovers', self.state()['sidekick'])

    def test_done_report_without_its_head_is_refused_in_the_same_turn(self):
        self.spawn_pi()
        brief, _ = self.dispatch()
        report = self.store / 'reports' / brief.name
        report.write_text('# Report\n\nstatus: done\n')
        out = self.run_command('finish', str(self.store), str(report), code=1)
        self.assertIn("needs the report template's header, with head:", out)
        report.write_text('# Report\n\nstatus: done\nhead: abc123\n')
        self.run_command('finish', str(self.store), str(report))

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
        report.write_text('status: done\nhead: abc123\n')
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

    def test_prompts_typed_but_reported_sent_are_submitted(self):
        (self.fake / 'typed-ok').touch()
        self.spawn_pi()
        self.assertFalse(self.state()['sidekick']['bootstrap_pending'])
        (self.fake / 'typed-ok').touch()
        self.dispatch()
        calls = (self.fake / 'calls.log').read_text()
        self.assertEqual(calls.count('send-keys demo-sidekick enter'), 2)

    def test_send_only_returns_once_the_brief_is_delivered(self):
        self.spawn_pi()
        brief = self.store / 'briefs/001-first.md'
        brief.write_text('playbook: investigation\nplan: none\ntimebox: 30\n')
        out = self.run_command('dispatch', str(self.store), str(brief), '--send-only')
        self.assertIn(f'sent: BRIEF {brief}', out)
        self.assertEqual(self.state()['dispatch']['brief'], str(brief))

    def test_a_timeout_cannot_cut_a_delivery_short(self):
        self.spawn_pi()
        brief = self.store / 'briefs/001-first.md'
        brief.write_text('playbook: investigation\nplan: none\ntimebox: 30\n')
        (self.fake / 'prompt-delay').write_text('3')
        result = subprocess.run(['timeout', '1', str(self.script), 'dispatch', str(self.store), str(brief), '--send-only'],
                                cwd=self.cwd, env=self.env, capture_output=True, text=True, check=False)
        # timeout reports 124 once its limit passes, however the command ends;
        # what matters is that the TERM did not stop the delivery.
        self.assertIn(f'sent: BRIEF {brief}', result.stdout, result.stderr)
        self.assertIn(f'agent prompt demo-sidekick pstack-pair BRIEF {brief}', (self.fake / 'calls.log').read_text())

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
