#!/usr/bin/env python3
"""Run the repo's Python test suites in parallel, one process per test.

The suites drive real scripts through fakes and wait on real timers, so one
test at a time leaves the machine idle: the serial run took about ten
minutes. Every test already works in its own temporary directory, with its
own fake agents, state and Herdr socket, so the tests run side by side.

    python3 tests/run.py                      # every suite, one worker per core
    python3 tests/run.py -j 4 test_pstack_pair
    python3 tests/run.py -k rotate            # tests whose id contains "rotate"

Prints each failure's output, the slowest tests, and a summary; exits 1 when
any test fails.
"""

import argparse
import os
import subprocess
import sys
import time
import unittest
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path

here = Path(__file__).resolve().parent
SUITES = ['test_pstack_kitchen', 'test_pstack_pair', 'test_pstack_sync']


def test_ids(suites):
    sys.path.insert(0, str(here))
    ids = []

    def walk(suite):
        for t in suite:
            if isinstance(t, unittest.TestSuite):
                walk(t)
            else:
                ids.append(t.id())

    for name in suites:
        walk(unittest.defaultTestLoader.loadTestsFromName(name))
    return ids


def run_one(test_id):
    start = time.monotonic()
    r = subprocess.run([sys.executable, '-m', 'unittest', '-q', test_id], cwd=here,
                       capture_output=True, text=True, check=False)
    return test_id, r.returncode, time.monotonic() - start, r.stdout + r.stderr


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('suites', nargs='*', default=SUITES)
    ap.add_argument('-j', '--jobs', type=int, default=os.cpu_count() or 4)
    ap.add_argument('-k', '--keyword', default='')
    ap.add_argument('--slowest', type=int, default=8)
    args = ap.parse_args()
    ids = [i for i in test_ids(args.suites) if args.keyword in i]
    start = time.monotonic()
    failed, times = [], []
    with ThreadPoolExecutor(max_workers=args.jobs) as pool:
        for fut in as_completed([pool.submit(run_one, i) for i in ids]):
            test_id, code, secs, out = fut.result()
            times.append((secs, test_id))
            if code != 0:
                failed.append(test_id)
                print(f'FAIL {test_id} ({secs:.1f}s)\n{out}', flush=True)
    wall = time.monotonic() - start
    print('slowest:')
    for secs, test_id in sorted(times, reverse=True)[:args.slowest]:
        print(f'  {secs:6.1f}s  {test_id}')
    print(f'{len(ids)} tests, {len(failed)} failed, {wall:.0f}s wall with {args.jobs} jobs')
    for test_id in failed:
        print(f'failed: {test_id}')
    return 1 if failed else 0


if __name__ == '__main__':
    sys.exit(main())
