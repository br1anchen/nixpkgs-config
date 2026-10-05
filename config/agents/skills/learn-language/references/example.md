# Worked example: Python filesystem semantics from repo code

This example illustrates the method, not a fixed first lesson. Use it only when
Python filesystem behavior serves the learner's mission. A JavaScript/TypeScript
programmer is the hypothetical learner; that is not an assumption about the user.

## Real context

In this repo, `scripts/pstack-sync.py`, function `sync`, installs skill links and
moves an existing entry into a backup before replacing it. Read its live source
and revision before using this example. The relevant excerpt is:

```python
if target.exists() or target.is_symlink():
    if backup is None:
        backup_root = home / '.local/state/pstack/backups'
        backup_root.mkdir(parents=True, exist_ok=True)
        backup = Path(tempfile.mkdtemp(prefix='install-', dir=backup_root))
    saved = backup / root / skill.name
    saved.parent.mkdir(parents=True, exist_ok=True)
    target.rename(saved)
```

`target` is a `pathlib.Path` for the skill entry being replaced, `home` is the
configured home directory, and `root` and `skill.name` preserve its original
location in the backup. Explain those roles before asking a question.

## Problem and initial rule

Why test two conditions instead of just existence? Present the tempting rule
"A filesystem entry that needs preserving must satisfy `exists()`." If the
learner knows Node's filesystem APIs, this familiar counterpart gives the
same predicate, with `target` a string path for the selected case:

```javascript
import { existsSync, lstatSync } from 'node:fs';

const keep = existsSync(target) ||
    (lstatSync(target, { throwIfNoEntry: false })?.isSymbolicLink() ?? false);
```

Do not hide the extra option and optional chaining. A tempting translation
without them is `existsSync(target) || lstatSync(target).isSymbolicLink()`.
On a missing entry it throws `ENOENT`, while Python's two predicates return
false in the tested environment. This is a useful boundary for the analogy,
not a claim that Python and Node have identical filesystem error handling.
These results were verified with Node 26.8.1. Consult the version-appropriate
[Node filesystem documentation](https://nodejs.org/api/fs.html#fslstatsyncpath-options)
and re-run when using another environment.

## First prediction

Show a link named `broken` whose destination is absent. Ask:

For that link, what does `target.exists(), target.is_symlink()` produce?

- A. `True, True`
- B. `False, True`
- C. `True, False`
- D. `False, False`

Send only the context and question to the learner. This reference contains the
answer for the teacher; do not paste its later sections before submission.

## Experiment controls and evidence

Provide buttons or chat choices for **directory**, **live link**, **broken link**,
and **missing entry**. The agent executes the chosen case. These cases can be
recorded with this isolated experiment:

```python
from pathlib import Path
from tempfile import TemporaryDirectory

with TemporaryDirectory() as directory:
    base = Path(directory)
    (base / 'real').mkdir()
    (base / 'live').symlink_to(base / 'real', target_is_directory=True)
    (base / 'broken').symlink_to(base / 'absent', target_is_directory=True)
    for name in ('real', 'live', 'broken', 'missing'):
        target = base / name
        print(name, target.exists(), target.is_symlink(),
              target.exists() or target.is_symlink())
```

Observed with Python 3.12.10 on Linux when authoring this skill:

```text
real True False True
live True True True
broken False True True
missing False False False
```

Re-run in the learner's environment before claiming a fresh observation.
Use the version-appropriate [pathlib documentation](https://docs.python.org/3/library/pathlib.html)
to establish the API contract. Symlink creation or diagnostic details can
differ by platform and permissions.

## Counterexample and revised rule

The broken link defeats the initial existence-only rule. Ask which predicate
preserves both reachable entries and dangling links:

- A. `target.exists() or target.is_symlink()`
- B. `target.exists() and target.is_symlink()`
- C. `target.exists() and not target.is_symlink()`
- D. `not target.exists() and target.is_symlink()`

After submission, explain the chosen result using the directory and broken-link
cases. Vary correct-option positions across future questions.

The revised rule distinguishes the destination's existence from the presence
of a link. It explains why the repo uses `or`; it does not justify every future
filesystem operation or establish race-free behavior.

## Transfer back to the repo

Now ask what the backup predicate will do for an ordinary file, a live link,
or a missing entry, without displaying the results table again. For a tooling
follow-up, let the learner choose a proposed patch that removes `is_symlink()`
and predict its effect on preserving old broken skill links. Keep that patch
inside the experiment, not the installed skill directories.

Record the first prediction, the chosen counterexample/revision, hints, and
independent transfer result only after the learner actually answers. Revisit
with a new link/destination case in a later session. This establishes a Python
standard-library concept through an authentic repository problem and a small
experiment; it is not evidence of general Python fluency.
