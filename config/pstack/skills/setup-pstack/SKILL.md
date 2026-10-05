---
name: setup-pstack
description: "Configure pstack's per-role models and reasoning budget for the current coding agent. Use when setting up pstack or changing its model choices or reasoning budget."
---

# Set up pstack

Read [the runtime adapter](../pstack/references/runtime.md). Identify the current
runtime key and enumerate model IDs actually supported by its delegation tool.
The presence of a CLI or model name in another runtime's config is not evidence
that this agent can dispatch it.

1. Read `~/.config/pstack/models/<runtime>.md` if it exists. Start unconfigured
   roles at `inherit-parent`. Model selection is optional. Preserve configured
   model families, panel lists, and aliases; drop retired role labels absent
   from the table below and report which labels were dropped.
2. Offer the current budget and four choices through the host
   question tool: `unlimited — keep max`, `large — xhigh reasoning`,
   `medium — high reasoning`, and `small — medium reasoning`. Apply any
   preference the user already supplied. An absent budget preserves existing
   settings until the user chooses. Apply the selected budget as described
   below, then present the current roles and available models. Ask only for
   missing model preferences; apply any choices the user already provided. Explain when the
   host has no delegation or only one model. Panels then lose independence or
   model diversity respectively.
3. Validate every selected real ID against the current session's supported IDs.
   `inherit-parent` and `auto` omit a model override. A panel list determines its
   requested worker count, bounded by the host's concurrency limit.
4. Write the runtime's file atomically, preserving other runtimes' files. Use the
   role labels below and record the chosen budget and target effort as a
   comment. Keep credentials out of this file.
5. Read it back and report the path and effective selections. Every pstack entry
   reads this file through the adapter; no editor rule or global instructions
   rewrite is needed. When the host forbids model overrides, report that limit.

```text
# budget: unlimited (preserve configured efforts)
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

## Apply the reasoning budget

`unlimited` leaves the configured efforts unchanged. `large`, `medium`, and
`small` target `xhigh`, `high`, and `medium` respectively, for every real model
entry, including panels. `inherit-parent` and `auto` stay unchanged. A budget
alone does not authorize changing the parent session's model or reasoning.

Use the host's actual schema. If reasoning is encoded in supported model IDs,
replace the effort token (the final token, or the token before trailing `fast`)
only when the resulting ID is available. Otherwise select a supported ID in the
same family with the highest effort at or below the target, or ask for a model
choice. Never invent a slug or silently switch families. If the host exposes
a separate reasoning parameter, retain the ID and record the supported effort
next to it, for example `swarm workers: <supported-id> (reasoning: high)`. If
there is no effort control, preserve the model and report that limitation.

Re-running setup preserves user choices of family, panel size, and aliases.
Show the effective role table and any unsupported budget choices before writing.
