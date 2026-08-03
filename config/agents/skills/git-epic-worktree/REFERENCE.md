# Git epic-worktree reference

## Naming

For repository `chenchess`, issue `127`, and title `Grounded Learning Plan`:

```text
directory:  ../chenchess-127-grounded-learning-plan
branch:     127-grounded-learning-plan
```

The title slug is lowercase ASCII, replaces non-alphanumeric runs with one
hyphen, and removes leading and trailing hyphens.

## What “copy the default branch” means

`git worktree add -b` creates an issue branch at the selected local base branch
commit and checks it out in a sibling directory:

```text
base commit
├── primary checkout and default branch
└── issue worktree and issue branch
```

Staged, unstaged, and untracked primary-checkout files are not copied. The
helper reports this when the primary checkout is dirty. Unlike a mutable
Jujutsu change, the Git base commit is immutable; later commits on either branch
do not alter the other worktree.

## Finish the issue branch

From the issue worktree:

```bash
git status --short
git diff
git diff --cached
git commit
```

Run the repository’s focused validation before integration. Ensure every
intended file is committed and the issue worktree is clean.

## PR while the default task is active

Resolve the remote and base branch, then fetch the remote base:

```bash
git fetch <remote> <base-branch>
fork_point="$(git merge-base <issue-branch> <base-branch>)"
git merge-base --is-ancestor "$fork_point" <remote>/<base-branch>
```

The ancestry check must succeed. If it fails, the issue branch includes local
base commits that are not present in the intended remote base. Either push the
default work under its own branch and create a stacked PR against that branch,
or wait. Do not target an older branch and silently include unrelated work.

After repository-specific gates:

```bash
git push -u <remote> <issue-branch>
gh pr create --base <remote-base-branch> --head <issue-branch>
```

Use explicit remote, base, and head values. Do not force-push unless the user
requests it and the repository permits it.

## Local merge after the default task is done

In the primary checkout, require the intended default branch and a clean
working tree:

```bash
git branch --show-current
git status --short
git log --oneline --decorate --graph \
  <default-branch> <issue-branch>
```

Commit the completed default task before integration. Then start a reviewable
merge without committing automatically:

```bash
git merge --no-commit --no-ff <issue-branch>
```

Resolve any conflicts in the primary checkout:

```bash
git status
git diff --name-only --diff-filter=U
git add <resolved-files>
git diff --check
```

Run focused validation against the combined tree. When no unmerged paths
remain, create the merge commit:

```bash
git commit
```

Apply the repository’s normal synchronization gates before pushing the default
branch. Keep the issue worktree and branch until the merge is accepted.
Worktree removal and branch deletion are separate, explicit cleanup actions.

## Start the agent session

The helper creates the worktree but does not launch an agent. Start a fresh
task from the worktree directory; do not repoint an active task rooted in the
primary checkout. For a terminal-based harness, choose the installed command:

```bash
cd <worktree-directory> && codex
cd <worktree-directory> && claude
cd <worktree-directory> && pi
cd <worktree-directory> && opencode
```

Give the new task the issue number and title, and ensure it reads the
worktree's repository instructions before editing.
