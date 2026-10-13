---
name: pstack-kitchen-setup
description: "Prepare any repository for pstack-kitchen: read its CI, task runners, and agent rules, write .agents/kitchen.toml, or a local-only host kitchen when the team has not agreed to commit one (profiles of the repo's own gate commands, escalation triggers, policy rules, review and landing settings), make sure a verification skill exists, and prove the result with kitchen.py doctor, a green baseline, and the repo's recent history. Use for /pstack-kitchen-setup, 'set up the kitchen', 'prepare this repo for the kitchen', when pstack-kitchen reports no kitchen, or after a repo's checks or rules change."
---

Read [the runtime adapter](../pstack/references/runtime.md) before following this workflow. Its runtime mappings apply to all referenced playbooks and scripts.

# Pstack kitchen setup

pstack-kitchen spends the master's attention on exceptions, not on every
dish. That works only when the repo itself says, as data, which of its own
commands prove which part of it, what makes a change risky, and which lines
must never land. This skill writes that data, `.agents/kitchen.toml`, and
proves it against the repo before anyone relies on it. A repo whose team has
not agreed to commit it gets a local-only host kitchen instead, outside the
repo; the kitchen reads either the same way. The schema is in
[kitchen-toml.md](../pstack-kitchen/references/kitchen-toml.md), with a
[worked example](../pstack-kitchen/references/kitchen-example.toml).

`kitchen.py` below means `~/.agents/skills/pstack-kitchen/scripts/kitchen.py`.
The master runs this skill in its own session; it needs no sidekick. It does
not choose agents: which harness runs the sidekick is the host's choice, not
the repo's.

## 0. Start or maintain

- No kitchen (`kitchen.py where` finds none): set up, steps 1 to 7. Ask the
  human once whether the kitchen is committed (the default) or local only.
  Local only writes to the host path `kitchen.py where --host` prints and
  commits nothing.
- An untracked or excluded `.agents/kitchen.toml` (`doctor` fails `kitchen`)
  is a half state: verify and the verifier read commits and never see it.
  Commit it, or move it to `kitchen.py where --host`, then maintain.
- One exists: maintain. `kitchen.py validate`, then `kitchen.py doctor --run`
  and `kitchen.py history --last 30`. Compare the CI workflows and task
  runners against the profiles for drift: a CI job or package with no
  profile, a profile command CI no longer runs, an AGENTS rule added since.
  Fix only what drifted, then prove it as in step 6. A promoted lesson
  (pstack-kitchen's `kitchen.py lessons promote`) arrives here as a brief
  with its proposal: add the check it names, and prove it fails on the
  lesson's evidence commit before it passes on HEAD.

## 1. Read the repo, not the human

Answer from the code; ask only what the code cannot say. In order of
authority:

1. **CI.** `.github/workflows/`, `.gitlab-ci.yml`, `.buildkite/`, and the
   like: the gates that actually block a merge. For each job, its commands
   and the path filters that trigger it. A job with path filters is a profile
   boundary drawn for you.
2. **Task runners.** `package.json` scripts and workspaces, `justfile`,
   `Makefile`, mise tasks, Cargo workspaces, `flake.nix` checks,
   `pyproject.toml`. These name the entry points humans use; the kitchen uses
   the same ones, never a command the repo does not have.
3. **Agent rules.** `AGENTS.md`, `CLAUDE.md`, `CONTRIBUTING.md`: required
   wrappers, forbidden commands, package boundaries, the landing policy.
4. **Shape.** Top-level areas (apps, packages, services, crates) and where
   their tests live.
5. **Verification.** An existing `.agents/skills/verify-*` and its feature
   map, e2e suites, journey or smoke scripts.
6. **Review.** The skills the sidekick should run on its own diff, and the
   style sections a review holds the diff to.

In a large monorepo, read CI and the runners yourself and fan out one
read-only subagent per area for test locations and entry points, each
returning a short summary (the guard-the-context-window principle).

## 2. Draft the profiles

One profile per area with its own proof. For each:

- `paths`: the area's globs (see the glob rules in the schema).
- `fast`: what CI runs for those paths that finishes in minutes: format,
  lint, typecheck, the area's unit tests. This runs at every committed step,
  so a slow command here costs every step; move it to `landing`. Prefer the
  repo's affected-only entry point (changed-files test mode, a workspace
  filter from `$PSTACK_KITCHEN_STEP_BASE`, a per-package test) over the whole suite: steps queue
  for the machine's gate slots, and a five-minute gate that takes thirteen
  under load stalls the sidekick.
- `behavioral`: e2e, journey, or app-driving commands the verifier runs at
  the unit's commit.
- The release gate's cheap static checks (test inventories, name-based
  conformance lists, schema snapshots): put them in a profile's `fast` or
  `behavioral` commands, so a step or a verifier catches what would otherwise
  fail only at the release push.
- `landing`: the rest of CI's battery for the area, run once.
- `tests` and `require_tests = true` where the area has tests.
- `verify`: `gates` for areas whose deterministic gates are the whole proof
  (docs, config, a library with thorough tests); `batch` by default; `unit`
  where a broken unit is expensive to find later.
- `heavy = true` for builds that saturate the machine (Rust, large
  TypeScript builds, Nix).
- `sample`: lower for areas the gates prove well, higher where they do not.

Three shapes need care:

- **A toolchain inside a shell.** When the tools exist only inside
  `nix develop`, a container, or an activated environment, set
  `[run] wrap` to that prefix once instead of prefixing every command;
  `kitchen.py` enters it once per gate. A profile that must run outside it
  sets `wrap = ""`.
- **A worktree that needs preparing.** A verifier works in a bare scratch
  worktree, with no installed dependencies. Read the repo's own install
  command (the one CI or its README runs) and write it as `[scratch] setup =
  [...]`, without the `[run] wrap` it already runs inside; `doctor` warns when
  a root lockfile suggests it is missing. The packet runs it first.
- **One script that runs every stage.** Read it and list its stages as
  separate commands, so a failure names the stage and `fast` can leave the
  slow ones to `landing`.
- **Tests that need an environment** (a real terminal, a display, network,
  credentials). The sidekick and verifier may run headless, so they do not
  belong in `fast`. Put them in `behavioral`, where the verifier drives the
  real surface, or in `landing`.

Every file belongs to a profile or to `coverage.ignore`. Ignore only files
that need no proof (licenses, editor settings). CI config and lockfiles are
not in that set: give CI config an escalate path, and let manifests escalate.

## 3. Escalation, policy, review, landing

- **Escalate** what deserves the consultant and a per-unit verifier:
  contracts, schemas, migrations, auth, public APIs, deploy config
  (`escalate.paths`); dependency manifests; `max_profiles` in a monorepo
  whose packages must not change together casually. Start narrow: a path
  that changes in a third of recent commits is routine work, not an
  exception. Step 6's history check settles it; aim for about one commit in
  five escalating, or fewer.
- **Policy.** One `[[policy.forbid]]` per AGENTS rule that a regular
  expression on an added line can catch, with `source` pointing at the rule
  and a `message` that names what to use instead. Scope its `paths` to where
  the pattern is a violation (scripts, code), not docs that may mention it. A
  rule that needs judgment stays in the docs; offer the `correct` skill for
  those.
- **Review.** `self` lists the skills the sidekick runs on its diff;
  `standards` points at the style sections the review should hold the diff
  to. The kitchen runs no reviewer: how the master reviews (its own read, the
  agent's built-in review, an external tool) is the owner's choice. Set
  `engine` only when the owner requires a review tool on every unit (such as
  `"joo"` for Judge of Owls): land-check then refuses a unit whose review
  note cites no run of it.
- **Landing.** Take the mode from the repo's rules (a `jj spr` stack is
  `stack`, "commit only" is `commit`). Ask the human only when the rules do
  not say. The kitchen never merges.

## 4. Verification skill

When a profile has a user-facing surface (UI, CLI, service) and the repo has
no `.agents/skills/verify-*`, run `create-verification-skill` now; it
generates and proves the skill. Then point each surface profile's `features`
at its feature-map files and its `behavioral` commands at what that skill
drives. A library with no surface needs none.

## 5. Validate, format, commit

```bash
kitchen.py validate
kitchen.py doctor
```

Fix every `fail`; a `warn` needs a reason in the report. `doctor` proves
only that each command's program exists where it runs; step 6 proves the
commands work. Format `kitchen.toml` with the repo's own formatter (its
format gate checks the file too), then commit it on a branch, following the
repo's commit conventions, and do not push. Step 6 runs on that commit, so
the tree is clean and a worktree contains the kitchen; amend the commit as
step 6 tunes it.

Local only: write the file at `kitchen.py where --host`, format it with the
repo's TOML formatter if it has one, and commit nothing. `validate` and
`doctor` must name it as the source (`user` or `roster`). Step 6 runs on
HEAD as it is, and its scratch worktree finds the same host file.

## 6. Prove it against the repo

1. **Green baseline.** `kitchen.py doctor --run` runs every fast gate to the
   end, printing progress on stderr. Every gate passes. A red gate is one of
   three things:
   - a wrong command or a missing wrap: fix it;
   - a test that needs an environment the run lacks: move it (step 2);
   - a test that fails under load but passes alone (`kitchen.py gate <p>
     fast --only N`), or a repo that is red on HEAD: kitchen debt. Report it
     to the human with the log and ask whether to fix it first or move it
     out of `fast`; never drop a test silently.

   Note each profile's time; a fast gate over about five minutes belongs
   partly in `landing`.
2. **History.** `kitchen.py history --last 30`. Read every row. A commit that
   was plainly architectural but shows `routine` needs an escalate path; a
   routine change that shows `escalated` needs a looser trigger. Every policy
   finding on accepted history is a rule that is too broad, or a real
   violation; narrow the rule or confirm the violation with the human.
3. **One gate failing on purpose.** In a scratch worktree (`git worktree
   add`), install the repo's dependencies its own way or link the dependency
   directories from the main checkout, break one line, and run the one
   command that should catch it (`kitchen.py gate <p> fast --only N`). See it
   fail with a log that names the problem, then remove the worktree. A gate
   that cannot fail proves nothing.

## 7. Hand back

The branch holds the kitchen commit (local only: the host file's path
instead), and the verification skill in its own commit if one was created. Do not push without the human's word. Reply with:

- the profiles: paths, gate commands, verify mode, baseline seconds;
- escalation triggers and policy rules, each with its source;
- the history table's summary and every row you changed a rule for;
- the landing mode and where it came from;
- open questions, with the default each one takes if unanswered.
