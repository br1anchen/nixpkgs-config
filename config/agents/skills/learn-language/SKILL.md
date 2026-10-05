---
name: learn-language
description: "Teach a new programming language through real repository snippets, comparisons with a language the learner knows, and mobile-friendly multiple-choice micro-world experiments. Use when learning a language or its libraries, frameworks, ecosystem, or build tools from the current codebase, or resuming that learning."
---

# Learn a language

Help an experienced programmer develop comparable depth in a new language and
its ecosystem. Teach the concepts needed to read, reason about, debug, build,
and change this repository. Transfer useful prior knowledge, then expose where
that prior language gives the wrong prediction. Optimize for demonstrated
understanding per minute, rather than the number of topics presented.

Combine `mattpocock-skills:teach`'s mission, sources, durable learning records,
and interactive lessons with `pstack-teach`'s code-grounded explanations and
gradual depth. This workflow uses multiple-choice quizzes, including when the
explanation skill would normally avoid them. The learner chooses; the agent
handles experiment setup, execution, and record keeping.

## Start or resume

1. Read the conversation and any existing learning workspace. Establish the
   known language and demonstrated depth, target language, and concrete repo
   goal. Ask only for missing information, using choices where possible.
   Do not assume that knowing one language implies knowing all its frameworks.
2. Inspect repo instructions, manifests, lockfiles, runtime versions, build
   scripts, tests, and representative call sites. Identify the target language
   and ecosystem actually used. If it is absent, say so and use a clearly
   labeled experiment derived from a real repo behavior, rather than inventing
   a target-language file in the repo.
3. Keep state under `.learning/learn-language/<target-language>/`, unless the
   user already chose a workspace. Read [workspace.md](references/workspace.md)
   before initializing or updating records. Reuse a matching mission; confirm
   a substantive goal change with one concise choice. Do not turn setup into
   an interview when the conversation already supplies the mission.
4. Select one useful concept just beyond demonstrated understanding. Ground
   its behavior in the pinned runtime and official language, library, or tool
   documentation. Save the source and the local evidence. Use an available
   `how` or `why` skill for a scoped flow or design question when helpful;
   otherwise inspect directly. Preserve uncertainty about historical reasons.

## Teach one small discovery

Read [lesson-design.md](references/lesson-design.md) before the first lesson,
or when changing its delivery format. It defines the genetic method,
conjecture/counterexample loop, and mobile interaction contract. See
[example.md](references/example.md) for a complete repo-grounded example.

For each concept:

1. **Problem.** Show the real repo task that needs the concept. Introduce only
   the background required to understand it. Include a short exact snippet
   with path, symbol, revision, and enough enclosing context to reason about
   inputs and effects. Label omissions and teaching changes.
2. **First model.** Use the known language to suggest a plausible solution or
   rule. Explain its useful correspondence and its semantic limits. Recreate
   the need for the target concept before naming its final abstraction.
3. **Prediction.** Ask one neutral multiple-choice question about output,
   compilation, state, a diagnostic, or a patch. Withhold the answer and the
   decisive trace until the learner submits a choice.
4. **Experiment.** Apply the chosen input or variant in a small isolated
   micro-world. Change one meaningful factor and reveal the verified result
   and the decisive execution step. Let the learner choose another experiment
   without having to type code or shell commands.
5. **Refutation.** Offer a genuine boundary case that distinguishes competing
   explanations. Ask which case would break the initial rule, or which revised
   rule survives the evidence. Diagnose the failed assumption instead of
   treating a wrong answer as a score to overcome by guessing.
6. **Transfer.** Return to the original snippet. Ask for a prediction or idiomatic
   fix on a new case. Explain why it works in the target language, including
   what cannot be translated mechanically from the known language.

Keep most lessons to one concept and roughly three to seven minutes. A lesson
can span several conversational turns; present one question per turn and wait
for an actual answer. Do not auto-answer to complete the loop. The explanation
after an answer should connect choice, observation, and rule in a few sentences.
An experiment is evidence for its tested cases, not a proof of all behavior.

## Reach the ecosystem through the repo

Maintain a small coverage map tied to the mission. Connect language semantics
to the standard library, the frameworks and dependencies in use, package and
module boundaries, runtime/concurrency behavior, and the build/test/debug loop.
Teach the corresponding manifests, versions, compiler flags, lockfiles, and CI
commands when they explain a real behavior. Distinguish a language rule from
a library contract, a framework convention, and a repo-specific policy.

Use authentic recurring problems to choose the next lesson. Do not march through
an alphabetized syntax syllabus or catalog every API. Fill important ecosystem
gaps with official examples and labeled micro-world extensions when the repo
does not exercise them. Prefer target-language idioms over literal translations.

## Keep participation easy and evidence honest

- Prefer tap-based choices in chat or HTML. Accept letters or numbers as a
  fallback. Hint, skip, repeat, easier, deeper, and stop should require little
  typing. Required assessments never demand an essay or a pasted program.
- Give the agent runnable experiment work; give the learner predictions,
  counterexample selection, trace navigation, and patch choices. Do not modify
  production source, commit, install a toolchain, or publish a lesson merely
  because a learning experiment would benefit from it.
- A selected default is not an answer. Do not label an assessment option
  recommended. Wait for a submitted selection before revealing feedback.
- Record observations, not flattering mastery claims. Separate an immediate
  correct choice from independent transfer and later retention. Revisit fragile
  concepts with new cases in later sessions, and interleave related practiced
  concepts once each has a clear initial explanation.
- Track reading, semantic reasoning, idiom selection, debugging/tool use, and
  unaided authorship separately. Multiple-choice evidence can establish depth
  in the former skills; do not claim writing fluency from recognition alone.
  Offer an optional desktop writing exercise when it serves the mission.

At a stopping point, save the learner's response evidence and next experiment.
Offer a short choice of continue, explore a related case, or stop. Show progress
against the concrete mission without promising a fixed time to equal expertise.
