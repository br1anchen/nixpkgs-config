---
name: pstack-kitchen
description: "Run coding work as a kitchen in one Herdr session: a master that plans, briefs, triages code review, and decides; a sidekick on the cheapest capable model that implements under the repo's own deterministic gates; a consultant started only when a unit escalates; and a fresh verifier pane that proves each unit on the real surface. The master is woken by exceptions, not by every step. Needs the repo's .agents/kitchen.toml (pstack-kitchen-setup writes it). Use for /pstack-kitchen, 'kitchen mode', 'run the kitchen', a `pstack-kitchen PLAN|BRIEF|STEER|CONSULT|VERIFY|REPORT|ADVICE|FEEDBACK|STOP` message, 'be the sidekick/consultant/verifier' in a kitchen, or sustained delegated work that should not need the master on every step. Requires HERDR_ENV=1."
---

Read [the runtime adapter](../pstack/references/runtime.md) before following this workflow. Its runtime mappings apply to all referenced playbooks and scripts.

# Pstack kitchen

pstack-pair with the master's attention moved from dishes to the kitchen.
The repo states, in `.agents/kitchen.toml`, which of its own commands prove
which part of it and what makes a change risky; `kitchen.py` reads that as
data. Every committed step passes those gates before it counts, a fresh
verifier proves each finished unit, and Judge of Owls sweeps its diff. The
master plans, writes precise briefs, triages the review, and decides; it is
woken by exceptions, not by routine steps. What keeps going wrong becomes a
rule in the kitchen, not another correction.

Everything [pstack-pair](../pstack-pair/SKILL.md) says about the store, the
messages, plans, check-ins, steers, the queue, notes, pausing, Devin and Pi
sidekicks, and shared rules holds here, with `kitchen.sh` in place of
`pair.sh` and `pstack-kitchen` in every message. This file covers what
differs.

## Preconditions

1. `test "${HERDR_ENV:-}" = 1`, the Herdr skill loaded, `jq`, `herdr`, and
   Python 3.11 or later on PATH. `scripts/kitchen.sh help` lists the commands.
2. The repo has `.agents/kitchen.toml` and `kitchen.py validate` passes
   (`scripts/kitchen.py`). Without it, run pstack-kitchen-setup first; a
   kitchen without rules is a pair with extra steps.
3. The host roster, `~/.config/pstack/kitchen.toml`, names the agents (all
   optional; `--kind` overrides):

   ```toml
   [sidekick]
   kind = "pi"
   args = ["--model", "devin/swe-2", "--thinking", "high"]
   [sidekick.fallback]
   kind = "devin"
   [consultant]
   kind = "codex"
   [verifier]            # routine units; default: the run's current sidekick
   kind = "pi"
   args = ["--model", "devin/swe-2", "--thinking", "high"]
   [verifier.fallback]   # a verifier stopped by its provider retries once here
   kind = "claude"
   args = ["--model", "claude-sonnet-5-5"]
   [verifier.escalated]  # escalated units and --landing; default: claude opus
   kind = "claude"
   args = ["--model", "claude-opus-5-5"]
   [machine]
   gate_slots = 1   # gates running at once across every kitchen on this host
   ```

   Without `[verifier]`, a routine unit is verified by the sidekick now
   implementing the run (its kind and arguments from `pair.json`, so after a
   failover it is the fallback), and an escalated unit or `verify --landing`
   by `claude --model claude-opus-5-5` with no fallback. `kind = "master"`
   in either entry means the master's own kind.

   Every gate takes one of the machine's slots, so parallel kitchens queue
   their test suites instead of overloading the machine. The default is one
   slot per eight cores.

## Roles and quota

Each role draws on a different quota; the kitchen spends each where it is
worth most.

| | Master | Sidekick | Consultant | Verifier |
| --- | --- | --- | --- | --- |
| Agent | the strongest model | the largest, cheapest pool | a different strong model, the scarcest | the host roster's `[verifier]`: the sidekick's kind (routine) or Claude Opus (escalated) |
| Lives | the whole run | the whole run, rotated or failed over | from the first escalation | one verification, then its pane closes |
| Owns | plans, briefs, review triage, decisions, the human | the working tree, steps, fixes | design critique | the verdict |
| Writes | the store | the brief's Scope | advice, scratch | its verdict, in a scratch worktree |

Enter your role. Master: [references/master.md](references/master.md).
Sidekick: [references/sidekick.md](references/sidekick.md).
Consultant: [references/consultant.md](references/consultant.md).
Verifier: [references/verifier.md](references/verifier.md).

## A unit's path

1. **Classify.** The brief's may-write Scope maps to profiles and a risk
   class (`kitchen.sh classify`; dispatch does it too). `routine` runs on the
   brief alone. `escalated` (a contract, a migration, a dependency, a
   cross-profile change, files no gate covers) starts the consultant and needs
   a plan round with it.
2. **Steps.** The sidekick commits each step and records it with
   `kitchen.sh step`, which runs the touched profiles' fast gates and the
   policy check and records only a passing step. The master does not read a
   routine unit's steps.
3. **Verify.** `kitchen.sh verify` per the unit's verify mode: `gates` (the
   step gates were the proof), `batch` (one verifier for several routine
   units), or `unit`. The verifier proves the brief's Acceptance at the
   unit's head and writes a verdict with evidence; a fix is verified with
   the unit it fixes (`--covers`). `verify` returns at an interval while the
   verifier works, so the master is never held in one long call.
4. **Review.** `kitchen.sh review` runs Judge of Owls on the unit's range at
   the risk class's style and budget. The master triages every critical or
   high finding: fixed, follow-up, or dismissed, each recorded with
   `kitchen.sh resolve`.
5. **Accept.** The master's review is short when the verdict is clean and
   the findings are resolved; a sampled unit (`audit: yes`) gets a full read.
6. **Land.** `kitchen.sh land-check` passes only when every accepted unit is
   verified and every blocking finding resolved; `kitchen.sh verify --landing`
   proves the stack tip with a fresh verifier; the landing brief goes as far
   as `[landing].mode` allows and never merges.
7. **Learn.** `kitchen.sh retro` shows where the master was needed and what
   repeated; each repeated class becomes a rule, a lint, a profile command, or
   a standing order. A gap in the kitchen itself goes to `kitchen.sh feedback`.

## Feedback

`kitchen.sh feedback <store> <file>` files the master's gaps (from [the
template](references/feedback-template.md)) into the host inbox,
`${XDG_STATE_HOME:-$HOME/.local/state}/pstack/feedback/`, behind a header it
writes. A maintainer session registered with `kitchen.sh maintainer on` gets
`pstack-kitchen FEEDBACK <path>` and works as [references/maintainer.md](references/maintainer.md)
says; with none live, the human gets a notification. `feedback --inbox` lists
open reports and `feedback --close` retires one.

## When the master wakes

A report (done, partial, blocked), a check-in digest at the interval, a
steer objection, an escalated unit's steps, a rejected or inconclusive
verdict, review findings, a sampled audit, an approval dialog, and a
provider error. Two failed gates in a row reach the master as a blocked
report. Everything else the kitchen handles.

## Store additions

The pair's store under `${XDG_STATE_HOME:-$HOME/.local/state}/pstack/kitchen/runs/<slug>/`, plus:

| Path | Writer | Content |
| --- | --- | --- |
| `gates.tsv` | `kitchen.sh step` | one row per step check: time, unit, commit, pass or fail, profiles |
| `verdicts/NNN-<slug>-v<k>.md` | verifier, or `verify` for gates mode | the verdict, from [the verdict template](references/verdict-template.md) |
| `verdicts/NNN-<slug>-v<k>-packet.md` | `kitchen.sh verify` | what the verifier was given |
| `joo/<unit or landing>-r<k>.json` | `kitchen.sh review` | the Judge of Owls review artifact |
| `resolutions.tsv` | master via `kitchen.sh resolve` | one decision per finding |
| `pair.json` `.escalations` | `kitchen.sh consultant` | why the consultant was started |

Beside the runs, on the host: `pstack/feedback/inbox/<date>-<repo>-<run>[-k].md` (open reports),
`feedback/done/` (closed ones, with a Closed block) and `feedback/maintainer.json` (the registered
maintainer), all written by `kitchen.sh feedback` and `maintainer`.

The repo's ledger, across runs, is `ledger.tsv` in `kitchen.py statedir`; `timings.tsv` beside it
records each gate's run time, which `kitchen.py timing` reads.
