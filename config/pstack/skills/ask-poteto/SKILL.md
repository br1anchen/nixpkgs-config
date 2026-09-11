---
name: ask-poteto
description: "Recommend which pstack skill or workflow fits a situation and explain how to use it. Use for ask-poteto, pstack tutorials, choosing between skills, or learning a pstack workflow."
---

# Ask Poteto

Help the user choose a workflow. This is a guide to the installed pstack suite,
not an impersonation of its author. Advice is the default; execute a recommended
workflow only when the user asks to do the work.

1. Read [the runtime adapter](../pstack/references/runtime.md). Identify the
   user's outcome, current uncertainty, available verification, and whether
   they want advice or execution. Infer these from the conversation. Ask one
   focused question only when the answer changes the route.
2. Consult [the scenario guide](references/scenarios.md). Select the smallest
   useful route. Read the selected skill's SKILL.md, or the selected playbook
   under `poteto-mode/playbooks`, before recommending its behavior. Verify that
   dependencies are installed and required runtime tools are available.
3. Give the recommended starting skill, why it fits this situation, one copyable
   prompt in the current agent's syntax, and what evidence the user should
   expect back. Mention one next step if needed. Explain missing capabilities
   and how they change the recommendation.
4. For a tutorial request, walk through a concrete example using the guide.
   Separate observing the problem, deciding the design, doing the work, and
   proving the result. Make each step end with something the user can inspect.

Recommend `pstack` or `poteto-mode` when the user has a concrete goal and wants
execution. Recommend `create-verification-skill` when they repeatedly have to
check results manually because the agent cannot exercise the app. Do not turn
a simple factual question or tiny edit into a panel of agents.

`arena` compares competing solutions to one problem. `swarm` distributes
independent units or repeated measurements. `interrogate` challenges a concrete
artifact. `architect` develops interfaces and ownership with implementation
feedback. Explain this distinction when the user is choosing among them.

A playbook is a referenced workflow inside poteto-mode, not an installed skill.
Say `poteto-mode prototype ...` or `poteto-mode create a multi-phase plan ...`;
do not invent `/prototype`, `/planning`, `/shipping`, or `/orchestrate` commands
as part of pstack. Other plugins may independently provide those names.

Use `/ask-poteto` and `/pstack` in Claude Code and Grok Build; `$ask-poteto` and
`$pstack` in Codex; `/skill:ask-poteto` and `/skill:pstack` in Pi. If the runtime
has no skill command, ask it to read the corresponding SKILL.md by path.
