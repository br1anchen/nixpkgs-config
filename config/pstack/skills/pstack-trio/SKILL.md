---
name: pstack-trio
description: "Run three coding agents in one Herdr session: a master that plans, briefs, reviews, and decides; a sidekick that implements, tests, and diagnoses under pstack playbooks; and a consultant of a different agent kind that critiques plans, answers design and finding consults, and prototypes in a throwaway worktree. The master drives every discussion, delegates implementation to the sidekick, and consults before steering on anything that changes the design. Use for /pstack-trio, 'trio mode', 'spawn a sidekick and a consultant', 'be the consultant', a `pstack-trio PLAN|BRIEF|STEER|CONSULT|REPORT|ADVICE|STOP` message, or when work should be delegated with a second opinion on file. Requires HERDR_ENV=1 and at least two distinct agent kinds."
---

Read [the runtime adapter](../pstack/references/runtime.md) before following this workflow. Its runtime mappings apply to all referenced playbooks and scripts.

# Pstack trio

Three agents, one Herdr session, one repository. The master owns judgment,
the sidekick owns the working tree, and the consultant owns the second
opinion. Every message between them is a file in the trio store plus a
one-line Herdr prompt that names the file. The terminal is never the record,
because agents on the alternate screen leave no scrollback.

The trio is `pstack-pair` with a consultant added. The pair's plan rounds,
briefs, check-ins, steers, and reviews are unchanged; the consultant joins
every plan round and answers consults when a finding changes the design. It
never messages the sidekick and never writes the shared tree.

## Preconditions

1. `test "${HERDR_ENV:-}" = 1`. Outside Herdr, say so and stop.
2. Load the Herdr skill for pane and agent control:
   `~/.agents/skills/herdr/SKILL.md`, or `herdr --skill` when that file is
   absent. Its safety rules apply throughout.
3. `jq` and `herdr` on PATH. `scripts/pair.sh help` lists every store and
   channel operation; use it instead of hand-built `herdr` calls for the trio.
4. At least two distinct agent kinds among master, sidekick, and consultant.
   `pair.sh spawn` reads the master's kind from Herdr and exits 8 when all
   three would match; tell the human to pick another kind or use
   `pstack-pair`. Sidekick and consultant may share a kind.
5. All three agents run with the master's permission mode, auto by default.
   `pair.sh spawn` detects it and translates per kind (`--permission-mode`
   for Claude Code, `--permission-mode smart` for Devin, `-a on-request -s
   workspace-write` for Codex); `--permission` and `--consultant-permission`
   override it. Kinds without a translation take native flags after `--`.

## Roles

| | Master | Sidekick | Consultant |
| --- | --- | --- | --- |
| Owns | plan, briefs, consults, review, decisions, the human | the working tree, tests, diagnosis, evidence | design critique, second reads, prototypes |
| Runs pstack as | poteto-mode framing, `how`, `architect`, review skills | the playbook each brief names, with its todolist | `how`, `why`, `architect` alternatives, `interrogate` stance, `blast-radius` on diffs |
| Writes | the trio store only | files inside the brief's Scope, plus its progress log and reports | advice files, and a scratch worktree it removes |
| Reads the tree | always, read-only; runs checks in scratch at a commit | always | always, read-only |
| Speaks through | plans, briefs, steers, consults, reviews, standing orders, gates | progress lines, reports | advice |

Enter your role. Master: [references/master.md](references/master.md).
Sidekick: [references/sidekick.md](references/sidekick.md).
Consultant: [references/consultant.md](references/consultant.md).

## Trio store

`${XDG_STATE_HOME:-$HOME/.local/state}/pstack/trio/<slug>/`, created by
`pair.sh init`. One writer per file.

| Path | Writer | Content |
| --- | --- | --- |
| `pair.json` | master via `pair.sh` | agent names, pane ids, kinds, cwd, git root, open scratch list |
| `standing-orders.md` | master | numbered constraints pasted by path into every brief |
| `plans/NNN-<slug>.md` | master | one plan round, from [the plan template](references/plan-template.md) |
| `briefs/NNN-<slug>.md` | master | one unit, from [the brief template](references/brief-template.md) |
| `progress/NNN-<slug>.md` | sidekick via `pair.sh progress` | one timestamped line per completed step or change of approach |
| `steers/NNN-<slug>-s<k>.md` | master | mid-brief direction k for unit NNN, from [the steer template](references/steer-template.md) |
| `consults/NNN-<slug>-c<k>.md` | master | question k about unit NNN for the consultant, from [the consult template](references/consult-template.md), with a `kind:` of design, finding, objection, or review |
| `reports/NNN-<slug>-s<k>.md` | sidekick | objection to steer k, from [the steer response template](references/steer-response-template.md) |
| `reports/NNN-<slug>.md` | sidekick | evidence for brief NNN, from [the report template](references/report-template.md), or the agree/object response to plan NNN, from [the plan response template](references/plan-response-template.md) |
| `advice/NNN-<slug>.md` | consultant | design critique of plan NNN, from [the plan advice template](references/plan-advice-template.md) |
| `advice/NNN-<slug>-c<k>.md` | consultant | answer to consult k, from [the advice template](references/advice-template.md) |
| `scratch/<id>/` | consultant or master via `pair.sh scratch` | throwaway worktree for one consult (`NNN-<slug>-c<k>`) or review (`NNN-<slug>-review`), at a commit or the live state; removed when done |
| `reviews/NNN-<slug>.md` | master | verdict on unit NNN, from [the review template](references/review-template.md); names the advice it drew on and any overrule |
| `gates.md` | master | open questions for the human |
| `decisions.tsv` | master via `pair.sh log` | the show-me-your-work trail |
| `status.md` | `pair.sh status` | derived table; never hand-edited |
| `queue` | master via `pair.sh queue`; the sidekick empties it with `pair.sh next` | the next brief's path, one slot |
| `events.tsv` | every `pair.sh` command | one row per message, report, wake, and log entry, read by `pair.sh metrics` |

`NNN` is a zero-padded sequence shared by plan or brief, report, advice, and
review, so the files for one unit sort together.

## Messages

| Prompt text | Direction | Sender's helper | Receiver's move |
| --- | --- | --- | --- |
| bootstrap (names the skill, the role, and the store) | master to sidekick and consultant | `pair.sh spawn` | bootstrap steps, `reports/000-ready.md` or `advice/000-ready.md`, reply `READY` |
| `pstack-trio PLAN <plan-path>` | master to sidekick and consultant at once | `pair.sh discuss` | sidekick grounds the plan in the code; consultant critiques the design; each writes agree or object, ends the turn |
| `pstack-trio BRIEF <brief-path>` | master to sidekick | `pair.sh dispatch` | run the brief, write its report, run `pair.sh finish`, then start the queued brief it names or end the turn |
| `pstack-trio BRIEF <brief-path>`, queued | master to a working sidekick | `pair.sh queue` | taken with `pair.sh next` right after a `done` report, in the same turn |
| `pstack-trio STEER <steer-path>` | master to a working sidekick, or one paused on an objection | `pair.sh steer` | read it between tool calls; agree and continue, or object with evidence and end the turn |
| `pstack-trio CONSULT <consult-path>` | master to consultant | `pair.sh consult` | read the named files, prototype in scratch if needed, write the advice, end the turn |
| `pstack-trio REPORT <report-path>` | sidekick to master | `pair.sh finish` (or `notify`) | read the report, review |
| `pstack-trio ADVICE <advice-path>` | consultant to master | `pair.sh notify` | read the advice, decide |
| `pstack-trio STOP <store>` | master to sidekick and consultant | `pair.sh stop` | pause safely, write a stop report or advice |

`discuss` returns when both agents settle, with one response path and status
per role. `consult` returns when the consultant settles into `idle`, `done`, or
`blocked`. `dispatch` and `wait` return when the sidekick's reply lands, the
report written since the message, or when it is `blocked`; a settle from
`herdr` alone is not trusted, because a Devin sidekick shows idle as a prompt
arrives and between steps, and one with no report that holds for a minute ends
the wait with `report: missing`. `dispatch` and `wait` also return at the
check-in interval with a digest. `wait` also returns the moment a dispatched
brief's report lands, even when the sidekick has already taken the queued
brief; `running:` then names the brief it is on. `notify` prompts the master only when the
master is idle. A message you receive after compaction still names this
skill and the file to read, so reload the skill and continue from that file.

## Plan first

Implementation starts only from a plan the sidekick agreed to and the
consultant advised on. The master drafts `plans/NNN-<slug>.md` with the
chosen design, the alternatives it weighed, and their pros and cons, then
sends it with `pair.sh discuss`, which reaches both agents at once. The
sidekick checks every step against the code and answers agree or object with
evidence. The consultant critiques the design itself: data shape, boundaries,
what the alternatives table misses, and answers agree or object. The master
merges both into the next round or a review with verdict `agreed`.

The consultant is advisory. An `object` from the consultant does not block
`agreed`; the master may overrule it with the reason under the review's
Overruled section and a decisions row. An advice file for the plan round must
exist, though: `pair.sh dispatch` refuses a feature, bug-fix, refactoring,
perf-issue, or pstack-tdd brief whose plan has no consultant advice on file
or no `agreed` review. Read-only and forensic briefs need no plan; a bug's
diagnosis brief runs before its plan. Three rounds without agreement become a
gate for the human, with all positions in `gates.md`.

## Consults

A consult is the master's question to the consultant outside a plan round.
`pair.sh new-consult <store> <NNN> --kind <kind>` creates the file for unit
NNN; `pair.sh consult` sends it and waits for the advice.

| Kind | When | The consultant answers |
| --- | --- | --- |
| design | the master weighs a direction before a plan or steer | which way and why, with the trade-offs |
| finding | a check-in digest, report, or diff surfaced something unexpected | whether it is what it looks like, and what it changes |
| objection | the sidekick objected to a steer | who is right on the evidence, and the alternative |
| review | a verdict is contested or a unit is on its second revise | accept, revise, or reject, with findings |
| glance | a check-in shows the first commit or a sizeable diff on a unit whose revise would cost the most | in five minutes: would the review say revise, and why, or `none` |

Consults are mandatory before: a steer that departs from the agreed design,
a superseding steer after a sidekick objection, and a `revise` verdict on a
unit's second try. They are optional elsewhere, and none is sent for the
landing unit: every discussion and review ends before landing. Three consults
per unit; `new-consult` refuses a fourth without `--force`, because a fourth
means the design is wrong and belongs in a plan round. A glance sits outside
that cap, one per unit, and is never mandatory: the consultant's quota is the
scarce one, so spend it where a late revise would cost the most.

Every consult runs at any time, the sidekick working or not. `consult`
stamps the sidekick's state and HEAD on the file; the consultant reads
committed work at that head, and anything uncommitted only through a
`pair.sh scratch` snapshot, never a tree that moves under it. Each consult
carries a timebox, fifteen minutes by default and five for a glance; past it
the consultant writes `partial` advice and ends the turn.

## Check-ins and steers

Unchanged from `pstack-pair`: the sidekick appends progress lines, `dispatch`
and `wait` return a check-in digest at the interval, and a steer is the one
message that may reach a working sidekick. Two fresh steers per brief, two
rounds each. The consultant adds one step: when a digest or objection shows a
finding that changes the design, the master consults before it steers, and
the steer's Direction cites the advice path.

## Keeping the sidekick busy

The sidekick is the critical path: the master turns a report around in
minutes, while a unit takes tens of minutes to hours. Three habits keep the
sidekick from waiting on the master.

- **Queue the next brief.** While a unit runs, the master drafts the next one
  and holds it with `pair.sh queue`. The sidekick runs `pair.sh next` after a
  `done` report and starts it in the same turn. The queue has one slot and
  holds only a unit that does not hinge on the running unit's review, so a
  `revise` becomes a follow-up brief, not a rework of the queued one.
- **Review at the commit.** A brief that writes says `commit: yes`, and the
  report's `head:` names that commit. The master reads it with `git show`
  while the sidekick works on the next unit, and reruns checks in `pair.sh
  scratch <store> NNN-<slug>-review --at <head>`, never in the shared tree.
- **Amend instead of re-planning.** An objection the master adopts becomes a
  numbered amendment in the `agreed` review. A new plan round is for a
  changed design, not a narrowed step.

`pair.sh metrics <store>` reads `events.tsv` and shows where the time went:
sidekick busy and idle, master wakes, review latency, verdicts. Sidekick idle
time is the number to drive down.

## Shared rules

- Facts about panes, agents, and states come from `herdr` JSON through
  `pair.sh`, never from memory or sidebar order.
- Approval dialogs belong to the human unless the standing orders delegate a
  class of them to the master. No agent answers another's dialogs.
- All three share one working tree. The sidekick writes it. The master and
  the consultant read it and its history at any time and write nothing in it
  that git does not ignore. Their builds, tests, installs, and prototypes go
  to a scratch worktree from `pair.sh scratch`, at a commit or a snapshot of
  the live state, removed when done, so they never race the sidekick's edits.
- Sidekick and consultant never message each other. Both read the store.
- Close only panes you created, and only when the human asked.
