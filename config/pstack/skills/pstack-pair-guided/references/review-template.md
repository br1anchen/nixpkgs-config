# Review NNN: <slug>

verdict: accept | revise | reject | agreed
approval: not-required | posted | human
report: <store>/reports/NNN-<slug>.md
direction: <store>/plans/NNN-<slug>.direction.md

<`approval` is set on a plan review. small: not-required. medium: posted, once
the direction summary is in your reply. large: human, only after the human
approved the direction summary. Dispatch checks it against the plan's scale.>

<`agreed` is the verdict on a plan response with status agree; it unlocks
implementation briefs that name that plan.>
head: <sha the review read>

## Amendments

<`agreed` only: objections adopted without a new round, numbered A1, A2, and
so on. Each binds every brief under this plan, and a brief cites the ones it
carries. "none" otherwise.>

## Checked

<what the master read and ran: diff ranges, commands with outcome, which
review skills were used>

## Blocking

<Only what makes the unit wrong to land: wrong behaviour, a missed consumer of
a changed value, data or schema safety, a rollback hazard, a broken contract,
a test that does not test its claim. `file:line`, what is wrong, the expected
behaviour. One per line; empty for accept. Only these make a revise. With
steps, review the report's review-delta only; the notes covered the rest.>

## Follow-ups

<Everything else worth doing, one per line: naming, docs wording, cleanups,
extra tests. They go to followups.md for a later brief or an issue and are
never a reason to revise. "none" when empty.>

## Next

<accept: what lands and how. revise: the brief number that carries these
findings. reject: why the unit is dropped.>
