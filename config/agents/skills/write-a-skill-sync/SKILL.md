---
name: write-a-skill-sync
description: Creates or migrates agent skills into a versioned project or system location, then verifies their runtime exposure. Use when adding, writing, or migrating a Pi skill and choosing between project-level (`./.agent/skills`) and system-level (`~/nixpkgs-config/config/agents/skills`) placement.
---

# Write a Skill and Sync It

## Choose scope first

Before drafting, ask `project` or `system`. Do not infer scope unless the user
explicitly names the destination.

- **Project:** `./.agent/skills/<name>/`
- **System:** `~/nixpkgs-config/config/agents/skills/<name>/`

## Gather requirements

Ask for the task or domain, concrete triggers and use cases, required reference
materials, and whether a deterministic helper script is needed. Inspect related
skills before duplicating their scope.

## Draft the skill

Use the scaffold when creating a new skill:

```bash
~/nixpkgs-config/config/agents/skills/write-a-skill-sync/scripts/new-skill.sh \
  --scope <project|system> --name <slug>
```

Keep the skill directory focused:

```text
<skill-name>/
├── SKILL.md           # required, concise instructions
├── REFERENCE.md       # optional detailed material
├── EXAMPLES.md        # optional examples
└── scripts/           # optional deterministic helpers
```

`SKILL.md` must have frontmatter with a lowercase hyphenated `name` and a
third-person `description` under 1024 characters. The description's first
sentence states the capability; its second says `Use when ...` with specific
triggers. It is the only text used to decide whether to load the skill.

Keep `SKILL.md` under 100 lines when practical. Move distinct or rarely needed
detail into a one-level-deep reference. Add scripts only for repeatable,
deterministic work or explicit error handling.

## Review and publish

Present the draft for user review: confirm covered use cases, unclear guidance,
and missing edge cases. Then verify:

- `SKILL.md` has a precise description and no time-sensitive instructions.
- Terminology is consistent and examples are concrete.
- Any referenced files exist and are only one level deep.
- Scripts are executable and have a deterministic interface.

For **system** scope, verify `home-manager/agents.nix` imports every directory
under `config/agents/skills` into `~/.agents/skills` and creates
`~/.agent/skills -> ~/.agents/skills`. Apply the configuration:

```bash
home-manager switch --flake ~/nixpkgs-config#darwin
```

Use the appropriate host profile when it is not `darwin`. Confirm the installed
skill is visible under `~/.agents/skills/<name>/SKILL.md` and through the
`~/.agent/skills` symlink.

For **project** scope, confirm the repository's agent discovers
`./.agent/skills/<name>/`; do not publish it to the system location unless the
user asks.
