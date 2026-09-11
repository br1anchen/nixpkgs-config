---
name: setup-benny
description: "Configure the bundled Benny triage and reproduction workflows for an existing event runner or scheduler. Use when installing or updating Benny."
---

# Set up Benny

Read [the runtime adapter](../pstack/references/runtime.md) and the bundled
[pack contract](../pstack/references/benny/FOR_AGENTS.md). The contract describes
the triage and reproduction intent. Its Cursor editor and automation handoff
instructions are replaced by the procedure here.

1. Identify the target repository, Slack/tracker integrations, event runner,
   authenticated agent runtime, and requested triggers. Reuse the user's
   existing configuration. Automatic external posting requires authorization.
2. Copy the pack from `pstack/references/benny` to the target repository's
   `.agents/automations/benny`. Preserve destination-only and user-owned files.
   Keep shared pstack skills installed separately.
3. Use the [configuration template](../pstack/references/benny/templates/configuration.example.yaml)
   and the operational skills' routing and feature-map examples to prepare
   secret-free configuration. Resolve available models from the active runtime.
4. Prepare separate triage and reproduction jobs from the bundled templates.
   Replace Cursor tool names using the runtime adapter. Pass workspace scope,
   thread/event identifiers, budget, permissions, and an idempotency key. Record
   processed events so retries cannot duplicate replies or PRs. Serialize jobs
   for the same issue; use isolated worktrees for independent writers.
5. Run both workflows locally on a supplied fixture or a read-only sample.
   Validate routing, missing integrations, duplicate events, and stop conditions.
   Report evidence and unresolved service configuration.
6. Activate jobs only on the user's configured runner with authorization. If no
   runner exists, leave reviewed job definitions and exact activation steps.
   Do not claim scheduled/event-driven execution exists until a real event
   reaches the runner and the expected result is observed.

The bundled operational skills are
[triage-issue-reports](../triage-issue-reports/SKILL.md) and
[reproduce-and-fix-issues](../reproduce-and-fix-issues/SKILL.md).
