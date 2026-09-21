# Review NNN: <slug>

verdict: accept | revise | reject | agreed
report: <store>/reports/NNN-<slug>.md
advice: <advice files this review drew on, comma separated, or none>

<`agreed` is the verdict on a plan round whose sidekick response says agree
and whose consultant advice is on file; it unlocks implementation briefs that
name that plan.>
head: <sha the review read>

## Checked

<what the master read and ran: diff ranges, commands with outcome, which
review skills were used>

## Findings

<`file:line`, what is wrong, why it matters, and the expected behaviour. One
per line. Empty for accept.>

## Overruled

<Required when the verdict departs from consultant advice named above: the
advice, what it recommended, why the master decides otherwise. "none" when
the advice was followed or none was taken.>

## Next

<accept: what lands and how. revise: the brief number that carries these
findings. reject: why the unit is dropped.>
