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
import subprocess
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


if __name__ == '__main__':
    unittest.main()
