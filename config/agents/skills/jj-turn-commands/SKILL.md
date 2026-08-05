---
name: jj-turn-commands
description: This skill makes jj (Jujutsu) the default VCS workflow for the session and requires transparent command reporting. Use when a task needs jj operations in a repo with .jj, the user says "use jj", or they explicitly ask for git-like actions in a jj-managed repository.
---

# JJ (Jujutsu) with Turn-by-Turn Command Reporting

## Quick start

Use jj commands exactly when jj is in use (presence of `.jj/`):

- Inspect state: `jj log`, `jj diff`
- Start next chunk: `jj new`
- Describe/update message: `jj describe -m "..."`
- Undo safely: `jj undo`
- Push workflow: `jj bookmark create <bookmark> -r @`, then `jj git push`

## Mandatory Turn Reporting

After **every agent turn** that performs any jj action, append a short report block:

- `Used command: <exact jj command(s)>`
- `Why: <one sentence tied to user goal and state>`

If multiple jj commands were run, list them in order.

Example:

- Used command: `jj new`; `jj describe -m "feat: add review command logging"`
- Why: started a new change and recorded a clear checkpoint before implementing the requested script.

## Core rules (jj vs git)

- Do not use `git add`, `git commit`, `git stash`, `git checkout` in jj mode.
- Workdir changes are automatic in current change; prefer:
  - `jj log`, `jj diff`, `jj new`, `jj describe`, `jj edit`, `jj split`, `jj abandon`, `jj rebase`.
- Use `jj undo` to recover from mistakes.

## Key operations

```bash
jj log
jj diff
jj new <change>
jj describe -m "message"
jj edit <change>
jj split
jj abandon <change>
jj bookmark create <name> -r @
jj git push --bookmark <name>
jj git push --deleted
jj git fetch
jj undo
```

## When to choose this skill

Load this skill when:
- you need to run version-control operations and repo is jj-managed, or
- user explicitly asks for jj usage, or
- an ambiguous VCS request could be git-like in a jj project.

Keep the command report short and explicit so the human can track exactly what was executed and keep fresh command knowledge across turns.