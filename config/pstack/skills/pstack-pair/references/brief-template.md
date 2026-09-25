# Brief {{SEQ}}: {{SLUG}}

playbook: {{one of: investigation | bug-fix | feature | refactoring | prototype | runtime-forensics | trace-forensics | perf-issue | pstack-tdd | session-pickup | pause-safely}}
timebox: {{minutes}}
commit: {{yes, end the unit in one commit the report names | no, and why}}
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

## Context

- {{pointers to files, commits, prior reviews under {{STORE}}/reviews/, upstream reports pasted in full when this unit depends on them}}

## Acceptance

- {{checkable criterion, one per line}}

## Verify

```bash
{{exact commands the sidekick runs and pastes output from}}
```

## Forbidden

- {{unit-specific bans beyond the standing orders}}

## Report

Append one progress line per completed todolist step and per change of
approach with `pair.sh progress {{STORE}} "<line>"`; the master reads only
that log between check-ins. Write the report file named above using the
report template in the pstack-pair
skill. End the turn with the single line `pstack-pair REPORT <path>`.
