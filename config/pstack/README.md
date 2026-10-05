# Pstack across coding agents

This repo owns 60 pstack skills in `skills/`, their reference files, helper
scripts, and MIT license. Start with the
[scenario tutorial](skills/ask-poteto/references/scenarios.md), or ask
[ask-poteto](skills/ask-poteto/SKILL.md) which route fits your task.

| Agent | Ask for guidance | Execute a task |
| --- | --- | --- |
| Claude Code | `/ask-poteto ...` | `/pstack ...` or `/poteto-mode ...` |
| Codex | `$ask-poteto ...` | `$pstack ...` or `$poteto-mode ...` |
| Pi | `/skill:ask-poteto ...` | `/skill:pstack ...` |
| Grok Build | `/ask-poteto ...` | `/pstack ...` |
| Other agent | Read `ask-poteto/SKILL.md` | Read `pstack/SKILL.md` |

`poteto-mode` is upstream's execution router. `ask-poteto` is our advice-only
addition, modeled on the role of the installed `ask-matt` skill. It chooses a
route, explains expected evidence, and supplies a prompt without launching work.

## What was installed before

The 2026-09-10 audit found 48 pstack skill directories under `~/.agents/skills`,
with `~/.claude/skills` and `~/.agent/skills` pointing at that shared directory.
Claude's installed-plugin and marketplace registries contained no pstack entry.
There was no top-level `pstack` skill, and no pstack skill lockfile was found.
These were unmanaged local skill copies, not a reproducible Claude marketplace
installation. The exact original installation command could not be established.
Pi and Grok had individual links for other skills, but none for pstack.

[sources.json](sources.json) records each imported skill, upstream revisions,
and hashes of the previously installed SKILL.md files. The base is Cursor pstack
0.15.9 at `e43c7ee26e0038c6c1fa8380dd34ce86ff94cb2a`. The local `pstack-tdd`,
`pstack-teach`, `pstack-pair`, `pstack-pair-guided`, `pstack-trio`,
`pstack-kitchen`, and `pstack-kitchen-setup` customizations are retained, including Devin bypass defaults, task-boundary
session rotation, and durable handoffs. `pstack-pair` runs a master and sidekick agent
pair over Herdr; `pstack-pair-guided` is its experimental variant with
scope-scaled human approval and a sidekick ask channel; `pstack-trio` adds a
consultant of a different agent kind that joins every plan round, answers
design and finding consults, and prototypes in a throwaway worktree.
`pstack-kitchen` moves the master's attention to exceptions: the repo's
`.agents/kitchen.toml` (written and proved by `pstack-kitchen-setup`) names the
gate commands that prove each part of it and what makes a change risky, every
step passes those gates, a fresh verifier pane proves each unit, Judge of Owls
reviews it, and a consultant joins only escalated units. Its
`scripts/kitchen.py` reads the kitchen as data (`tests/test_pstack_kitchen.py`).
See their SKILL.md files. The four share one script core,
`pstack-pair/scripts/pair-core.sh`; each skill's `scripts/pair.sh` sets its
variant, adds its own commands, and sources it (the kitchen's is `scripts/kitchen.sh`). The consultant's commands
(spawn, plan rounds, consults, multi-role stop) live in
`pstack-trio/scripts/consultant-core.sh`, sourced after the core. `tests/test_pstack_pair.py`
drives all three against a fake `herdr` and compares golden transcripts. Other workflows use the current
upstream revision plus the runtime adaptation. The old installation is backed
up on sync, including any local edits outside SKILL.md.

The [michael-denyer port](https://github.com/michael-denyer/pstack-claude) informed
the shared-skill boundary and adapter approach. Its Claude plugin hooks and
Claude-specific defaults are not installed. Cursor's tutorial and marketplace
artwork are not runtime dependencies.

## Sync and update

Home Manager imports `home-manager/pstack.nix`, which runs the same sync script
used below against a Nix-store snapshot. It exposes individual skill links in
`~/.agents/skills`, `~/.claude/skills`, `~/.pi/agent/skills`, and `~/.grok/skills`.
Existing directory-wide aliases are respected. Codex and generic Agent Skills
consumers use the shared `.agents` path. Pi and Grok also support that shared
path; their native links support installations that use only native discovery.

For live editing, sync directly from the checkout:

```bash
python3 scripts/pstack-sync.py          # status; exit 1 means drift
python3 scripts/pstack-sync.py --apply  # backup conflicts, then install links
python3 scripts/pstack-sync.py          # should show no changes
```

Replaced directories, files, and links go under
`~/.local/state/pstack/backups/install-*/`, preserving their original relative
paths. Unrelated skills stay in place. A second sync is a no-op. To restore an
old skill, remove only its generated link and move its saved entry back. For
links pointing at obsolete Nix generations, prefer rebuilding that generation;
old store paths can be garbage-collected.

Edit the repo files, not Nix-store links. A subsequent Home Manager activation
switches checkout links back to the generation's snapshot. Reload skills or
start a fresh agent session after changing the installed set. This does not
install an auto-start hook or enable background services.

To update upstream, compare against the pinned revision in `sources.json`,
merge changes into this vendored tree, and review the runtime adapter and local
customizations. Update the skill inventory for additions/removals, then run the
checks below. Sync does not fetch upstream or delete removed skill names; remove
obsolete generated links explicitly after reviewing their local contents.

## Runtime translation

Every skill loads [runtime.md](skills/pstack/references/runtime.md), including
when invoked directly. It maps delegation, models, questions, planning, skills,
UI/CLI control, transcripts, persistent state, and automation to the active host.
The actual host tool schema is authoritative. Multi-model review and cloud
execution are not guaranteed merely because skills are discovered.

The 0.15.9 update adds `correct`, `benchmark-checklist`, and
`principle-explain-the-number`, plus agent-resistant design checks, exact-SHA
measurement briefs, fresh workers by default, hourly autopilot audits, and
revised PR writing guidance. Cursor-only docs, artwork, and plugin registration
are excluded from the portable installation.

`setup-pstack` writes per-runtime model and reasoning-budget preferences under
`~/.config/pstack/models/`. With no preferences, roles inherit the parent model.
Those account-specific preferences remain host-local. No Cursor model slug is
assumed available. The adapter explains single-model and sequential fallbacks.

Benny's operational skills and complete reference pack are included, but actual
event scheduling requires a configured runner. `make-bot-ui` uses a documented
webhook service instead of Cursor-only routine and secret-card APIs.

Bundled Bun helpers run through `pstack/scripts/run-helper.sh`, which copies them
to a content-addressed writable cache. They require Python 3 and Bun. Other
helpers may require Git, gh, jq, or project-specific tools. Dependency downloads
still follow the host's permission policy. The worktree audit uses an explicitly
scoped `PSTACK_TRANSCRIPTS_DIR`, handles paths with spaces on Linux/macOS, and
never treats absent transcript evidence as permission to delete work.

## Validation

```bash
PYTHONDONTWRITEBYTECODE=1 python3 scripts/check-pstack.py
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests -p 'test_pstack_*.py'
nix flake check --no-write-lock-file 'path:.'
home-manager build --flake 'path:.#omarchy' --no-out-link
home-manager build --flake 'path:.#darwin' --no-out-link
```

`path:.` includes new files before they are tracked by Git. The Omarchy profile
build and flake check passed. The Darwin profile evaluated, but its build failed
on this Linux machine because it requires an `aarch64-darwin` builder. No full
Home Manager switch was performed. End-to-end model runs on all four agents and
live webhook/scheduler execution have not been tested.
