# Review NNN: <slug>

verdict: accept | revise | reject | agreed
report: <store>/reports/NNN-<slug>.md
advice: <advice files this review drew on, comma separated, or none>

<`agreed` is the verdict on a plan round whose sidekick response says agree
and whose consultant advice is on file; it unlocks implementation briefs that
name that plan.>
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

## Overruled

<Required when the verdict departs from consultant advice named above: the
advice, what it recommended, why the master decides otherwise. "none" when
the advice was followed or none was taken.>

## Next

<accept: what lands and how. revise: the brief number that carries these
findings. reject: why the unit is dropped.>
