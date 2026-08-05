---
name: write-a-skill-sync
description: It creates or migrates skills into a versioned location and confirms how they should be exposed. Use when adding a new Pi skill and deciding between project-level (`./.agent/skills`) and system-level (`~/nixpkgs-config/config/agents/skills`) placement.
---

# write-a-skill Sync

## First question (required)

Always ask before drafting:

- `project` or `system`

## Project-level flow (`project`)

- Path: `./.agent/skills/<name>/`
- Keep files in repo scope:
  - required `SKILL.md`
  - optional `REFERENCE.md`, `EXAMPLES.md`, `scripts/`
- Ensure `SKILL.md` follows `write-a-skill` rules:
  - clear `description`
  - include `Use when ...`
  - under 1024 chars

## System-level flow (`system`)

- Path: `~/nixpkgs-config/config/agents/skills/<name>/`
- Keep files as above.
- Ensure `~/nixpkgs-config/home-manager/agents.nix` exports all `config/agents/skills/*` into `~/.agents/skills` and sets up `~/.agent/skills` symlink via home-manager activation.
- Then run:
  - `home-manager switch --flake ~/nixpkgs-config#darwin` (or your host profile)

## Deterministic scaffold

Use the bundled helper so the workflow is consistent:

```bash
/Users/br1anchen/nixpkgs-config/config/agents/skills/write-a-skill-sync/scripts/new-skill.sh --scope <project|system> --name <slug>
```

It creates/initializes:
- target directory
- starter `SKILL.md`
- for system scope: validates key `home-manager/agents.nix` patterns and ensures `~/.agent/skills -> ~/.agents/skills`

## End-of-turn checklist

- [ ] Scope confirmed explicitly (`project` or `system`).
- [ ] Skill written to selected path.
- [ ] `description` includes clear capability + `Use when ...` and is <= 1024 chars.
- [ ] System scope: `home-manager/agents.nix` path wiring is present.
- [ ] System scope: `~/.agent/skills` symlink is in place.