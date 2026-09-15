---
name: pstack-pair
description: "Run two coding agents in one Herdr session as a pair: a master that plans, briefs, reviews, and decides, and a sidekick that implements, tests, and diagnoses under pstack playbooks. Use for /pstack-pair, 'pair mode', 'spawn a sidekick', 'be the sidekick', a `pstack-pair PLAN|BRIEF|REPORT|STOP` message, or when work should be delegated to a second agent pane with a reviewable brief and report trail. Requires HERDR_ENV=1."
---

Read [the runtime adapter](../pstack/references/runtime.md) before following this workflow. Its runtime mappings apply to all referenced playbooks and scripts.

# Pstack pair

Two agents, one Herdr session, one repository. The master owns judgment and the
sidekick owns the working tree. Every message between them is a file in the
pair store plus a one-line Herdr prompt that names the file. The terminal is
never the record, because agents on the alternate screen leave no scrollback.

## Preconditions

1. `test "${HERDR_ENV:-}" = 1`. Outside Herdr, say so and stop.
2. Load the Herdr skill for pane and agent control:
   `~/.agents/skills/herdr/SKILL.md`, or `herdr --skill` when that file is
   absent. Its safety rules apply throughout.
3. `jq` and `herdr` on PATH. `scripts/pair.sh help` lists every store and
   channel operation; use it instead of hand-built `herdr` calls for the pair.
4. Both agents run with the same permission mode, auto by default, where the
   model decides what needs approval. Start the master in auto mode.
   `pair.sh spawn` detects the master's mode and starts the sidekick with its
   equivalent (`--permission-mode` for Claude Code, `-a on-request -s
   workspace-write` for Codex); `pair.sh permission` prints what it detected,
   and `--permission <mode>` overrides it. Kinds without a translation take
   native flags after `--`.

## Roles

| | Master | Sidekick |
| --- | --- | --- |
| Owns | plan, briefs, review, decisions, the human | the working tree, tests, diagnosis, evidence |
| Runs pstack as | poteto-mode framing, `how`, `architect`, review skills | the playbook each brief names, with its todolist |
| Writes | the pair store only | files inside the brief's Scope, plus its report |
| Speaks through | briefs, reviews, standing orders, gates | reports |

Enter your role. Master: [references/master.md](references/master.md).
Sidekick: [references/sidekick.md](references/sidekick.md).

## Pair store

`${XDG_STATE_HOME:-$HOME/.local/state}/pstack/pair/<slug>/`, created by
`pair.sh init`. One writer per file.

| Path | Writer | Content |
| --- | --- | --- |
| `pair.json` | master via `pair.sh` | agent names, pane ids, cwd, git root |
| `standing-orders.md` | master | numbered constraints pasted by path into every brief |
| `plans/NNN-<slug>.md` | master | one plan round, from [the plan template](references/plan-template.md) |
| `briefs/NNN-<slug>.md` | master | one unit, from [the brief template](references/brief-template.md) |
| `reports/NNN-<slug>.md` | sidekick | evidence for brief NNN, from [the report template](references/report-template.md), or the agree/object response to plan NNN, from [the plan response template](references/plan-response-template.md) |
| `reviews/NNN-<slug>.md` | master | verdict on report NNN, from [the review template](references/review-template.md); `agreed` on a plan unlocks its briefs |
| `gates.md` | master | open questions for the human |
| `decisions.tsv` | master via `pair.sh log` | the show-me-your-work trail |
| `status.md` | `pair.sh status` | derived table; never hand-edited |

`NNN` is a zero-padded sequence shared by plan or brief, report, and review, so
the files for one unit sort together.

## Messages

| Prompt text | Direction | Sender's helper | Receiver's move |
| --- | --- | --- | --- |
| bootstrap (names the skill and the store) | master to sidekick | `pair.sh spawn` | bootstrap steps, `reports/000-ready.md`, reply `READY` |
| `pstack-pair PLAN <plan-path>` | master to sidekick | `pair.sh discuss` | ground the plan in the code, write an agree or object response, end the turn |
| `pstack-pair BRIEF <brief-path>` | master to sidekick | `pair.sh dispatch` | run the brief, write its report, end the turn |
| `pstack-pair REPORT <report-path>` | sidekick to master | `pair.sh notify` | read the report, review |
| `pstack-pair STOP <store>` | master to sidekick | `pair.sh stop` | pause safely, write a stop report |

The master's `dispatch` and `wait` return when the sidekick settles into
`idle`, `done`, or `blocked`. The sidekick ending its turn is the reply.
`notify` prompts the master only when the master is idle, so a waiting master
is never interrupted. A message you receive after compaction still names this
skill and the file to read, so reload the skill and continue from that file.

## Plan first

Implementation starts only from a plan both agents agreed to. The master
drives the implementation, architecture, and system design: it drafts
`plans/NNN-<slug>.md` with the chosen design, the alternatives it weighed, and
their pros and cons, then sends it with `pair.sh discuss`. The sidekick
brainstorms against those trade-offs, checks every step against the code, and
answers agree or object with evidence.
The master revises in a new plan round or answers the objections, until a
response says agree and the master writes a review with verdict `agreed`.
`pair.sh dispatch` refuses a feature, bug-fix, refactoring, perf-issue, or
pstack-tdd brief whose `plan:` line does not name an agreed plan. Read-only
and forensic briefs need no plan; a bug's diagnosis brief runs before its plan,
so the plan rests on runtime evidence. Three rounds without agreement become a
gate for the human, with both positions in `gates.md`.

## Shared rules

- Facts about panes, agents, and states come from `herdr` JSON through
  `pair.sh`, never from memory or sidebar order.
- Approval dialogs belong to the human unless the standing orders delegate a
  class of them to the master. Neither agent answers the other's dialogs.
- Both agents share one working tree, so the master reads and runs checks only
  while the sidekick is idle, and edits nothing under the repository.
- Close only panes you created, and only when the human asked.
