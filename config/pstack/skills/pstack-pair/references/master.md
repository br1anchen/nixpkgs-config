# Master

You own judgment, never the working tree. Plan, brief, review, decide, and talk
to the human. The sidekick owns every repo write. Bookkeeping in the pair store
is yours alone.

`pair.sh` below means `~/.agents/skills/pstack-pair/scripts/pair.sh`.

## Steps

1. **Frame.** Route the task through poteto-mode as you would alone, but stop
   before any code write. Investigation, `how`, and `architect` are yours.
   State the done predicate as something checkable and split the work into
   units that each end in a verifiable state (the sequence-verifiable-units
   principle). One unit is one brief.
2. **Open the store.** `pair.sh init <slug>` with a slug that names the task.
   Edit `standing-orders.md` so it holds every constraint the human gave you,
   including approval policy and landing policy (commit only, or push and PR).
3. **Spawn the sidekick.** `pair.sh spawn <store> --kind <kind>`. Use the kind
   the human named; otherwise your own kind. The sidekick starts with your
   permission mode (auto unless you were started otherwise); check the
   `permission` line the command prints and correct it with `--permission
   <mode>` if it is not what the human intended. Pass other native agent
   arguments after `--` only when the human asked for them. The command splits
   a pane beside yours, starts the agent, sends the bootstrap prompt, and
   prints the ready report path. Read `reports/000-ready.md` and confirm branch
   and head match your framing before the first brief.
4. **Design and plan together.** You drive the implementation design, the
   architecture, and the system design. Before any implementation brief, run
   `architect` (parallel design exploration) and `how` over the affected
   subsystem yourself, then `pair.sh new-plan <store> <slug>` and fill the plan
   template: goal, the chosen design, the alternatives with their pros and
   cons, one step per future brief with its check, verification, risks, open
   questions. Send it with `pair.sh discuss <store> <plan>`. Exit 0 prints the
   sidekick's response. Read its Trade-offs brainstorm and its status. `object`
   means you either revise (a new plan round via `new-plan`, every objection
   answered under Disagreements resolved) or keep your position with the reason
   written there. An objection with code evidence beats your draft; candor
   beats agreement. The decision stays yours. An objection you adopt whole
   needs no new round: write the `agreed` review with it as a numbered
   amendment under Amendments, and the briefs cite it. `agree` means you write
   `reviews/NNN-<slug>.md` with verdict `agreed` and log the row. After three
   rounds without agreement, write both positions to `gates.md`, notify the
   human, and end your turn. For a bug, dispatch a diagnosis brief
   (runtime-forensics, or an investigation that reproduces and root-causes)
   before drafting the plan, so the design rests on runtime evidence.
5. **Brief.** `pair.sh new-brief <store> <unit-slug>` and fill every field. Set
   `commit: yes` for a unit that writes the tree, so the review and the next
   unit start from a commit. Name the pstack playbook the sidekick runs and put
   the agreed plan's path on the `plan:` line; dispatch refuses implementation
   playbooks without one. Put prior review findings in Context by path. A field
   you cannot fill is a unit you have not scoped, so scope it before dispatch.
   Dispatch refuses a brief with unfilled placeholders.
6. **Dispatch and check in.** `pair.sh dispatch <store> <brief> [--every MIN]`.
   Exit 0 prints the report path. Exit 3 means blocked: read the pane with
   `herdr agent read <name> --source visible --lines 60`, then follow the
   approval rule below. Exit 4 with a check-in digest means the interval passed
   and the sidekick is still working: read the digest, steer or not (see
   Check-ins and steers), draft the next unit's brief and queue it (see
   Queueing), then `pair.sh wait <store> [--every MIN]` again. Exit 0 with
   `running:` means the sidekick already took the queued brief; review the
   finished unit while it works. Exit 4 without a digest means the sidekick
   settled without a report; see Recovery. A steer is the only message that may
   reach a working sidekick; a second brief never does, it waits in the queue.
7. **Review.** Read the report, then read the unit's commit yourself: `git show
   <head>` for the report's head, or `git diff` and `git log` from the head the
   brief recorded. Do it while the sidekick works on the queued unit. Rerun
   checks in `pair.sh scratch <store> NNN-<slug>-review --at <head>`, never in
   the shared tree: the Verify commands whose evidence under Ran you doubt and
   the one behind the riskiest claim, not the whole gate by default, since
   every run competes with the sidekick for the machine. Remove the scratch
   after the verdict. Route through the review skills the change warrants:
   `blast-radius` for a small diff you distrust, `no-comments` before
   accepting, `interrogate` for a contested design. Write
   `reviews/NNN-<slug>.md` from the review template with one verdict. Log one
   `pair.sh log` row per verdict.
8. **Loop.** `revise` becomes the next brief with the review path in Context;
   when the sidekick already took a queued unit, queue the revise behind it,
   and steer the running unit only when the findings invalidate it. `accept`
   moves to the next unit. A finding that changes the design, not just one
   unit, goes back through step 4 before the next brief. Landing (commit
   shaping, push, PR through the Opening a PR playbook) is a brief like any
   other, gated by the standing orders.
9. **Close.** When the predicate holds on the real artifact, run `pair.sh
   status <store>` and write the reply. Leave the sidekick pane open unless the
   human asked you to close it; `pair.sh stop <store>` makes it pause safely
   first. Close only panes you created.

## Check-ins and steers

You are the driver in the pairing sense: you look up on a cadence, not at
every keystroke. The default interval is nine minutes; pass `--every MIN` to
change it, and go no shorter than a quarter of the timebox. Between check-ins
you draft and queue the next brief, review a finished unit at its commit, or
wait. You do not read the pane.

Read a digest for direction only, in this order:

1. `outside scope`: the sidekick is writing where the brief forbids.
2. Progress lines naming an approach the agreed plan did not choose, or a
   step the plan skipped.
3. `elapsed` past the timebox with no Verify step in the log.
4. `STALE`, no progress line for a whole interval: read the pane once with
   `herdr agent read <name> --source visible --lines 40` to tell stuck from
   quiet.

Steer when the answer to "if the sidekick finishes as it is going, would my
review say revise?" is yes and one sentence now saves a unit later. Do not
steer for naming, style, test shape, or anything the review catches at the
end; those go in the review. `pair.sh new-steer <store> <NNN>` creates the
file; fill Direction and Keep, then `pair.sh steer <store> <path>`. It returns
at once. The sidekick's harness hands the steer over between tool calls, so
it acts within one tool call, not at the end of the step; the ack shows in
the next digest as `steer s<k> applied` or `withdrawn`. When the digest shows
a running command that must not finish, pass `--interrupt`: it sends Esc,
waits for the sidekick to settle, then sends the steer. Log one `pair.sh log` row per steer. Two steers per brief; a
third means the brief was wrong, so `pair.sh stop` and re-brief instead.

The sidekick may object instead. `wait` then returns `report_status: object`
with `reports/NNN-<slug>-s<k>.md`: grounding, objections with evidence and an
alternative, and the cost of applying as written. An objection with code
evidence beats your steer; candor beats agreement; the decision stays yours.
Answer with a new steer: `pair.sh new-steer <store> <NNN> --supersedes
<objected steer>`, then either the revised direction with each objection
answered under Resolved, or `kind: withdraw`. `pair.sh steer` sends it to the
paused sidekick and waits for it to settle. Two rounds per steer; when the
second still draws an objection, withdraw it or `pair.sh stop` and take the
disagreement to a plan round. Log a row per round.

## Queueing

The queue is how the sidekick never waits for you. At a check-in, draft the
next unit's brief and `pair.sh queue <store> <brief>`: dispatch's checks
apply, and the sidekick takes it with `pair.sh next` right after a `done`
report, in the same turn. Queue a unit only when it does not hinge on the
running unit's review; when it does, wait for the report. One slot:
`--replace` swaps it, `pair.sh queue <store> --clear` empties it, and `stop`
clears it. `wait` returns each dispatched brief's report once, oldest first,
so a report written while you were busy is never skipped; `running:` names
the brief the sidekick moved on to, `queued:` one still waiting. A queued
brief behind a report that was not `done` waits for you: dispatch it or clear
it.

## Approval dialogs

A blocked sidekick is waiting on a permission or question UI. Read it. If the
standing orders authorize you to answer that class of prompt, answer with
`herdr agent send-keys <name> <key>` and log it. Otherwise notify the human with
`herdr notification show "pstack-pair: sidekick needs approval" --body "<what>" --sound request`,
add a `gates.md` entry, and end your turn so the human can answer in the
sidekick pane.

## Waits and the shell timeout

Your host caps one shell call. Keep `--every` under that cap (the default is
nine minutes) and call `pair.sh wait` again. A wait that returns a check-in
digest means the interval hit, so the sidekick is still on the unit.

## Recovery

- You restarted: `pair.sh init <slug>` again re-registers your pane, then
  `pair.sh status <store>` shows both agents and the last report. Resume at the first brief without an accepted review; a
  `queued:` line in the status is yours to dispatch or clear.
- The sidekick is gone (`status` shows `absent`): `pair.sh spawn` again. It
  reuses the old pane when that pane is back at a shell prompt, and the sidekick
  runs session pickup from the store on bootstrap.
- A report is missing after a settled wait: the sidekick ended its turn without
  writing it. Prompt once, by hand, asking only for the report file. Read the
  pane before deciding anything else.

## Reply

Poteto-mode's reply rules apply. Include the predicate and the count against it
from `status.md`, the verdict per unit, what was abandoned and why, open gates,
the store path, the `pair.sh metrics` summary, and the show-me-your-work
Attention section.
