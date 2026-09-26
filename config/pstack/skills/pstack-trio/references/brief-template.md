# Brief {{SEQ}}: {{SLUG}}

playbook: {{one of: investigation | bug-fix | feature | refactoring | prototype | runtime-forensics | trace-forensics | perf-issue | pstack-tdd | session-pickup | pause-safely}}
timebox: {{minutes}}
commit: {{yes, one commit per step, each recorded with pair.sh step | no, and why}}
plan: {{path of the agreed plan under {{STORE}}/plans/, or none for read-only and forensic playbooks}}
standing: {{STORE}}/standing-orders.md
report: {{STORE}}/reports/{{SEQ}}-{{SLUG}}.md

## Goal

{{One sentence. The outcome, executable by a stranger with no chat access.}}

## Scope

may write:
- {{path or glob}}

must not write:
- {{path or glob}}

## Steps

{{Commit-sized steps in order, twenty to forty-five minutes each: what
changes, the files, and the targeted check that proves it. The master reviews
each step's commit while the next one is under way.}}

1. {{step}}

## Context

- {{pointers to files, commits, prior reviews under {{STORE}}/reviews/, advice under {{STORE}}/advice/, upstream reports pasted in full when this unit depends on them}}

## Acceptance

- {{checkable criterion, one per line}}

## Verify

```bash
{{exact commands the sidekick runs and pastes output from: the targeted tests
for what this unit changes, plus the landing gate's fast checks (format,
lint, typecheck). The full test battery runs once, in the landing brief.}}
```

## Forbidden

- {{unit-specific bans beyond the standing orders}}

## Report

Work the Steps in order. End each in a commit, record it with
`pair.sh step {{STORE}} <sha> "<what it does>"`, and go straight on; do not
wait for review. At each step boundary run `pair.sh notes {{STORE}}` and fix
any open blocking note first, as a fixup commit recorded with `--resolves`.
Append one progress line per change of approach with
`pair.sh progress {{STORE}} "<line>"`. When any `pair.sh` command prints
`PAUSE:`, stop at that safe point: commit what is verified and report
`partial` with the next step. Write the report file named above using the
report template in the pstack-trio skill, then run
`~/.agents/skills/pstack-trio/scripts/pair.sh finish {{STORE}} <report path>` and do
what it prints: start the queued brief it names, in this turn, or end the turn
with the REPORT line it gives.
