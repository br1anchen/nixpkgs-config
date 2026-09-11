---
name: setup-pstack
description: "Configure pstack's per-role models for the current coding agent. Use when setting up pstack or changing its model choices."
---

# Set up pstack

Read [the runtime adapter](../pstack/references/runtime.md). Identify the current
runtime key and enumerate model IDs actually supported by its delegation tool.
The presence of a CLI or model name in another runtime's config is not evidence
that this agent can dispatch it.

1. Read `~/.config/pstack/models/<runtime>.md` if it exists. Start unconfigured
   roles at `inherit-parent`. Model selection is optional.
2. Present the current roles and available models. Ask only for missing model
   preferences; apply any choices the user already provided. Explain when the
   host has no delegation or only one model. Panels then lose independence or
   model diversity respectively.
3. Validate every selected real ID against the current session's supported IDs.
   `inherit-parent` and `auto` omit a model override. A panel list determines its
   requested worker count, bounded by the host's concurrency limit.
4. Write the runtime's file atomically, preserving other runtimes' files. Use the
   role labels below. Keep credentials out of this file.
5. Read it back and report the path and effective selections. Every pstack entry
   reads this file through the adapter; no editor rule or global instructions
   rewrite is needed. When the host forbids model overrides, report that limit.

```text
feature, refactoring: inherit-parent
bug-fix: inherit-parent
perf-issue: inherit-parent
hillclimb: inherit-parent
judgment and prose: inherit-parent
hardest tasks: inherit-parent
how explorer: inherit-parent
how explainer: inherit-parent
why investigators: inherit-parent
why synthesizer: inherit-parent
reflect tooling: inherit-parent
reflect judgment, divergent, synthesizer: inherit-parent
arena runners: inherit-parent, inherit-parent, inherit-parent
arena cross-judge pool: inherit-parent
swarm workers: inherit-parent
architect runners: inherit-parent, inherit-parent, inherit-parent
interrogate reviewers: inherit-parent, inherit-parent, inherit-parent
```

Use only the number of workers warranted by the workflow. Repeated inherited
models are role-separated passes, not a diverse-model panel.
