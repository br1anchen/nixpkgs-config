---
name: pstack-pair-guided
description: "The guided variant of pstack-pair: two coding agents in one Herdr session, a master that designs, briefs, reviews, and decides, and a sidekick that implements, tests, and diagnoses under pstack playbooks. Adds scope-scaled human approval of a plain-language direction summary, a sidekick ask channel answered by the master or escalated to the human, and periodic check-ins with directional steers while the sidekick works. Use for /pstack-pair-guided, 'guided pair', a `pstack-pair-guided PLAN|BRIEF|ANSWER|STEER|REPORT|STOP` message, or when the human wants to approve direction before implementation. Requires HERDR_ENV=1."
---

Read [the runtime adapter](../pstack/references/runtime.md) before following this workflow. Its runtime mappings apply to all referenced playbooks and scripts.

# Pstack pair, guided

The experimental sibling of `pstack-pair`. Same store, same channel, same
roles, with two additions: the human approves direction in proportion to the
plan's scale, and the sidekick can ask the master mid-brief. Check-ins and
steers work as in `pstack-pair`; a steer is the master's counterpart to an
ask. Both skills stay installed so the two approaches can be compared; they
use separate store roots.

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
   equivalent (`--permission-mode` for Claude Code, `--permission-mode smart`
   for Devin, `-a on-request -s workspace-write` for Codex); `pair.sh permission` prints what it detected,
   and `--permission <mode>` overrides it. Kinds without a translation take
   native flags after `--`.

## Roles

| | Master | Sidekick |
| --- | --- | --- |
| Owns | plan, briefs, review, decisions, the human | the working tree, tests, diagnosis, evidence |
| Runs pstack as | poteto-mode framing, `how`, `architect`, review skills | the playbook each brief names, with its todolist |
| Writes | the pair store only | files inside the brief's Scope, plus its progress log and report |
| Speaks through | briefs, steers, reviews, standing orders, gates | progress lines, reports |

Enter your role. Master: [references/master.md](references/master.md).
Sidekick: [references/sidekick.md](references/sidekick.md).

## Pair store

`${XDG_STATE_HOME:-$HOME/.local/state}/pstack/pair/<slug>/`, created by
`pair.sh init`. One writer per file.

| Path | Writer | Content |
| --- | --- | --- |
| `pair.json` | master via `pair.sh` | agent names, pane ids, cwd, git root |
| `standing-orders.md` | master | numbered constraints pasted by path into every brief |
| `plans/NNN-<slug>.md` | master | one plan round with its `scale`, from [the plan template](references/plan-template.md) |
| `plans/NNN-<slug>.direction.md` | master | the human's plain-language summary, from [the direction template](references/direction-template.md) |
| `reports/NNN-<slug>-q<k>.md` | sidekick | ask k on unit NNN, from [the ask template](references/ask-template.md) |
| `answers/NNN-<slug>-a<k>.md` | master | the answer to ask k, from [the answer template](references/answer-template.md) |
| `briefs/NNN-<slug>.md` | master | one unit, from [the brief template](references/brief-template.md) |
| `progress/NNN-<slug>.md` | sidekick via `pair.sh progress` | one timestamped line per completed step or change of approach; a check-in shows only the lines the master has not seen |
| `steers/NNN-<slug>-s<k>.md` | master | mid-brief direction k for unit NNN, from [the steer template](references/steer-template.md); `supersedes:` names the objected steer it answers |
| `reports/NNN-<slug>-s<k>.md` | sidekick | objection to steer k, from [the steer response template](references/steer-response-template.md) |
| `reports/NNN-<slug>.md` | sidekick | evidence for brief NNN, from [the report template](references/report-template.md), or the agree/object response to plan NNN, from [the plan response template](references/plan-response-template.md) |
| `reviews/NNN-<slug>.md` | master | verdict on report NNN, from [the review template](references/review-template.md); `agreed` plus an `approval` matching the plan's scale unlocks its briefs |
| `scratch/<id>/` | master via `pair.sh scratch` | throwaway worktree at a unit's commit for rerunning its checks; removed after the review |
| `gates.md` | master | open questions for the human |
| `decisions.tsv` | master via `pair.sh log` | the show-me-your-work trail |
| `status.md` | `pair.sh status` | derived table; never hand-edited |
| `queue` | master via `pair.sh queue`; the sidekick empties it with `pair.sh next` | the next brief's path, one slot |
| `events.tsv` | every `pair.sh` command | one row per message, report, wake, and log entry, read by `pair.sh metrics` |

`NNN` is a zero-padded sequence shared by plan or brief, report, and review, so
the files for one unit sort together.

## Messages

| Prompt text | Direction | Sender's helper | Receiver's move |
| --- | --- | --- | --- |
| bootstrap (names the skill and the store) | master to sidekick | `pair.sh spawn` | bootstrap steps, `reports/000-ready.md`, reply `READY` |
| `pstack-pair-guided PLAN <plan-path>` | master to sidekick | `pair.sh discuss` | ground the plan in the code, write an agree or object response, end the turn |
| `pstack-pair-guided BRIEF <brief-path>` | master to sidekick | `pair.sh dispatch` | run the brief, write its report, run `pair.sh finish`, then start the queued brief it names or end the turn |
| `pstack-pair-guided BRIEF <brief-path>`, queued | master to a working sidekick | `pair.sh queue` | taken with `pair.sh next` right after a `done` report, in the same turn |
| `pstack-pair-guided STEER <steer-path>` | master to a working sidekick, or to one paused on an objection | `pair.sh steer` | read it on arrival, between tool calls; agree and continue, or object with evidence and end the turn |
| `pstack-pair-guided ANSWER <answer-path>` | master to sidekick | `pair.sh answer` | resume the brief with the answer applied |
| `pstack-pair-guided REPORT <report-path>` | sidekick to master | `pair.sh finish` (or `notify`) | read the report, review |
| `pstack-pair-guided STOP <store>` | master to sidekick | `pair.sh stop` | pause safely, write a stop report |

The master's `dispatch` and `wait` return when the sidekick's reply lands:
the report written since the message, or a `blocked` sidekick. A settle from
`herdr` alone is not trusted, because a Devin sidekick shows idle as a prompt
arrives and between steps; a settle with no report that holds for a minute
ends the wait with `report: missing`.
They also return when the check-in interval passes with the sidekick still
working, printing a check-in digest instead of a report path. `wait` also
returns the moment a dispatched brief's report lands, even when the sidekick
has already taken the queued brief; `running:` then names the brief it is on.
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
pstack-tdd brief whose `plan:` line does not name an agreed plan with the
approval its scale requires. Read-only
and forensic briefs need no plan; a bug's diagnosis brief runs before its plan,
so the plan rests on runtime evidence. Three rounds without agreement become a
gate for the human, with both positions in `gates.md`.

## Scale and the human's approval

Every plan carries a `scale`, and the sidekick may challenge it in discussion.

| Scale | Means | Before implementation |
| --- | --- | --- |
| small | one or two units inside one module, fully reversible | report the direction in the master's reply and proceed; review `approval: not-required` |
| medium | several units or a crossed module boundary, still reversible | write the direction summary, put it in the reply, proceed; `approval: posted` |
| large | architecture or data-shape change, new dependency, migration, anything irreversible, or three discussion rounds | write the direction summary, notify the human, end the turn, wait; `approval: human` only after the human approves |

The direction summary is plain language for a person who has not read the
code: what we are doing, the direction and why it won, the trade-offs weighed,
what the sidekick pushed back on, risks, and the exact decision requested with
its default. Write it with the `bro` skill's plainness and the unslop rules.
A standing order such as "keep going, do not wait for approvals" downgrades
large to medium for that session, per poteto-mode's session overrides.

## Asks and escalation

The sidekick gathers context freely, read-only, before and during a brief.
When an answer would change what it writes and no experiment can settle it,
it writes an ask report with status `asking` and ends its turn. The master's
wait returns with `report_status: asking`. The ladder is sidekick, then
master, then human:

- The master answers anything inside the agreed plan, the brief, and the
  standing orders, and anything an experiment can settle (run it, cite it).
- Anything that changes the design, touches a stated preference of the human,
  or is irreversible goes to the human as a `gates.md` entry with the master's
  recommendation and a default, and the master ends its turn.
- Two asks per brief. A third means the brief was under-scoped; the fix is a
  new plan round, and `pair.sh new-answer` refuses without `--force`.
- An ask that would not change the work is not sent: the sidekick proceeds
  with the default and records the assumption under Deviations.

## Check-ins and steers

The master drives the way a pairing driver does: it looks up on a cadence,
not continuously, and corrects direction, not keystrokes.

- The sidekick appends one line per completed todolist step and per change
  of approach to `progress/NNN-<slug>.md` through `pair.sh progress`. Before
  it writes outside Scope or departs from the plan, it writes the line first,
  so a check-in can catch it.
- `dispatch` and `wait` return at the check-in interval (`--every MIN`, nine
  minutes by default) when the sidekick is still working, with a digest:
  elapsed against the timebox, the progress lines not yet seen, files touched
  and which fall outside Scope, commits since dispatch, and steer counts.
  That digest is all the master reads between reports; it reads the pane only
  when the digest marks the log `STALE`.
- A steer is a mid-brief correction from the master: `pair.sh new-steer`,
  then `pair.sh steer`. It lands in the sidekick's input queue while it works;
  the harness hands it over between tool calls and the sidekick acts on it
  there, not at the end of the step. `--interrupt` cancels the running tool
  call first, for a direction that cannot wait for it. Steers carry direction: an approach
  the agreed plan did not choose, scope drift, a step to skip, a Forbidden
  line about to be crossed, or news from the human. Anything the review can
  catch at the end waits for the review.
- The sidekick agrees or objects, as with a plan. Agree: apply, acknowledge
  in the progress log, continue. Object: write the steer response with
  evidence and an alternative, notify, end the turn. The master answers with
  a steer that supersedes the objected one, revised or withdrawn, and
  `pair.sh steer` resumes the sidekick. Two rounds per steer; the decision
  stays with the master, and a standing disagreement goes to a plan round.
- Two fresh steers per brief. A third means the brief was wrong: stop the
  unit and re-brief.

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
  class of them to the master. Neither agent answers the other's dialogs.
- Both agents share one working tree. The sidekick writes it. The master
  reads it and its history at any time and edits nothing under the
  repository; it runs builds and tests only in a scratch worktree from
  `pair.sh scratch`, so they never race the sidekick's edits.
- Close only panes you created, and only when the human asked.
