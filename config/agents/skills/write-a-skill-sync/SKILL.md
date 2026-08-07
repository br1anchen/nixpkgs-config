---
name: write-a-skill-sync
description: Creates or migrates agent skills into a versioned location and verifies how they are exposed. Use when adding a new Pi skill and choosing between project-level (`./.agent/skills`) and system-level (`~/nixpkgs-config/config/agents/skills`) placement.
---

# Write a Skill and Sync It

## Choose scope first

Before drafting, ask `project` or `system`.

- **Project:** `./.agent/skills/<name>/`
- **System:** `~/nixpkgs-config/config/agents/skills/<name>/`

## Gather requirements

Ask for:
- task/domain
- concrete use cases
- reference materials
- whether a deterministic helper script is needed

Inspect related skills before creating a duplicate.

## Draft the skill

Use this structure:

```md
name: skill-name
description: "Clear one-line capability. Use when ..."
```

```text
<skill-name>/
├── SKILL.md           # required
├── REFERENCE.md       # optional
├── EXAMPLES.md        # optional
└── scripts/           # optional deterministic helpers
```

### SKILL.md requirements
- `name` must be lowercase hyphenated
- `description` first sentence states capability; second sentence says `Use when ...`
- `description` <= 1024 chars
- Prefer concise, one-level split docs when needed
- Add scripts only for deterministic, repeated operations

## Deterministic scaffold

Use:

```bash
~/nixpkgs-config/config/agents/skills/write-a-skill-sync/scripts/new-skill.sh \
  --scope <project|system> --name <slug>
```

## Scope behavior

### Project
- write to `./.agent/skills/<name>/`
- keep local to repo unless asked to promote

### System
- write to `~/nixpkgs-config/config/agents/skills/<name>/`
- ensure system wiring exports all `config/agents/skills/*` into `~/.agents/skills`
- ensure symlinks:
  - `~/.agent/skills -> ~/.agents/skills`
  - `~/.claude/skills -> ~/.agents/skills`
- then run:
  - `home-manager switch --flake ~/nixpkgs-config#darwin` (or host profile)

## Review and publish checklist

- [ ] Scope confirmed explicitly (`project` or `system`).
- [ ] Skill written to selected path.
- [ ] `description` includes clear capability + `Use when ...` and is <= 1024 chars.
- [ ] `home-manager/agents.nix` wiring is present.
- [ ] For system scope, both symlinks are in place (`~/.agent/skills`, `~/.claude/skills`).