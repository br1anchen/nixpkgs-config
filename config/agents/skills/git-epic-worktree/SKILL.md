---
name: git-epic-worktree
description: Creates isolated Git worktrees for parallel large-issue or epic work, names sibling directories and branches predictably, and integrates finished work through a PR or local merge. Use with Codex, Claude Code, Pi, OpenCode, or another coding harness when another issue must proceed while the primary Git checkout is busy, when starting a parallel epic/spec task, or when merging a completed issue worktree back.
---

# Git Epic Worktree

## Required input

Obtain:

- the numeric issue number;
- a short issue title;
- the local base branch, defaulting to the current branch of the primary
  checkout;

Run creation from the primary checkout, not another linked worktree. The base
branch commit is copied; uncommitted and staged files in the primary checkout
are intentionally excluded. If HEAD is detached or the base branch is
ambiguous, stop and ask.

## Create the worktree

Use the bundled helper:

```bash
<skill-dir>/scripts/create-worktree.sh \
  --issue 127 \
  --title "grounded learning plan"
```

Pass `--base <branch>` to override the current branch. The helper creates:

- sibling directory `<repo>-<issue>-<slug>`;
- local branch `<issue>-<slug>`;
- a linked Git worktree checked out on that branch.

It never overwrites a directory or reuses a local or remote branch. Start a
fresh task in the new directory using the active coding harness, and keep the
original task rooted in the primary checkout.

## Work in parallel

- Give every coding-agent task exactly one checkout or worktree directory.
- Commit cohesive slices on the issue branch.
- Do not let two worktrees check out or mutate the same branch.
- Assign separate ports and local service state when both tasks run services.
- Follow repository-local `AGENTS.md`, validation, commit, and push
  instructions.

## Integrate completed work

First inspect both checkouts and identify the default branch, issue branch,
remote, fork point, unpublished commits, and uncommitted files. Ask whether the
default task is done if that cannot be established safely.

### Default task is still active

Use the PR workflow in [REFERENCE.md](REFERENCE.md). Push the issue branch and
open a PR against a remote branch containing its actual fork point. Never open
a PR that accidentally includes unpublished default-task commits.

### Default task is done

Use the local merge workflow in [REFERENCE.md](REFERENCE.md). In the primary
checkout, require a clean default branch, merge the issue branch with
`--no-commit --no-ff`, resolve conflicts locally, validate, then commit the
merge. Do not remove the worktree or branch during conflict resolution.

## Safety

Never push, create a PR, merge, abort a merge, remove a worktree, delete a
branch, or move the default branch without explicit user intent. Cleanup is a
separate action after integration is accepted.
