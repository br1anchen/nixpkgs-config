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
5. **Dispatch and wait.** `kitchen.sh dispatch <store> <brief>`, then
   `kitchen.sh wait <store>`, each in your harness's background mode where it
   has one (Claude Code: run in the background and you are re-invoked when it
   returns), so a wait never holds your turn. The kitchen's wait is quiet: a
   check-in with nothing flagged does not return. It returns for a report, an
   escalated unit's steps, a blocked sidekick, a digest that carries a flag
   (a stale log, a write outside Scope, an objection, an open blocking note,
   a timebox overrun, a pause), or after `--max` minutes (an hour) with the
   latest digest. Read a digest for direction only, as the pair master does;
   steer only when your review would otherwise say revise. Never wrap
   `dispatch` in a short `timeout`: when you need the call back at once, pass
   `--send-only`, which returns as soon as the brief is delivered, then wait.
   Delivery itself ignores TERM, so a killed dispatch never leaves a brief
   recorded but unsent. A pi or Devin sidekick whose last unit is done is
   rotated by `dispatch` itself (`rotated:` in its output), so there is no
   separate `rotate` call; after partial or blocked work it keeps its
   session. A log that has gone quiet is not flagged stale while a command
   the sidekick started since its last line still runs in its tree; the
   digest shows `running: <command> for Nm` instead.
6. **On a done report:** verify, then review.
   - `kitchen.sh verify <store> <NNN>`. It returns every nine minutes with
     the verifier's progress (exit 4) while the verifier works on: do other
     work, such as `kitchen.sh wait` on the sidekick, then
     `kitchen.sh verify <store> --wait` (exit 4 while it runs, 5 when none is
     open). One verification is open at a time. A partial or blocked unit can
     be verified or reviewed at the head its report names; the command notes
     it, and land-check still needs a clean verdict and an accepted review.
     A `batch` unit may wait for the next done unit and verify together
     (`kitchen.sh verify <store> 004 005`); verify a batch before landing at
     the latest. Exit 2 with `reject`: run the `revise` command it prints,
     read the fix brief, dispatch it, and verify the fix together with the
     unit it fixes (`kitchen.sh verify <store> 007 --covers 003`): one
     verdict at the fix's head covers both, and land-check accepts it. Never
     re-verify the rejected unit at its own head. A second rejection, an
     `inconclusive`, or an `invalid` verdict is yours: read the verdict and
     the unit before anything else.
   - The verifier's deadline defaults to three times the slowest recent
     passing run of the unit's behavioral gates (`kitchen.py timing`), and
     never less than 45 minutes; `--timeout MIN` overrides it.
   - A verifier that hits its provider (a rate limit, an outage) writes no
     verdict. `verify` reports `inconclusive` with the provider's error,
     including when the limit resets, and a routine unit verifies again on
     the verifier's fallback in the same call (the roster's
     `[verifier.fallback]`, else the sidekick's), once, and only when the
     fallback is a different kind from the one that failed. Escalated units
     have no fallback by default. The verifier comes from the host roster's
     `[verifier]` (routine, default the current sidekick) or
     `[verifier.escalated]` (default Claude Opus); the repo no longer
     chooses. `--kind KIND` picks the verifier's kind yourself, with the
     matching entry's arguments when its class names that kind. `verify:missing` now means the verifier
     ended without a verdict and without a provider error: read the packet
     and the pane.
   - A unit is measured from its dispatch head, but never from before where
     its branch leaves trunk: a unit dispatched before a landing and then
     rebased onto the new trunk is measured from there (`verify` and
     `review` print a `note:` when they move the base). `--base REV` sets it
     by hand on either.
   - `kitchen.sh review <store> <NNN>`. For each blocking finding, read it in
     context (`joo connected review context --artifact <artifact> --finding
     <id> --json`) and decide: `kitchen.sh resolve <store> <id> fixed "<commit
     or brief>"`, `followup "<why it can wait>"`, or `dismissed "<why it is
     wrong>"`. Fixes go to the sidekick as a brief, queued behind its running
     unit when it is busy. Medium and lower findings are follow-ups unless
     you see otherwise. To read an artifact yourself, read `.findings[]`
     only: the blocking ones are `.findings[] | select((.severity ==
     "critical" or .severity == "high") and .status == "actionable")`, the
     filter `review` uses. A re-review of the same unit (`-r2`) replaces the
     round before it: land-check counts only the latest round's findings. `notes[].comments[]` holds the reviewers' raw
     comments before triage, including ones triage dropped, so a recursive
     `jq '..'` over the file reports findings that are not there.
7. **Review and accept.** With a clean verdict and no open blocking finding,
   write `reviews/NNN-<slug>.md` from the pair's review template, reading the
   report's `review-delta` and the verdict, not the whole diff. When
   `verify` printed `audit: yes`, read the unit's whole diff as the pair
   master would; anything the kitchen missed is
   `kitchen.sh catch <store> <layer> "<what>"`, naming the layer that should
   have caught it.
8. **Land.** `kitchen.sh land-check <store>`, then
   `kitchen.sh review <store> --landing` for the walkthrough and anything
   between units, then the landing brief. The landing review covers the stack
   from where it leaves trunk (origin's default branch, else main or master),
   so a rebase never pulls trunk's commits into it; `--base <rev>` overrides.
   A squash or rebase step touches no profile, so before the landing brief,
   `kitchen.sh verify <store> --landing` gives the stack tip a fresh verifier
   of the escalated class: every behavioral gate the stack touches, from where it
   leaves trunk, and the main flows its briefs describe. land-check reports
   its result without requiring it. Its playbook (`opening-a-pr` or
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

## Reports and bookkeeping

`finish` refuses a done report without its `head:`, so a malformed report is
fixed in the sidekick's own turn, not by a brief. When a report must still
change after the fact, a brief whose Scope lists only store files is
bookkeeping: `classify` keeps it routine and gates-only, and it escalates
nothing. Prefer `--covers` over a brief that rewrites a report to say a later
unit met its acceptance.

## Escalation mid-unit

A unit classified routine can turn out to need a design decision. When a
digest or a steer objection shows that, stop the unit (`kitchen.sh stop`),
start the consultant, and take it through a plan round before the next
brief. Record why with `kitchen.sh log`.
