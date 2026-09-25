# Master

You own judgment, never the working tree. Plan, brief, consult, review,
decide, and talk to the human. The sidekick owns every repo write. The
consultant owns the second opinion and never the decision. Bookkeeping in the
trio store is yours alone.

`pair.sh` below means `~/.agents/skills/pstack-trio/scripts/pair.sh`.

## Steps

1. **Frame.** Route the task through poteto-mode as you would alone, but stop
   before any code write. Investigation, `how`, and `architect` are yours.
   State the done predicate as something checkable and split the work into
   units that each end in a verifiable state (the sequence-verifiable-units
   principle). One unit is one brief.
2. **Open the store.** `pair.sh init <slug>` with a slug that names the task.
   Edit `standing-orders.md` so it holds every constraint the human gave you,
   including approval policy and landing policy (commit only, or push and PR).
3. **Spawn the pair.** `pair.sh spawn <store> --sidekick <kind> --consultant
   <kind>`. Use the kinds the human named. The trio needs two distinct kinds
   among the three agents; a consultant of a different kind from you is the
   point, so name one unless the human chose otherwise. When spawn exits 8,
   tell the human which kinds collided and stop; do not retry with the same
   kinds. Both agents start with your permission mode; check the `permission`
   lines the command prints and correct them with `--permission` or
   `--consultant-permission` if they are not what the human intended. Pass
   other native agent arguments after `--` only when the human asked for them;
   they reach every role spawned by that call. The command splits a pane beside
   yours for the sidekick and one below it for the consultant, bootstraps each,
   and prints both ready paths. Read `reports/000-ready.md` and
   `advice/000-ready.md` and confirm branch and head match your framing before
   the first plan.
4. **Design and plan together.** You drive the implementation design, the
   architecture, and the system design. Before any implementation brief, run
   `architect` and `how` over the affected subsystem yourself, then `pair.sh
   new-plan <store> <slug>` and fill the plan template: goal, the chosen
   design, the alternatives with their pros and cons, one step per future brief
   with its check, verification, risks, open questions. Send it with `pair.sh
   discuss <store> <plan>`. It reaches the sidekick and the consultant at once
   and returns both responses: the sidekick's report on whether the plan
   survives the code, and the consultant's advice on whether the design is
   right. Read both. Merge them: a code-grounded objection from the sidekick
   beats your draft; a design objection from the consultant deserves an answer,
   adopted or declined with the reason. Revise in a new plan round (`new-plan`,
   with every objection answered under Disagreements resolved) until the
   sidekick says agree. An objection you adopt whole, from either agent, needs
   no new round: carry it as a numbered amendment under the `agreed` review's
   Amendments, and the briefs cite it. A new round is for a changed design.
   Then write `reviews/NNN-<slug>.md` with verdict `agreed`, name the advice
   file on its `advice:` line, and if the consultant still objects, say why you
   proceed under Overruled. Log the row. After three rounds without agreement,
   write all positions to `gates.md`, notify the human, and end your turn. For
   a bug, dispatch a diagnosis brief before drafting the plan, so the design
   rests on runtime evidence; a design consult on the diagnosis report is cheap
   and often worth it.
5. **Brief.** `pair.sh new-brief <store> <unit-slug>` and fill every field. Set `commit: yes` for a unit that writes the tree, so the review and the
   next unit start from a commit, and put the landing gate's fast checks
   (format, lint, typecheck) in its Verify, so landing never fails on them. Name the pstack playbook the sidekick runs and put
   the agreed plan's path on the `plan:` line; dispatch refuses implementation
   playbooks without an agreed plan and its advice. Put prior review findings
   and advice in Context by path. A field you cannot fill is a unit you have
   not scoped, so scope it before dispatch. Dispatch refuses a brief with
   unfilled placeholders.
6. **Dispatch and check in.** `pair.sh dispatch <store> <brief> [--every MIN]`.
   Exit 0 prints the report path. Exit 3 means blocked: read the pane with
   `herdr agent read <name> --source visible --lines 60`, then follow the
   approval rule below. Exit 4 with a check-in digest means the interval passed
   and the sidekick is still working: read the digest, consult or steer or
   neither (see below), draft the next unit's brief and queue it (see
   Queueing), then `pair.sh wait <store> [--every MIN]` again. Exit 0 with
   `running:` means the sidekick already took the queued brief; review the
   finished unit while it works. Exit 4 without a digest means the sidekick
   settled without a report; see Recovery. A steer is the only message that may
   reach a working sidekick; a second brief never does, it waits in the queue.
   Any consult may run while the sidekick works.
7. **Review.** Read the report, then read the unit's commit yourself: `git show
   <head>` for the report's head, or `git diff` and `git log` from the head the
   brief recorded. Do it while the sidekick works on the queued unit. Rerun
   checks in `pair.sh scratch <store> NNN-<slug>-review --at <head>`, never in
   the shared tree: the Verify commands whose evidence under Ran you doubt and
   the one behind the riskiest claim, not the whole gate by default, since
   every run competes with the sidekick for the machine. Remove the scratch
   after the verdict. Route through the review skills the change warrants:
   `blast-radius` for a small diff you distrust, `no-comments` before
   accepting, `interrogate` for a contested design. When the verdict is
   contested in your own reading, or the unit is on its second revise, send a
   review consult and read the advice before you decide. Write
   `reviews/NNN-<slug>.md` from the review template with one verdict, the
   advice it drew on, and any overrule. Log one `pair.sh log` row per verdict.
8. **Loop.** `revise` becomes the next brief with the review path in Context;
   when the sidekick already took a queued unit, queue the revise behind it,
   and steer the running unit only when the findings invalidate it. `accept`
   moves to the next unit. A finding that changes the design, not just one
   unit, goes to a consult and then back through step 4 before the next brief.
   Landing (commit shaping, push, PR through the Opening a PR playbook) is a
   brief like any other, gated by the standing orders. Its Scope lets the
   sidekick fix mechanical gate failures (formatting, lint autofixes) and
   rerun the gate, up to twice, before it reports `failed`; a failure that
   needs judgment still comes back to you. Landing takes no consult: every
   discussion ends before it.
9. **Close.** When the predicate holds on the real artifact, run `pair.sh
   status <store>` and write the reply. An open scratch worktree in the status
   is the consultant's to remove; ask it with a design consult of one line if
   it forgot. Leave the panes open unless the human asked you to close them;
   `pair.sh stop <store>` makes both agents pause safely first. Close only
   panes you created.

## Consults

The consultant is your second opinion on file. Ask it when your review would
otherwise rest on one reading, and record what you did with the answer.

- `pair.sh new-consult <store> <NNN> --kind
  design|finding|objection|review|glance` creates
  `consults/NNN-<slug>-c<k>.md`. Fill Question, Read first, Decision this
  feeds with its default, and Constraints. Then `pair.sh consult <store>
  <path>`; it runs whether the sidekick works or not. Exit 0 prints the
  advice path and its status. Exit 3 means the consultant is blocked on a
  dialog; see Approval dialogs. Exit 4 means it settled without writing
  advice; prompt once by hand for the file only.
- A glance is optional and cheap: five minutes on the diff at a check-in,
  asking whether the review would say revise. Send one when the digest shows
  the first commit, or a sizeable diff, on a unit whose revise would cost the
  most. The consultant's quota is the scarce one; skip it on small or
  mechanical units.
- Mandatory consults: before a steer whose Direction departs from the agreed
  design (kind design); before a superseding steer after a sidekick objection
  (kind objection); before a `revise` verdict on a unit's second try (kind
  review). Everything else is your call.
- The advice is advisory. Follow it, or overrule it in the review or the
  steer's Resolved section with the reason, and log the row either way.
  `partial` advice past its timebox counts as advice; the consult's default
  applies unless the partial answer says otherwise.
- Three consults per unit. `new-consult` exits 7 on a fourth; the design is
  wrong, so go back to step 4.
- Never send the landing unit for review. Never ask the consultant to talk
  to the sidekick or the human.

## Check-ins and steers

You are the driver in the pairing sense: you look up on a cadence, not at
every keystroke. The default interval is nine minutes; pass `--every MIN` to
change it, and go no shorter than a quarter of the timebox. Between check-ins
you draft and queue the next brief, review a finished unit at its commit,
consult, or wait. You do not read the pane.

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
end; those go in the review. When the correction changes the design rather
than restores it, consult first (kind design or finding) and cite the advice
path in Direction. `pair.sh new-steer <store> <NNN>` creates the file; fill
Direction and Keep, then `pair.sh steer <store> <path>`. It returns at once.
The sidekick's harness hands the steer over between tool calls; the ack shows
in the next digest as `steer s<k> applied` or `withdrawn`. When the digest
shows a running command that must not finish, pass `--interrupt`. Log one
`pair.sh log` row per steer. Two steers per brief; a third means the brief
was wrong, so `pair.sh stop` and re-brief instead.

The sidekick may object instead. `wait` then returns `report_status: object`
with `reports/NNN-<slug>-s<k>.md`: grounding, objections with evidence and an
alternative, and the cost of applying as written. Send an objection consult
naming the steer and the objection, read the advice, then answer with a new
steer: `pair.sh new-steer <store> <NNN> --supersedes <objected steer>`, with
the revised direction and each objection answered under Resolved, citing the
advice, or `kind: withdraw`. `pair.sh steer` sends it to the paused sidekick
and waits for it to settle. Two rounds per steer; when the second still draws
an objection, withdraw it or `pair.sh stop` and take the disagreement to a
plan round. Log a row per round.

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

A blocked sidekick or consultant is waiting on a permission or question UI.
Read it. If the standing orders authorize you to answer that class of prompt,
answer with `herdr agent send-keys <name> <key>` and log it. Otherwise notify
the human with `herdr notification show "pstack-trio: <role> needs approval"
--body "<what>" --sound request`, add a `gates.md` entry, and end your turn
so the human can answer in that pane.

## Waits and the shell timeout

Your host caps one shell call. Keep `--every` under that cap (the default is
nine minutes) and call `pair.sh wait` again. A consult's timeout defaults to
fifteen minutes; pass `--timeout` under your cap when the cap is lower and
call `pair.sh advice <store> <NNN>` afterwards to find the file.

## Recovery

- You restarted: `pair.sh init <slug>` again re-registers your pane, then
  `pair.sh status <store>` shows all three agents and the last report and
  advice. Resume at the first brief without an accepted review; a
  `queued:` line in the status is yours to dispatch or clear.
- An agent is gone (`status` shows `absent`): `pair.sh spawn <store> --only
  sidekick|consultant --<role> <kind>`. It reuses the old pane when that pane
  is back at a shell prompt, and the agent runs session pickup from the store
  on bootstrap. The diversity check runs against the kinds on record.
- A report or advice is missing after a settled wait: the agent ended its
  turn without writing it. Prompt once, by hand, asking only for the file.
  Read the pane before deciding anything else.

## Reply

Poteto-mode's reply rules apply. Include the predicate and the count against
it from `status.md`, the verdict per unit, which advice was followed and
which overruled, what was abandoned and why, open gates, the store path, the `pair.sh metrics` summary, and the show-me-your-work
Attention section.
