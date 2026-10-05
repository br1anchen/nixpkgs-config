"""kitchen.py against a throwaway repo: the kitchen.toml schema, classify,
gate, policy, and doctor, end to end through the command line."""
import json
import os
import subprocess
import sys
import tempfile
import textwrap
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
        self.env = {**os.environ, 'XDG_STATE_HOME': str(Path(self.tmp.name) / 'state'),
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
        return result.stdout + result.stderr

    def data(self, *args, code=0):
        return json.loads(self.run_kitchen('--json', *args, code=code))

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
        self.assertEqual(r['verify'], {'mode': 'batch', 'kind': 'sidekick'})
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
                self.assertEqual(r['verify'], {'mode': 'unit', 'kind': 'master'})
                self.assertEqual((r['sample'], r['review']['style']), (1.0, 'thorough'))
                self.base = self.git('rev-parse', 'HEAD')

    def test_scope_globs_expand_against_tracked_files(self):
        r = self.data('classify', '--paths', 'src/**', 'src/new.py')
        self.assertEqual([f['path'] for f in r['files']], ['src/app.py', 'src/util.py', 'src/new.py'])
        self.assertEqual(r['profiles'], ['app'])

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


class GateTests(KitchenTests):
    def test_passing_gate_and_logs(self):
        r = self.data('gate', 'app', 'fast')
        self.assertTrue(r['passed'])
        self.assertTrue(Path(r['commands'][0]['log']).exists())
        self.assertEqual(self.data('gate', 'app', 'landing'), {'profile': 'app', 'stage': 'landing',
                                                                'passed': True, 'commands': []})

    def test_failing_gate_prints_the_log_tail_and_exits_2(self):
        self.write('.agents/kitchen.toml', KITCHEN.replace(
            'fast = ["test -f src/app.py"]', 'fast = ["echo boom; exit 3", "echo second"]'))
        out = self.run_kitchen('gate', 'app', 'fast', code=2)
        self.assertIn('app fast: FAIL', out)
        self.assertIn('exit 3', out)
        self.assertIn('| boom', out)
        self.assertIn('exit 0', out)
        self.assertEqual(len(self.data('gate', 'app', 'fast', '--fail-fast', code=2)['commands']), 1)

    def test_heavy_gate_releases_its_slot(self):
        self.write('.agents/kitchen.toml', KITCHEN.replace('sample = 0.2', 'sample = 0.2\nheavy = true'))
        self.data('gate', 'app', 'fast')
        self.data('gate', 'app', 'fast')
        locks = list((Path(self.tmp.name) / 'state/pstack/kitchen/repos').glob('heavy-*.lock'))
        self.assertEqual([p.name for p in locks], ['heavy-0.lock'])

    def test_unknown_profile(self):
        self.assertIn('no profile web', self.run_kitchen('gate', 'web', 'fast', code=1))


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
        self.assertEqual([f['rule'] for f in r['findings']], ['test-touch'])
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
            'features': 'ok', 'verification skill': 'warn'})

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
