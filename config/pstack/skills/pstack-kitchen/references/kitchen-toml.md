# kitchen.toml

A repo's kitchen rules, committed at `.agents/kitchen.toml`, or kept on the
host when the repo's team has not agreed to commit them (see Where it lives). They say which of
the repo's own commands prove which part of it, what makes a change risky, and
which lines must never land. `scripts/kitchen.py` reads them as data; no agent
invents a verification recipe or judges risk from prose. A unit is checked
against the kitchen at its own commit (`kitchen.py --at <sha>`), so changing
the rules never changes a verdict already given.

A worked example: [kitchen-example.toml](kitchen-example.toml).

## Where it lives

`kitchen.py` takes the first kitchen it finds:

1. `--config <path>`: relative to the repo, or absolute.
2. The repo's `.agents/kitchen.toml`, at `--at <rev>` when given, else the
   working copy.
3. A host kitchen, for a repo whose team has not agreed to commit one: the
   `file` of the first `[[kitchen]]` entry in the host roster whose `match`
   glob covers the checkout or its main checkout, else
   `~/.config/pstack/kitchens/<host>__<owner>__<repo>.toml`, named from the
   `origin` remote. Without an origin, the name is the main checkout's
   basename and a hash of its path.

```toml
# ~/.config/pstack/kitchen.toml
[[kitchen]]
match = "~/src/<repo>/**"      # the checkout, or a bare repo with its worktrees
file = "<repo>.toml"          # relative paths resolve against ~/.config/pstack/kitchens/
```

Every clone, worktree, and verifier scratch of a repo resolves to the same
host file. `kitchen.py where` prints the kitchen in use and the host path;
`kitchen.py where --host` prints only the host path, whether it exists or not.
`validate` and `doctor` name the source. A committed kitchen shadows the host
one, and an uncommitted `.agents/kitchen.toml` fails `doctor`: this checkout
reads it, but verify and the verifier's scratch read commits and never see it.

A host kitchen has no history, so the rule that a unit is checked against
the kitchen at its own commit holds through a snapshot instead: when
`kitchen.sh` classifies a brief, it copies the host file into the run store
(`kitchens/<hash>.toml`, `kitchen.py snapshot <dir>`) and writes `kitchen:
<copy>` into the brief's header. That brief's steps, its verifier's gates,
and its verdict all read the copy, so editing the host file changes the
next brief, not one already dispatched. A landing verify takes a fresh copy.

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
| `.heavy` | `false` | `true`, or a list of stages from `fast`, `behavioral`, `landing`: those stages' gates take one of `resources.max_parallel_heavy` machine-wide slots, so a verifier's build never races the sidekick's. `true` means all three. A 30-second fast gate should not queue behind a verifier's behavioral build, so a repo that builds only there opts in with `heavy = ["behavioral", "landing"]`. A heavy gate takes its heavy slot before its machine gate slot |
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
| `.self` | `[]` | skills the sidekick runs on its diff before reporting done |
| `.standards` | `[]` | doc sections (`path#anchor`) the review holds the diff to |
| `.max_batch_diff` | `800` | a batch over this many diff lines verifies per unit instead |
| `.engine` | unset | a review tool the owner requires on every unit, such as `"joo"`. The kitchen does not run it; the master does, and land-check refuses an accepted unit whose review note has no `engine: <name> <run id or artifact path>` line. `doctor` checks that `<name>-dev` or `<name>` is on PATH |
| `.routine`, `.escalated`, `.landing` | unset | tuned a reviewer the kitchen no longer runs; still parsed, ignored, and `validate` and `doctor` warn while the file sets them |
| `[verify]` | | |
| `.routine_kind`, `.escalated_kind` | unset | moved to the host roster's `[verifier]` and `[verifier.escalated]`; still parsed, ignored, and `validate` and `doctor` warn on stderr while the file sets them |
| `[landing].mode` | `"commit"` | how far the kitchen goes: `commit`, `branch` (push), `stack` (a linear stack of PRs), `pr`. It never merges. A stack landed by a push that rewrites its commits (a squash; `jj checked-push` of an spr stack, whose PRs sit on synthetic merge heads) leaves its PRs open: the landing brief closes each with a pointer to its landed commit |
| `[coverage].ignore` | `[]` | globs `doctor` and `classify` treat as covered without a gate |
| `[resources].max_parallel_heavy` | `1` | heavy gates running at once on this machine |
| `[scratch].setup` | `[]` | commands that prepare a bare worktree, run in order by `kitchen.py setup` (first in every verifier packet when set, and once by `kitchen.sh init` as the sidekick when the run's checkout is a linked worktree), inside `[run].wrap`, from the repo root, as the verifier. They run inside the wrap, so do not repeat it: with `wrap = "nix develop --impure --command"` the line is `bun install --frozen-lockfile`. `doctor` warns when a root lockfile suggests the repo needs one |
| `[run].wrap` | `""` | a prefix the gates run inside, such as `nix develop --impure --command`, entered once per gate |

## Lanes

Every command the kitchen runs for a role sees two variables: `PSTACK_KITCHEN_ROLE`
(`sidekick` or `verifier`) and `PSTACK_KITCHEN_RUN` (the run's slug). The role
keeps the sidekick and its verifier apart; the run keeps two kitchens on one
machine apart. A repo's scripts should derive ports, data directories and
emulator names from the (run, role) pair, since either one alone can collide
(two runs share the role `verifier`). `kitchen.py` passes both through to the
wrap, `setup` and gate commands without inferring or clearing them; the kitchen
allocates no ports.

## Globs

Paths are repo-relative. `**` crosses directories; `*` and `?` stay inside
one. A pattern never matches a basename alone: `*.md` is top-level only,
`**/*.md` is everywhere.

## Commands

Each command runs with `bash -c` from the repo root; its output goes to a log
under `${XDG_STATE_HOME:-~/.local/state}/pstack/kitchen/repos/<repo>/logs/`,
and a failure prints the log's last 20 lines. A gate stops at its first
failure. A command that fails while the one-minute load is over one per core
runs once more: a pass then counts, marked `flaky under load` in the step's
output and counted by `retro` as `gate-flaky`, so a suite that only fails on
a loaded machine shows up as that rather than as broken changes.
`PSTACK_KITCHEN_RETRY_LOAD` sets the load per core (default `1.0`; `off` never
reruns). Each gate also runs with its own short `TMPDIR` under `/tmp`, removed
when it ends (`PSTACK_KITCHEN_GATE_TMP` moves it). Every command sees `PSTACK_KITCHEN_STEP_BASE`, the commit the step or unit
is checked against, so an affected-only command covers every commit of a
multi-commit step (`turbo run test --filter=...[$PSTACK_KITCHEN_STEP_BASE]`;
give a fallback such as `${PSTACK_KITCHEN_STEP_BASE:-HEAD^1}` for runs
outside a step). Ranges are measured from the merge-base, so a squash or a
rebased step still covers everything it carries. Every command also sees
`PSTACK_KITCHEN_ROLE` (`sidekick` or `verifier`):
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
kitchen.py validate                                   # parse and check; names the source
kitchen.py where [--host]                             # the kitchen in use, and the host path
kitchen.py snapshot <dir>                             # copy a host kitchen into dir by content hash; prints it
kitchen.py classify --base <sha> [--head <sha>]       # a unit's commits
kitchen.py classify --working-tree                    # uncommitted work
kitchen.py classify --paths 'apps/web/**' src/x.ts    # a brief's Scope, before work starts
kitchen.py gate <profile> fast|behavioral|landing     # exit 2 on failure; --keep-going, --only N
kitchen.py policy --base <sha> [--head <sha>]         # forbid rules and test-touch; exit 2 on findings
kitchen.py history [--last 20]                        # how each recent commit classifies, and its policy findings
kitchen.py doctor [--run]                             # coverage, commands, features; --run records a baseline
kitchen.py lessons [--all]                            # staged lessons with held/hit counts, then the top candidates
kitchen.py lessons add <kind> <class> <area> [--match M] "<rule>" # stage an evidence-backed lesson (proposed)
kitchen.py lessons dismiss <kind> <class> <area> [--match M] --note "<why>" # hide a candidate with no one cause
kitchen.py lessons set <id> <status> [--rule] [--note] # proposed | active | promoted | retired
kitchen.py lessons promote <id> [--out <file>]        # the promotion proposal for the human to decide
kitchen.py ledger-backfill <ledger> [--runs <dir>]    # give rows from before area and match both, from the run stores
```

Lessons live in `.agents/LESSONS.md` beside a repo kitchen, or beside a host
kitchen as `<key>.lessons.md`; they are not a kitchen.toml key. The file holds
each rule, its status and evidence, and any notes a human adds (a rewrite
keeps them); held and hit counts stay in the host ledger, which also hands out
lesson ids, so runs in parallel worktrees never stage the same one. A
lesson's match is the trouble within its class: the stage and check a gate
failed (`fast lint`), the policy rule (`test-touch`, class `policy`), or the
steer's kind.

`--json` gives each result as data, `--at <rev>` reads the kitchen (and, for
`--paths`, the file list) at a revision, and `--repo` points at another
checkout. `classify` prints the risk class with every escalation reason, the
touched profiles, files no profile covers, the verification mode and kind, the
sample rate, the review settings, and the feature files the verifier needs.
