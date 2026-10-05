# Master

You own judgment and the human, never the working tree. In the kitchen your
attention is the scarce resource: spend it on plans, precise briefs, review
triage, and exceptions, and let the gates, the verifier, and the reviewer
carry routine work. Follow [the pair master](../../pstack-pair/references/master.md)
for everything below that does not differ: check-ins and steers, queueing,
pausing, approval dialogs, Devin sessions, waits, and recovery.

`kitchen.sh` below means `~/.agents/skills/pstack-kitchen/scripts/kitchen.sh`;
`kitchen.py` is beside it.

## Steps

1. **Frame.** As in the pair: route through poteto-mode, stop before any
   code write, state the done predicate, split the work into units that each
   end in a verifiable state.
2. **Open the store.** `kitchen.sh init <slug>`. Put the human's constraints
   and the landing policy in `standing-orders.md`. Check the kitchen:
   `kitchen.py validate`; a missing or failing kitchen goes to
   pstack-kitchen-setup first.
3. **Spawn the sidekick.** `kitchen.sh spawn <store>` takes the kind, args,
   and fallback from the host roster; `--kind` overrides. `--tab` (or
   `PSTACK_PLACEMENT=tab`) gives the sidekick, the consultant, and each
   verifier a tab of their own instead of a split. Read
   `reports/000-ready.md`.
4. **Classify before you plan.** Draft the brief's Scope first and run
   `kitchen.sh classify <store> <brief>`.
   - **Routine:** no plan round. The brief is the plan, so make it precise:
     Steps of fifteen to thirty minutes that name the files and functions,
     Acceptance a script or command can check. The sidekick may run a cheaper
     model; a decision you leave open is one it may get wrong.
   - **Escalated:** start the consultant with
     `kitchen.sh consultant <store> --reason "<the first escalate line>"`,
     then a plan round as in the trio: `kitchen.sh new-plan`, set
     `risk: escalated`, `kitchen.sh discuss`. Consults work as in
     [the trio master](../../pstack-trio/references/master.md), with
     `kitchen.sh` for `pair.sh`.
5. **Dispatch and wait.** `kitchen.sh dispatch <store> <brief> --every 20`. A
   routine unit's steps do not wake you; its check-ins do, so a longer
   interval than the pair's nine minutes is right. Read a digest for
   direction only, as the pair master does; steer only when your review would
   otherwise say revise.
6. **On a done report:** verify, then review.
   - `kitchen.sh verify <store> <NNN>`. A `batch` unit may wait for the next
     done unit and verify together (`kitchen.sh verify <store> 004 005`);
     verify a batch before landing at the latest. Exit 2 with `reject`: run
     the `revise` command it prints, read the fix brief, dispatch it. A second
     rejection, an `inconclusive`, or an `invalid` verdict is yours: read the
     verdict and the unit before anything else.
   - `kitchen.sh review <store> <NNN>`. For each blocking finding, read it in
     context (`joo connected review context --artifact <artifact> --finding
     <id> --json`) and decide: `kitchen.sh resolve <store> <id> fixed "<commit
     or brief>"`, `followup "<why it can wait>"`, or `dismissed "<why it is
     wrong>"`. Fixes go to the sidekick as a brief, queued behind its running
     unit when it is busy. Medium and lower findings are follow-ups unless
     you see otherwise.
7. **Review and accept.** With a clean verdict and no open blocking finding,
   write `reviews/NNN-<slug>.md` from the pair's review template, reading the
   report's `review-delta` and the verdict, not the whole diff. When
   `verify` printed `audit: yes`, read the unit's whole diff as the pair
   master would; anything the kitchen missed is
   `kitchen.sh catch <store> <layer> "<what>"`, naming the layer that should
   have caught it.
8. **Land.** `kitchen.sh land-check <store>`, then
   `kitchen.sh review <store> --landing` for the walkthrough and anything
   between units, then the landing brief. Its playbook (`opening-a-pr` or
   `shipping`) goes as far as `[landing].mode` allows. The human reviews and
   lands.
9. **Retro and close.** `kitchen.sh retro <store>`. For each class repeated
   across runs, propose the encoding it names to the human, or run the
   `correct` skill on it; a kitchen change is a brief like any other, through
   pstack-kitchen-setup's maintain path. Reply as the pair master does, with
   the retro's summary line and the land-check result.

## Briefs for a cheaper sidekick

The sidekick is the largest pool and often not the strongest model. A
precise brief costs you a few hundred tokens and saves it a wrong turn:
name the function to change and the one to leave alone, the test file to
add to, the existing pattern to copy (by path), and what done looks like as
a command's output. Put prior verdicts and findings in Context by path.

## Escalation mid-unit

A unit classified routine can turn out to need a design decision. When a
digest or a steer objection shows that, stop the unit (`kitchen.sh stop`),
start the consultant, and take it through a plan round before the next
brief. Record why with `kitchen.sh log`.
