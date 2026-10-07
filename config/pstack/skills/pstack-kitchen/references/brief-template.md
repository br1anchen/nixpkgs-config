# Brief {{SEQ}}: {{SLUG}}

playbook: {{one of: investigation | bug-fix | feature | refactoring | prototype | runtime-forensics | trace-forensics | perf-issue | pstack-tdd | session-pickup | pause-safely | opening-a-pr | shipping}}
timebox: {{minutes}}
commit: {{yes, one commit per step, each recorded with kitchen.sh step | no, and why}}
plan: {{path of the agreed plan under {{STORE}}/plans/; required when risk is escalated, else none}}
risk: set by kitchen.sh classify at dispatch
profiles: set by kitchen.sh classify at dispatch
verify: set by kitchen.sh classify at dispatch
standing: {{STORE}}/standing-orders.md
report: {{STORE}}/reports/{{SEQ}}-{{SLUG}}.md

## Goal

{{One sentence. The outcome, executable by a stranger with no chat access.}}

## Scope

may write:
- {{one repo-relative path or glob per line, in full (never relative to the line above); `quote` a path that contains a comma; a note may follow after " — ". The kitchen classifies the unit from these lines.}}

must not write:
- {{path or glob}}

## Steps

{{Commit-sized steps in order, fifteen to thirty minutes each. Name the files
and functions each one changes and the targeted check that proves it; the
sidekick may run on a cheaper model, so leave it no design decision the plan
did not make.}}

1. {{step}}

## Context

- {{pointers to files, commits, prior reviews or verdicts under {{STORE}}/, upstream reports pasted in full when this unit depends on them}}

## Acceptance

- {{checkable criterion, one per line; the verifier proves these and nothing else}}

## Verify

```bash
{{extra commands beyond the profiles' fast gates, which kitchen.sh step runs at
every step anyway: the targeted tests for what this unit changes, or "none"}}
```

## Forbidden

- {{unit-specific bans beyond the standing orders and the repo's policy rules}}

## Report

Work the Steps in order. End each in a commit and record it with
`kitchen.sh step {{STORE}} <sha> "<what it does>"`: it runs the touched
profiles' fast gates and the repo's policy check, and records the step only
when they pass. On a failure, fix it in a new commit and run `kitchen.sh step`
again with that commit; it tells you when two failures in a row make this a
blocked report. At each step boundary run `kitchen.sh notes {{STORE}}` and fix
any open blocking note first, as a fixup commit recorded with `--resolves`.
Append one progress line per change of approach with
`kitchen.sh progress {{STORE}} "<line>"`. When any `kitchen.sh` command prints
`PAUSE:`, stop at that safe point: commit what is verified and report
`partial` with the next step. Before reporting done, run the review skills the
kitchen's `review.self` names on your diff. Write the report file named above
using the pstack-pair report template, then run
`~/.agents/skills/pstack-kitchen/scripts/kitchen.sh finish {{STORE}} <report path>`
and do what it prints.
