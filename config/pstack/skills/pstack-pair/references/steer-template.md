# Steer {{SEQ}}-s{{K}}: {{SLUG}}

brief: {{STORE}}/briefs/{{SEQ}}-{{SLUG}}.md
supersedes: {{SUPERSEDES}}
kind: {{one of: redirect | narrow | skip-step | scope | info | withdraw}}
scope effect: {{none, or the exact "may write" or "must not write" line to add}}

## Direction

{{One or two sentences a stranger could act on: what to do differently from
here, and the plan line or evidence it rests on. Direction only: approach,
scope, priority, a step to skip, news from the human. Naming, style, and test
shape wait for the review. For kind withdraw: "continue the brief as written".}}

## Keep

{{What already done stands: "all of it", or the steps to leave as they are.}}

## Resolved

{{First round: "none". A later round: each objection from the sidekick's
response and your answer, or the reason you keep your position.}}

## Ack

Read this the moment it reaches you, between tool calls, not at the end of
the step. Agree: append
`pair.sh progress {{STORE}} "steer s{{K}} applied: <what changed>"` and continue
the brief. Object: write `{{STORE}}/reports/{{SEQ}}-{{SLUG}}-s{{K}}.md` from the
steer response template, run `pair.sh finish`, and end the turn; the master's answer arrives
as the next STEER. List this steer under Deviations in the final report.
