# Pstack scenario guide

This guide uses the installed skills and playbooks as its executable source of
truth. Prompts below use Claude/Grok syntax. In Codex replace `/skill-name` with
`$skill-name`; in Pi use `/skill:skill-name`. Plain requests to use a named skill
also work when the host supports discovery.

## What the two articles contribute

Lauren's [Part 1](https://x.com/poteto/status/2094457600259842065) argues for
investing in an agent-operated verification interface and a feature map before
scaling delegation. Her [Part 2](https://x.com/poteto/status/2097732320606507506)
then connects investigation, explanations, runnable prototypes, and architecture
to that verification foundation. These are engineering practices, not a promise
of a particular productivity multiplier.

X returned 403 during this review on 2026-09-10. The author's article text was
read through [Part 1's mirror](https://threadnavigator.com/thread/2094457600259842065/)
and [Part 2's mirror](https://threadnavigator.com/thread/2097732320606507506/).
The examples below are new prompts grounded in the MIT-licensed
[pstack source and guide](https://github.com/cursor/plugins/tree/7366ac128bdf95f45e6734f412b49a4031800169/pstack/docs/guide).
They adapt its workflows to this installation.

## Start with one feature you can prove

Suppose an export operation occasionally duplicates records after a retry.

1. Establish the verification route. If the project already has a reliable CLI,
   integration test, or app-driving skill, use it. Otherwise ask:

   ```text
   /create-verification-skill for this app. Cover creating an export, interrupting
   it, retrying it, and inspecting the resulting records. Use existing tooling.
   Include setup, reset, a feature map, and machine-readable evidence.
   ```

   Inspect the generated commands and run one known-good path. A Markdown
   promise of verification is insufficient; there must be an executable check.

2. Confirm the problem before choosing a fix:

   ```text
   /poteto-mode investigate the duplicate-export report. Restate the user's
   failure in plain English, reproduce it, and show the relevant execution path.
   Keep this pass read-only. Separate observed facts from hypotheses.
   ```

   Expect reproduction steps, a failing result, and file references. If the
   issue cannot be reproduced, expect the missing conditions, not a guessed fix.

3. Once the cause is established, give a bounded implementation task:

   ```text
   /pstack fix the confirmed export retry defect. A retried export must contain
   each source record exactly once. Preserve cancellation behavior. Use the
   existing verification commands and show before/after output. Do not merge.
   ```

   Expect the focused diff, verification output, and any unverified behavior.
   Use `pstack-tdd` explicitly when a cheap regression test can capture it.

4. If the UI or commands changed, run `maintain-verification-skill` so future
   agents can still reach and verify the feature.

## Choose by what is missing

| Situation | Starting route | Inspect before moving on |
| --- | --- | --- |
| Agent cannot exercise the app | `create-verification-skill` | Working control commands and feature map |
| Verification has drifted | `maintain-verification-skill` | Commands checked against current features |
| You need the execution path | `how` | Concrete call path and ownership |
| You need the reason behind a choice | `why` | Historical evidence, with uncertainty stated |
| You need a understandable explanation | `pstack-teach` | Mechanics, rationale, and tradeoffs |
| You are resuming recent work | `recall` | Scoped history checked against current git/PR state |
| Bug with unknown cause | `poteto-mode` investigation or bug-fix playbook | Reproduction and competing hypotheses |
| Known behavior to implement | `pstack` feature playbook | Checkable outcome and real verification |
| New interface or ownership boundary | `architect` | Caller sketch, types, candidates, rationale |
| Several plausible implementations | `arena` | Independent candidates, rubric, synthesis |
| Uncertain UI or runtime behavior | `poteto-mode` prototype playbook | Runnable variants and observed differences |
| Many independent files or cases | `swarm` | Per-unit outputs and an aggregated result |
| Concrete diff or design needs challenge | `interrogate` | Evidence-backed findings and disposition |
| Change may affect distant callers | `blast-radius` | Reachable consumers and regression risks |
| A metric must improve | `poteto-mode` perf or hillclimb playbook | Baseline, repeated measurements, retained wins |
| Migration spans several PRs | `poteto-mode` multi-phase-plan playbook | Ordered units, each with its own proof |
| Large task fits no playbook | `figure-it-out` | A bounded, auditable procedure |
| PR needs CI/review follow-up | `poteto-mode` babysit playbook | Current head, checks, review resolution |
| Overnight or multi-session work | `poteto-mode` autonomous-run playbook | Stop condition, resumable state, decision trail |
| Standing project with multiple tracks | `poteto-mode` orchestrate playbook | Ownership, isolated workers, verified frontier |
| Repeated incoming issue reports | `setup-benny` after verification works | Tested runner configuration and event handling |

## New API or subsystem

Start from what a caller should be able to do:

```text
/architect a rate limiter for our webhook handler. Ground the current request
path first. Show caller code, core types, and failure semantics. Use a small
prototype to answer timing questions. Stop at a reviewable design before
changing production behavior.
```

Use `arena` directly when you want competing answers to one well-framed problem.
Use `interrogate` after an artifact exists and there are concrete claims to test.
When a host offers only one model, keep the role-separated passes but expect
less model diversity. With no delegation, ask for sequential comparison and
record that it is not independent review.

## UI decision

```text
/poteto-mode prototype two ways to show a stalled export. Exercise keyboard
navigation and retry in both. Show recordings or screenshots plus observed
behavior. Keep prototypes disposable; do not integrate a winner yet.
```

The screenshot documents appearance. The interaction proves behavior. If the
host lacks UI control, that part remains a manual check.

## Performance work

```text
/poteto-mode reduce export startup latency. Measure the current version with
fixed input and warmup rules. Identify the dominant cost before editing. Compare
repeated before/after runs and report the distribution, not just the fastest run.
```

`swarm` can spread independent samples across available workers. Keep environment
and load comparable so parallel execution does not invalidate the measurement.
Use the hillclimb playbook for sustained improvement against an explicit target.

## Migration and overnight work

```text
/poteto-mode turn the accepted export API design into a multi-PR migration.
Migrate callers in dependency order. Every PR must have a runnable acceptance
check. Preserve existing behavior and leave each commit buildable. Prepare PRs
for review; do not merge them.
```

Once the plan and verification are usable:

```text
/poteto-mode execute the agreed migration until all acceptance checks pass or
a required external dependency blocks progress. Record decisions and exact
resume steps. Keep each writer isolated and respect the session's worker limit.
```

This does not create a scheduler. Local agents may stop when their session ends.
A real scheduled or remote runner is separate configuration. Ask for it only
when recurrence or independent execution is part of your intended task.

## Keep the request small

For ordinary work, provide the outcome, constraints, and how to recognize
success. Let `poteto-mode` select its playbook. Name leaf skills when you want a
particular result, such as an explanation or a comparison, rather than the full
implementation workflow. Use `ask-poteto` when you want help choosing.
