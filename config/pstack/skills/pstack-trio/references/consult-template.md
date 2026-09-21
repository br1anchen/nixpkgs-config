# Consult {{SEQ}}-c{{K}}: {{SLUG}}

unit: {{UNIT}}
kind: {{KIND}}
timebox: {{minutes, 15 unless the question needs a build}}
advice: {{STORE}}/advice/{{SEQ}}-{{SLUG}}-c{{K}}.md
sidekick state at send: {{filled by pair.sh consult; leave as is}}

## Question

{{One question a stranger could answer from the store and the tree. Design:
which way should this go and why. Finding: a check-in, report, or diff
surfaced this; is it what it looks like and what does it change. Objection:
the sidekick objected to a steer; who is right on the evidence. Review: a
second read of this diff against the plan before a verdict.}}

## Read first

- {{paths in the store: the plan, the brief, the report, the progress log, the objection}}
- {{paths in the tree, with line ranges where known}}

## Decision this feeds

{{What the master will do with the answer: a steer, a review verdict, a new
plan round, a gate for the human. Name the default the master takes if the
advice does not arrive in the timebox.}}

## Constraints

- Read the shared tree; never write a non-ignored path in it and never build or test there.
- A prototype or a build runs in `pair.sh scratch {{STORE}} {{SEQ}}-{{SLUG}}-c{{K}}`, removed before the advice is sent.
- {{unit-specific constraints, or "none beyond the standing orders"}}

## Reply

Write the advice file named above from the advice template. Then
`pair.sh notify {{STORE}} <advice-path>` and end the turn with the single line
`pstack-trio ADVICE <path>`.
