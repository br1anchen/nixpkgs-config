# kitchen.toml

A repo's kitchen rules, committed at `.agents/kitchen.toml`. They say which of
the repo's own commands prove which part of it, what makes a change risky, and
which lines must never land. `scripts/kitchen.py` reads them as data; no agent
invents a verification recipe or judges risk from prose. A unit is checked
against the kitchen at its own commit (`kitchen.py --at <sha>`), so changing
the rules never changes a verdict already given.

A worked example: [kitchen-example.toml](kitchen-example.toml).

## Keys

Unknown keys are errors, so a typo fails `kitchen.py validate` instead of
silently doing nothing.

| Key | Default | Meaning |
| --- | --- | --- |
| `version` | required | `1` |
| `[profile.<name>]` | at least one | an area of the repo and its proof; name is `[a-z][a-z0-9-]*` |
| `.paths` | required | globs the profile covers; a file may sit in several profiles |
| `.fast` | `[]` | commands `kitchen.py gate <p> fast` runs at every step: format, lint, typecheck, targeted tests; minutes, not tens of minutes |
| `.behavioral` | `[]` | commands the verifier runs at the unit's commit: e2e, journeys, the app driven for real |
| `.landing` | `[]` | the full battery, run once, in the landing unit |
| `.features` | `[]` | feature-map files of the repo's verification skill that the verifier reads for this profile |
| `.tests` | `[]` | globs of this profile's test files |
| `.require_tests` | `false` | a change to the profile's files needs a change to a `tests` file (`kitchen.py policy` reports `test-touch`) |
| `.verify` | `"batch"` | routine verification: `gates` (deterministic gates only, no verifier), `batch` (one verifier per landing stack), `unit` (one per unit) |
| `.sample` | `0.1` | share of clean routine units the master audits in full |
| `.heavy` | `false` | its gates take one of `resources.max_parallel_heavy` machine-wide slots, so a verifier's build never races the sidekick's |
| `.wrap` | `[run].wrap` | this profile's wrap; `""` runs it unwrapped |
| `[escalate]` | | what turns a routine change into an escalated one: per-unit verification by the master's kind, full sampling, the escalated review settings, and the consultant |
| `.paths` | `[]` | globs whose change is architectural: contracts, schemas, migrations, auth |
| `.manifests` | `[]` | dependency manifests; changing one adds or moves a dependency |
| `.max_profiles` | none | escalate when a change touches more profiles than this (a cross-boundary change) |
| `.max_diff_lines` | `600` | escalate a larger diff |
| `.unmapped` | `true` | escalate a change to files no profile or `coverage.ignore` covers, since no gate proves them |
| `[[policy.forbid]]` | | a rule for added lines |
| `.id` | required | unique; a line opts out with `kitchen-allow: <id>` and the reason beside it |
| `.pattern` | required | Python regular expression, searched in each added line |
| `.message` | required | what to do instead; the sidekick reads only this |
| `.paths` | `["**"]` | globs the rule applies to |
| `.source` | `""` | the rule's origin, such as `AGENTS.md#rust` |
| `[review]` | | |
| `.engine` | `"none"` | `joo` runs Judge of Owls on every unit; `none` leaves review to the master's own read |
| `.self` | `[]` | skills the sidekick runs on its diff before reporting done |
| `.standards` | `[]` | doc sections (`path#anchor`) the review holds the diff to |
| `.max_batch_diff` | `800` | a batch over this many diff lines verifies per unit instead |
| `.routine` / `.escalated` / `.landing` | `standard`/4, `thorough`/8, `quick`/4 | `style` (quick, standard, thorough), `budget` (joo execution budget), `second_reviewer`, `walkthrough` (default only for landing) |
| `[verify]` | | |
| `.routine_kind` | `"sidekick"` | who verifies a routine unit: a fresh pane of the sidekick's kind or the master's |
| `.escalated_kind` | `"master"` | the same for an escalated unit |
| `[landing].mode` | `"commit"` | how far the kitchen goes: `commit`, `branch` (push), `stack` (a linear stack of PRs), `pr`. It never merges |
| `[coverage].ignore` | `[]` | globs `doctor` and `classify` treat as covered without a gate |
| `[resources].max_parallel_heavy` | `1` | heavy gates running at once on this machine |
| `[run].wrap` | `""` | a prefix the gates run inside, such as `nix develop --impure --command`, entered once per gate |

## Globs

Paths are repo-relative. `**` crosses directories; `*` and `?` stay inside
one. A pattern never matches a basename alone: `*.md` is top-level only,
`**/*.md` is everywhere.

## Commands

Each command runs with `bash -c` from the repo root; its output goes to a log
under `${XDG_STATE_HOME:-~/.local/state}/pstack/kitchen/repos/<repo>/logs/`,
and a failure prints the log's last 20 lines. A gate stops at its first
failure. Every command sees `PSTACK_KITCHEN_ROLE` (`sidekick` or `verifier`):
the verifier runs at the same time as the sidekick, so a repo's scripts that
start servers, emulators, or databases should pick their ports and data from
it. State (logs, the baseline, the ledger) is kept per repository, shared by
its worktrees. With a wrap, `kitchen.py` re-runs itself inside it once per gate,
so a shell that takes seconds to enter costs that once, not per command, and
`doctor` checks each program inside the wrap it runs in. Use the repo's own entry points
(package scripts, `just`, `make`, wrappers the AGENTS file requires) so the
kitchen never drifts from how humans run the same checks.

## kitchen.py

```bash
kitchen.py validate                                   # parse and check
kitchen.py classify --base <sha> [--head <sha>]       # a unit's commits
kitchen.py classify --working-tree                    # uncommitted work
kitchen.py classify --paths 'apps/web/**' src/x.ts    # a brief's Scope, before work starts
kitchen.py gate <profile> fast|behavioral|landing     # exit 2 on failure; --keep-going, --only N
kitchen.py policy --base <sha> [--head <sha>]         # forbid rules and test-touch; exit 2 on findings
kitchen.py history [--last 20]                        # how each recent commit classifies, and its policy findings
kitchen.py doctor [--run]                             # coverage, commands, features; --run records a baseline
```

`--json` gives each result as data, `--at <rev>` reads the kitchen (and, for
`--paths`, the file list) at a revision, and `--repo` points at another
checkout. `classify` prints the risk class with every escalation reason, the
touched profiles, files no profile covers, the verification mode and kind, the
sample rate, the review settings, and the feature files the verifier needs.
