# Jujutsu epic-workspace reference

## Naming

For repository `chenchess`, issue `127`, and title `Grounded Learning Plan`:

```text
directory:  ../chenchess-127-grounded-learning-plan
workspace:  127-grounded-learning-plan
bookmark:   127-grounded-learning-plan
```

The title slug is lowercase ASCII, replaces non-alphanumeric runs with one
hyphen, and removes leading and trailing hyphens.

## What “copy the default bookmark” means

The new workspace starts with an empty mutable change whose parent is the
selected local bookmark:

```text
selected bookmark
├── default workspace changes
└── new issue workspace and issue bookmark
```

Only content already present at the selected bookmark is copied. Files changed
only in an unbookmarked default working copy are excluded. If the local
bookmark itself points at the active default change, the helper stops. A
parallel child of that mutable change would automatically rebase whenever the
default task amended its ancestor. At a safe boundary, describe the default
slice and run `jj new`; the bookmark then remains on the stable parent.

Before creating a remote PR, inspect that dependency explicitly:

```bash
jj log -r '<base-bookmark> | <issue-bookmark> | <base-bookmark>@<remote>'
```

## Finish the issue tip

From the issue workspace:

```bash
jj status
jj diff
jj describe -m "<final description> (#<issue>)"
jj new
```

Run the repository’s focused validation before integration. The issue bookmark
should remain on the described completed change, while `@` becomes a new empty
child.

## PR while the default task is active

1. Resolve the intended remote and remote base bookmark.
2. Verify the remote base contains the revision from which the issue workspace
   was created. If it does not, either publish the default task under its own
   remote bookmark and create a stacked PR against it, or wait. Do not target an
   older branch and silently include unrelated default-task changes.
3. Run repository-specific release or checked-push gates.
4. Push only the issue bookmark.
5. Create the PR with explicit base and head.

Generic commands, adapted to repository instructions:

```bash
jj git push --remote <remote> --bookmark <issue-bookmark>
gh pr create --base <remote-base-bookmark> --head <issue-bookmark>
```

Use a repository-provided checked-push command instead of direct push when one
exists.

## Local merge after the default task is done

In the default workspace, first ensure its current change is intentional and
described. Record both tips, then create a merge change:

```bash
jj status
jj log -r '@ | <default-bookmark> | <issue-bookmark>'
jj new @ <issue-bookmark>
jj describe -m "merge: integrate #<issue> <title>"
```

`jj new` may materialize conflicts. Resolve them in the default workspace:

```bash
jj status
jj resolve
jj diff
```

Edit conflicted files deliberately, run focused validation, and confirm that
`jj status` reports no unresolved conflicts. Only then advance the default
bookmark:

```bash
jj bookmark set <default-bookmark> -r @
```

Apply the repository’s normal synchronization gates before any push. Keep the
issue workspace and bookmark until the integration is accepted; cleanup is a
separate, explicit action.

## Start the agent session

The helper creates the workspace but does not launch an agent. Start a fresh
task from the workspace directory; do not repoint an active task rooted in the
default workspace. For a terminal-based harness, choose the installed command:

```bash
cd <workspace-directory> && codex
cd <workspace-directory> && claude
cd <workspace-directory> && pi
cd <workspace-directory> && opencode
```

Give the new task the issue number and title, and ensure it reads the
workspace's repository instructions before editing.
