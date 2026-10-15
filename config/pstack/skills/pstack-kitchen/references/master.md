# Master

You own judgment and the human, never the working tree. In the kitchen your
attention is the scarce resource: spend it on plans, precise briefs, review
triage, and exceptions, and let the gates and the verifier carry routine
work. Follow [the pair master](../../pstack-pair/references/master.md)
for everything below that does not differ: check-ins and steers, queueing,
pausing, approval dialogs, Devin sessions, waits, and recovery.

`kitchen.sh` below means `~/.agents/skills/pstack-kitchen/scripts/kitchen.sh`;
`kitchen.py` is beside it.

## Steps

1. **Frame.** As in the pair: route through poteto-mode, stop before any
   code write, state the done predicate, split the work into units that each
   end in a verifiable state.
2. **Open the store.** `kitchen.sh init <slug>` from a fresh, MCP-free
   session (see Rotate yourself). Put the human's constraints
   and the landing policy in `standing-orders.md`. Check the kitchen:
   `kitchen.py validate`; a missing or failing kitchen goes to
   pstack-kitchen-setup first.
3. **Spawn the sidekick.** `kitchen.sh spawn <store>` takes the kind, args,
   and fallback from the host roster; `--kind` overrides. `--tab` (or
   `PSTACK_PLACEMENT=tab`) gives the sidekick, the consultant, and each
   verifier a tab of their own instead of a split. Read
   `reports/000-ready.md`.
4. **Classify before you plan.** Draft the brief's Scope first (one
   repo-relative path or glob per line, in full; dispatch refuses `a, b` on
   one line) and run `kitchen.sh classify <store> <brief>`.
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
   recorded but unsent. A Pi, Prime, or Devin sidekick whose last unit is done is
   rotated by `dispatch` or `discuss` itself (`rotated:` in its output), so
   there is no separate `rotate` call; after partial or blocked work it keeps its
   session. A log that has gone quiet is not flagged stale while a command
   the sidekick started since its last line still runs in its tree; the
   digest shows `running: <command> for Nm` instead, or `editing: last change
   Nm ago` while files or HEAD changed within the interval (activity, not
   advancement; the timebox still applies). A done report that `finish` would
   refuse (open blocking notes, a head older than the last recorded step, or
   Verify commands that have not passed at its head) does not wake you; a wait that ends on one says `written but not ready`.
6. **On a done report:** verify, then review.
   - `kitchen.sh verify <store> <NNN>`. It returns every nine minutes with
     the verifier's progress (exit 4) while the verifier works on: do other
     work, such as `kitchen.sh wait` on the sidekick, then
     `kitchen.sh verify <store> --wait` (exit 4 while it runs, 5 when none is
     open). One verification is open at a time. A partial or blocked unit can
     be verified or reviewed at the head its report names; the command notes
     it, and land-check still needs a clean verdict and an accepted review.
     A clean landing verdict counts as that verdict for every unit whose head
     its range contains (`covered:` in land-check); an inconclusive one is
     still yours to settle.
     A `batch` unit may wait for the next done unit and verify together
     (`kitchen.sh verify <store> 004 005`); verify a batch before landing at
     the latest. Exit 2 with `reject`: run the `revise` command it prints,
     read the fix brief, dispatch it, and verify the fix together with the
     unit it fixes (`kitchen.sh verify <store> 007 --covers 003`): one
     verdict at the fix's head covers both, and land-check accepts it. A
     rejected landing verdict gets one fix brief over the union of the
     units' Scopes from the same `revise`; prove it with `verify --landing`
     again. Never
     re-verify the rejected unit at its own head. A second rejection, an
     `inconclusive`, or an `invalid` verdict is yours: read the verdict and
     the unit before anything else.
   - The verifier's deadline defaults to `max(45, ceil((3 x the slowest recent
     passing behavioral gates + the last recorded `kitchen.py setup` run, when
     the repo declares setup) x min(3, max(1, load1 / cores)) / 60))` minutes;
     `verify` prints the parts (`deadline 97m: 3 x 20m gates + 10m setup, x1.38
     for load 22 on 16 cores`) and `--timeout MIN` overrides it. When it passes
     with no verdict, a live verifier is asked once to write an `inconclusive`
     one with what it proved, and given `KITCHEN_VERIFY_GRACE_S` (600 s) to do
     it; `verify` then returns exit 4 with the grace left, and
     `verify --wait` resumes the same expiry. A working Devin is not prompted
     (Enter would cancel its command) and a blocked verifier gets no grace.
   - A verifier never seen working, with nothing typed and no verdict, gets
     its packet once more (`redelivered:`). One idle for
     `KITCHEN_VERIFY_IDLE_S` (600 s) with no verdict and no process of its
     own running in its pane does not sit out the deadline: `verify` closes
     it as `stalled` and exits 4 with the command to rerun. Any attempt that
     ends without a clean or rejecting verdict prints the verifier's
     `transcript:` and whether the packet ever reached it; one that never got
     its packet says nothing about the work, so rerun it.
   - `--covers` takes one unit per flag or a comma list, and the fix is named
     last: `verify 015 --covers 010,011,013` checks out 015's head. `verify`
     refuses a head that does not contain a named unit's head, and says which.
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
     matching entry's arguments when its class names that kind.
     `verify:missing` now means the verifier ended without a verdict and
     without a provider error: read the packet and the pane.
   - The start line names the configured agent, `verifier <name> (<kind>
     <model arguments>)`, or `(<kind> (model unspecified))` when the entry
     sets no model, so you see which model proves the unit before the verdict;
     it is what the CLI was asked for. The packet records it as
     `verifier-agent:`, with `verifier-class:` and a `verifier-outcome:` the
     host updates per attempt. `kitchen.sh fleet` ends with a table by agent
     and class built from those; read it as reported outcomes on different
     workloads, not as model accuracy. `kitchen.py doctor` prints the resolved
     routine, fallback and escalated verifier and where each came from.
   - A unit is measured from its dispatch head, but never from before where
     its branch leaves trunk: a unit dispatched before a landing and then
     rebased onto the new trunk is measured from there (`verify` prints a
     `note:` when it moves the base). `--base REV` sets it by hand.
   - Review the unit's range (from the dispatch head, or the base `verify`
     used) with what the repo's owner uses: your own read, your agent's
     built-in review, or an external tool you run yourself. The kitchen runs
     none of them and reads no tool's output. When `[review].engine` is set
     (`kitchen.py validate` prints `review engine:`), the owner requires that
     engine on every unit: run it on the unit's range and add
     `engine: <name> <run id or artifact path>` under the review note's
     `head:` line, or land-check refuses the unit. For `joo`:
     `joo-dev engine review --repo <root> --range <base>..<head> --json --out <store>/scratch/joo-NNN.json`
     (or `joo`), cite that artifact path, and read its findings with
     `joo-dev connected review context --artifact <path> --json`.
     Decide each blocking finding:
     fixed (a note or a fix brief to the sidekick, queued behind its running
     unit when it is busy), a follow-up in the review note (it goes to
     `followups.md`), or dismissed with the reason. A finding that a file is
     "not in the range" may be a binary add a reviewer cannot read: check
     `git diff --name-status <base>..<head>` before dismissing it. A later
     review round, a landing review above all, can raise again what an
     earlier one settled; check the run's review notes before re-reading.
7. **Review and accept.** With a clean verdict and every blocking finding decided,
   write `reviews/NNN-<slug>.md` from the pair's review template, reading the
   report's `review-delta` and the verdict, not the whole diff. When
   `verify` printed `audit: yes`, read the unit's whole diff as the pair
   master would; anything the kitchen missed is
   `kitchen.sh catch <store> <layer> "<what>" <NNN>`, naming the layer that
   should have caught it and the unit it was in.
8. **Land.** `kitchen.sh land-check <store>`, then review the stack as a
   whole for anything between units, then the landing brief. Review it from
   where it leaves trunk (origin's default branch, else main or master), the
   base `verify --landing` prints, so a rebase never pulls trunk's commits
   into it.
   A squash or rebase step touches no profile, so before the landing brief,
   `kitchen.sh verify <store> --landing` gives the stack tip a fresh verifier
   of the escalated class: every behavioral gate the stack touches, from where it
   leaves trunk, and the main flows its briefs describe. land-check reports
   its result without requiring it. Its playbook (`opening-a-pr` or
   `shipping`) goes as far as `[landing].mode` allows. The human reviews and
   lands.
9. **Retro and close.** `kitchen.sh retro <store>`. It ends with the repo's
   lessons and the strongest candidates the ledger holds: the same trouble
   in one area across runs (a gate check failing in 3, a reject or a
   redirecting steer in 2), or a catch. Each candidate prints its arguments.
   Read its evidence; if one cause runs through it, write the rule a
   sidekick or verifier could have followed to avoid it, one sentence, and
   stage it: `kitchen.py --repo <root> lessons add <args> "<rule>"`. If the
   evidence shares no cause, dismiss it, `kitchen.py --repo <root> lessons
   dismiss <args> --note "<why>"`; it stays hidden until newer trouble of
   its kind comes back. A staged lesson is `proposed`; the human makes it
   `active` (`lessons set <id> active`). The lessons file is this run's
   change in the shared worktree: commit it on its own, as `lessons add`
   prints, so it lands with the run and no sidekick commit sweeps it up.
   Other runs see it once it lands.

   A lesson marked `(promotable)` held in 3 units with no hit. Draft its
   proposal, `kitchen.py --repo <root> lessons promote <id> --out
   <store>/promotions/<id>.md`, and fill what it leaves to you: the exact
   check, an example hunk from the evidence (before and after), the check
   failing on the evidence commit and passing on HEAD, and its hits over
   recent history. Ask the human with the file, one lesson at a time; never
   promote without a yes. On yes the check is a brief like any other (a
   kitchen.toml change through pstack-kitchen-setup's maintain path), and
   once it lands, `lessons set <id> promoted --note "<commit> <check>"`. A
   lesson hit twice while active is wrong or too weak: rewrite it with
   `lessons set <id> active --rule "<rule>"`, or retire it with a note.
   For a class already
   repeated and plain enough to enforce now, propose the encoding it names
   to the human, or run the `correct` skill on it; a kitchen change is a
   brief like any other, through pstack-kitchen-setup's maintain path. Reply as the pair master does, with
   the retro's summary line and the land-check result, and ask the human once
   whether to close the run's panes: a finished run's sidekick, consultant
   and verifier hold about a gigabyte of memory for as long as they stay
   open. On yes, `kitchen.sh close <store>` ends them and closes their
   panes; your own pane stays.

   Gaps in the kitchen itself (a command, message, default or document of
   pstack-kitchen that cost the run time or a wake) are not repo classes.
   Write them from [the feedback template](feedback-template.md) and file
   them: `kitchen.sh feedback <store> <file>`. It prints where the report
   landed and whether a maintainer session or the human was told. Repo
   classes stay with pstack-kitchen-setup's maintain path.

## Rotate yourself

Your session is the run's largest cost. Every model call re-reads all of
it, and on this host a master that served several runs re-read 500-900k
tokens per call, 27-31 calls per unit, which was 55-65% of the run's
dollars. The fix is a fresh session at a unit boundary, with a handoff in
place of the history:

- One master session per run. Never carry a session into the next run;
  start a new one, without the human's MCP servers (an MCP-free master's
  first call is about 52k tokens; one with them, about 117k), and with
  Remote Control on so the human can follow it from claude.ai or a phone:
  `claude --strict-mcp-config --mcp-config ~/.agents/skills/pstack-pair/references/no-mcp.json --remote-control <slug>-master`.
- After every `KITCHEN_MASTER_ROTATE_UNITS` (5) clean unit verdicts,
  `verify` prints `master: N units verified since your last handoff`. At
  that boundary, with no dispatch you must answer this turn:
  `kitchen.sh new-handoff <store>` writes `session-handoff.md` from
  [the template](handoff-template.md) with every unit's state filled in.
  Fill Goal, Decisions and Next, correct Units, then
  `kitchen.sh rotate-master <store>`. It starts the next generation in a
  pane beside yours (MCP-free, Remote Control on, your permission mode and
  model), points `pair.json` at it, and prompts it with the handoff. End
  your turn with no further commands, and act on no later prompt or task
  notification: the new master owns the run and closes your pane. If the
  next master does not start, `rotate-master` says so and changes nothing;
  you stay the master and rotate at a later boundary.
- `rotate-master` records the session it closes under `pair.json`
  `.master.sessions`, so a human can `claude --resume <id>` it.
  `KITCHEN_MASTER_REMOTE_CONTROL=0` starts the next master without Remote
  Control.

On `pstack-kitchen MASTER <store>`: you are that next generation. Run
`kitchen.sh take-master <store>` first: it waits briefly for the old master
to end its turn, closes its pane (and the background waits it left
running), and gives you back the run's master name. Then read
`session-handoff.md`, `standing-orders.md` and `pair.json` (the dispatch,
queue and verifying fields), then the files the handoff points at, and
continue from its Next section; run `wait` or `verify --wait` on open
dispatches and verifications. Do not re-run `init` or `spawn`; the roles
are live.

## Delegated reads

What you read stays in your context for the rest of the session, and the
reads that fill it are diffs and files for review: `git show`, `git diff`,
`sed -n`, `cat`, `Read`, a few thousand tokens each, hundreds per run. Read
directly only what you act on in this turn (a verdict's Findings, a
report's review-delta, a digest). For everything else, delegate the read to
a subagent of your harness (Claude Code: the Agent tool, Explore type) with
a bounded question and a bounded answer: "read range A..B for unit NNN
against its Acceptance; report findings as file:line and one sentence each,
at most ten; say `none` otherwise". Only the answer enters your context; the
subagent's reading is discarded with it. The same holds for an audit read
(`audit: yes`), a landing review and a consultant's prototype.

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
