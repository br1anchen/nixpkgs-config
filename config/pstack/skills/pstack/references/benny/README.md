# Benny reference pack

Two workflows process issue reports: triage, then reproduction and a bounded
fix when authorized. Start with the installed `setup-benny` skill and
[the intent contract](FOR_AGENTS.md).

Copy this pack into `.agents/automations/benny` in the target repository.
Preserve destination-only files and merge local changes. Keep user-owned
configuration and secrets outside the copied pack. The runner reads the
operational WORKFLOW.md files directly; they are not extra registered skills.

Use [the configuration example](templates/configuration.example.yaml),
[triage prompt](templates/triage-automation-prompt.md), and
[reproduction prompt](templates/reproduce-automation-prompt.md). A configured
event runner or scheduler supplies delivery and authentication. Verify a
harmless report and duplicate delivery before enabling production events.
