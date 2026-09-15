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
   prints the ready report path. Read `reports/000-ready.md` and
   confirm branch and head match your framing before the first brief.
4. **Design and plan together.** You drive the implementation design, the
   architecture, and the system design. Before any implementation brief, run
   `architect` (parallel design exploration) and `how` over the affected
   subsystem yourself, then `pair.sh new-plan <store> <slug>` and fill the plan
   template: goal, the chosen design, the alternatives with their pros and
   cons, one step per future brief with its check, verification, risks, open
   questions. Send it with `pair.sh discuss <store> <plan>`. Exit 0 prints the
   sidekick's response. Read its Trade-offs brainstorm and its status.
   `object` means you either revise (a new plan round via `new-plan`, every
   objection answered under Disagreements resolved) or keep your position with
   the reason written there. An objection with code evidence beats your draft;
   candor beats agreement. The decision stays yours. `agree` means you write
   `reviews/NNN-<slug>.md` with verdict `agreed` and log the row. After three
   rounds without agreement, write both positions to `gates.md`, notify the
   human, and end your turn. For a bug, dispatch a diagnosis brief
   (runtime-forensics, or an investigation that reproduces and root-causes)
   before drafting the plan, so the design rests on runtime evidence.
5. **Brief.** `pair.sh new-brief <store> <unit-slug>` and fill every field.
   Name the pstack playbook the sidekick runs and put the agreed plan's path on
   the `plan:` line; dispatch refuses implementation playbooks without one.
   Put prior review findings in Context by path. A field you cannot fill is a unit you have not scoped, so
   scope it before dispatch. Dispatch refuses a brief with unfilled
   placeholders.
6. **Dispatch.** `pair.sh dispatch <store> <brief>`. Exit 0 prints the report
   path. Exit 3 means blocked: read the pane with
   `herdr agent read <name> --source visible --lines 60`, then follow the
   approval rule below. Exit 4 means the timebox passed without a report: do
   your own planning for the next unit, then `pair.sh wait <store>` again.
   Never send a second prompt to a working sidekick.
7. **Review.** Read the report, then read the diff yourself with `git diff` and
   `git log` against the head the brief recorded. Rerun the Verify commands
   while the sidekick is idle. Route through the review skills the change
   warrants: `blast-radius` for a small diff you distrust, `no-comments` before
   accepting, `interrogate` for a contested design. Write
   `reviews/NNN-<slug>.md` from the review template with one verdict. Log one
   `pair.sh log` row per verdict.
8. **Loop.** `revise` becomes the next brief with the review path in Context.
   `accept` moves to the next unit. A finding that changes the design, not
   just one unit, goes back through step 4 before the next brief. Landing (commit shaping, push, PR through
   the Opening a PR playbook) is a brief like any other, gated by the standing
   orders.
9. **Close.** When the predicate holds on the real artifact, run
   `pair.sh status <store>` and write the reply. Leave the sidekick pane open
   unless the human asked you to close it; `pair.sh stop <store>` makes it pause
   safely first. Close only panes you created.

## Approval dialogs

A blocked sidekick is waiting on a permission or question UI. Read it. If the
standing orders authorize you to answer that class of prompt, answer with
`herdr agent send-keys <name> <key>` and log it. Otherwise notify the human with
`herdr notification show "pstack-pair: sidekick needs approval" --body "<what>" --sound request`,
add a `gates.md` entry, and end your turn so the human can answer in the
sidekick pane.

## Waits and the shell timeout

Your host caps one shell call. Keep `--timeout` under that cap (the default is
nine minutes) and call `pair.sh wait` again. A wait that returns `working`
means the timeout hit, so the sidekick is still on the unit.

## Recovery

- You restarted: `pair.sh init <slug>` again re-registers your pane, then
  `pair.sh status <store>` shows both agents and the last report. Resume at the
  first brief without an accepted review.
- The sidekick is gone (`status` shows `absent`): `pair.sh spawn` again. It
  reuses the old pane when that pane is back at a shell prompt, and the sidekick
  runs session pickup from the store on bootstrap.
- A report is missing after a settled wait: the sidekick ended its turn without
  writing it. Prompt once, by hand, asking only for the report file. Read the
  pane before deciding anything else.

## Reply

Poteto-mode's reply rules apply. Include the predicate and the count against it
from `status.md`, the verdict per unit, what was abandoned and why, open gates,
the store path, and the show-me-your-work Attention section.
