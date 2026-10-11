# Handoff: {{SLUG}} (master generation {{GENERATION}})

store: {{STORE}}
written: {{WRITTEN}}

A fresh master reads this before anything else. Write it for a stranger with
no chat access: what the run is for, where every unit stands, what you
decided and why, and the next commands to run. Keep it under 150 lines; the
store holds the detail, so point at files instead of quoting them.

## Goal

{{The run's goal and its done predicate, in one or two sentences. The human's
constraints that are not already in standing-orders.md.}}

## Units

{{UNITS}}

{{Correct or annotate the table above: what each open unit is waiting on, and
which units are landed. Name any brief you drafted but did not dispatch
(scratch/unsent/).}}

## Decisions

- {{design or scope decisions made this generation, each with its reason and
  the plan, advice, verdict or steer that records it}}

## Open concerns

- {{risks, flaky gates, provider limits, human questions outstanding; or none}}

## Next

1. {{the exact next command, such as `kitchen.sh wait <store>` or
   `kitchen.sh verify <store> 012`, and what to do with its result}}
2. {{the unit after that, and whether its brief exists}}

## Pointers

- standing orders: {{STORE}}/standing-orders.md
- {{plans, briefs, verdicts, advice or notes a new master needs first}}
