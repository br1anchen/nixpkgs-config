---
name: jj-epic-workspace
description: Creates isolated Jujutsu workspaces for parallel large-issue or epic work, names sibling directories and bookmarks predictably, and integrates finished work through a PR or local merge. Use with Codex, Claude Code, Pi, OpenCode, or another coding harness when another issue must proceed while the default jj workspace is busy, when starting a parallel epic/spec task, or when merging a completed issue workspace back.
---

# Jujutsu Epic Workspace

## Required input

Obtain:

- the numeric issue number;
- a short issue title;
- the default workspace bookmark to copy, inferring it only when exactly one
  local bookmark is the nearest bookmarked ancestor of the default working copy;

Run creation from the `default` jj workspace. The bookmark revision is the
base; unbookmarked working-copy content is intentionally excluded. If the
bookmark choice is ambiguous, stop and ask. The base bookmark must not point at
the active default working-copy change: finish that slice and run `jj new`, or
choose another stable bookmark, before branching parallel work.

## Create the workspace

Use the bundled helper:

```bash
<skill-dir>/scripts/create-workspace.sh \
  --issue 127 \
  --title "grounded learning plan"
```

Pass `--base <bookmark>` when inference is ambiguous. The helper creates:

- sibling directory `<repo>-<issue>-<slug>`;
- workspace name `<issue>-<slug>`;
- local bookmark `<issue>-<slug>`;
- an initial `wip: <title> (#<issue>)` change description.

It never overwrites a directory or reuses a local or remote bookmark. Start a
fresh task in the new directory using the active coding harness, and keep the
original task rooted in the default workspace.

## Work in parallel

- Give every coding-agent task exactly one workspace directory.
- Treat bookmarks and the jj operation log as repository-global state.
- Do not run mutating jj commands literally simultaneously in two workspaces.
- Never branch parallel work from a mutable default change; jj would
  automatically rebase its descendants whenever that ancestor changes.
- Keep changes cohesive; finish a slice with a final description and `jj new`
  so the issue bookmark remains on the completed tip.
- Follow repository-local `AGENTS.md`, validation, and push instructions.

## Integrate completed work

First inspect both workspaces and identify the default bookmark, issue
bookmark, remote, common base, and unpublished changes. Ask whether the default
task is done if that cannot be established safely.

### Default task is still active

Use the PR workflow in [REFERENCE.md](REFERENCE.md). Push the issue bookmark and
open a PR against a remote bookmark containing its actual base. Never open a PR
that accidentally includes unpublished default-workspace changes.

### Default task is done

Use the local merge workflow in [REFERENCE.md](REFERENCE.md). In the default
workspace, create a two-parent jj change from the default tip and issue
bookmark, resolve conflicts locally, validate, then advance the default
bookmark. Do not rewrite or abandon the issue workspace during conflict
resolution.

## Safety

Never move `main`, push, create a PR, delete a workspace, or forget a workspace
without explicit user intent for that action. Preserve both changes when
integration is uncertain; jj recovery is available through `jj op log`.
