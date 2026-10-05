# Lesson design

## Method and sources

Geoffrey Litt's [Understanding is the new bottleneck](https://www.geoffreylitt.com/2026/07/02/understanding-is-the-new-bottleneck.html)
uses explanations, quizzes, and manipulable micro-worlds to build the
understanding needed to participate in software design. Adapt that approach
here by having the learner make predictions and control small experiments,
then reconnect the observations to the repository.

Toeplitz's **genetic method**, articulated in his 1927 paper and developed in
[The Calculus: A Genetic Approach](https://nexp.pt/pdf/Toeplitz-Calculus.pdf),
motivates concepts through the problems that made them necessary. Reconstruct
a short path from a familiar attempted solution to a target-language abstraction.
This is a pedagogical reconstruction, not a claim about the language's actual
history. Use historical claims only when sourced.

Lakatos's [Proofs and Refutations, 1976](https://www.cambridge.org/core/books/abs/proofs-and-refutations/chapter-1/8BBA3959FB1D877D0453C04178B9F62D)
develops conjectures and their supporting arguments through criticism and
counterexamples. For programming lessons, make the initial rule explicit,
identify the assumption a counterexample defeats, and revise the rule or its
domain. This combined programming workflow is an adaptation of these methods.
Compiler output and successful tests do not establish universal correctness.

The two teaching skills contribute different pieces: `mattpocock-skills:teach`
supplies mission-led state, trusted resources, practice, and retention;
`pstack-teach` supplies plain explanations, real code, and incremental depth.
Avoid mandatory community enrollment or long historical investigations.

## Context before a question

Show the file and symbol, the relevant input and initial state, and any caller
or type definition needed to interpret the snippet. Usually five to fifteen
lines suffice. A standalone expression with unexplained identifiers does not.
Separate verbatim repo code from a simplified experiment or known-language
analogue. Record the commit and content hash for dirty source. Re-read the code
if the repo changed; a stale lesson may need a new version.

State the target runtime/version, pertinent imports, and whether the question
asks about parsing, type checking, runtime behavior, a library contract, or
tool configuration. Do not let omitted context create multiple valid answers.

## Multiple-choice questions

- Usually offer three or four plausible options, one correct. Explicitly label
  multi-select questions when necessary. Include a distinct hint/skip control
  rather than turning those into competing semantic answers.
- Make distractors represent identifiable misconceptions: a false friend from
  the known language, the wrong evaluation order, the wrong lifetime, or an
  incorrect API boundary. Avoid trivia, joke answers, and vague phrasing.
- Use comparable specificity, word count, formatting, and grammatical shape.
  Exact length matching is optional when it would obscure the meaning. Do not
  make the correct option consistently longer or consistently the same letter.
- Prefer neutral choice widgets when available. If a tool forces recommendation
  labels, use ordinary lettered choices or the lesson's HTML controls instead.
  A preselected radio value must still require an explicit Check submission.
- Withhold the answer until submission. Keep the answer key out of the learner's
  visible context, not just below a spoiler in the same chat message.
- Explain the actual chosen distractor after an error. Offer a discriminating
  experiment or hint and an unfamiliar retry case. Preserve the first attempt
  as evidence; retries after disclosure do not become independent successes.
- Prefer prediction, counterexample selection, rule revision, trace reasoning,
  and choosing an idiomatic patch over recognizing a definition.

## A faithful micro-world

Extract the smallest executable case that retains the decisive repo behavior.
Run the target compiler/interpreter or real library against controlled cases in
a temporary directory. For an intentionally failing case, capture the actual
diagnostic and distinguish compile-time rejection from a runtime exception.
Do not touch a live database, application state, network service, or worktree
to make an experiment feel authentic.

Offer meaningful controls such as choose input, switch implementation, step,
replay, and reset. Show state before and after, the evaluation order or trace,
and the repo consequence. An animation of an explanation with no experiment
choices is not a micro-world.

For native languages or frameworks that cannot run on a phone, pre-run a finite
set of variants in the actual pinned environment and replay their captured
results with buttons. Label this as a recorded experiment. A JavaScript model
of another language is a simulation, not that language's runtime. Label its
assumptions and verify its cases against native execution. Do not use `eval`
on learner input or silently substitute guessed outcomes when tools are absent.
If execution is unavailable, distinguish a source-supported prediction from
observed evidence and keep the runtime verification outstanding.

## Mobile delivery

Chat is sufficient for a small lesson. A prediction followed by a submitted
choice and an agent-run experiment preserves the loop without an HTML artifact.
Use HTML for useful controls, replayable traces, or several related variants.
Keep chat choices available when the client cannot display or open local HTML.
Do not require desktop terminal access, hover, dragging, or freeform code input.

For HTML, use a viewport meta tag, a single-column layout, readable text, and
clearly labeled controls with at least 44 CSS-pixel touch targets. Keep choices
stacked. Let code scroll horizontally inside its block without widening the
page. Provide visible focus, keyboard activation, and textual state/feedback
alongside color. Use an `aria-live` region for feedback. Avoid external fonts
or CDN dependencies for the learning interaction.

Reuse workspace assets for typography, choices, and trace controls. A lesson
may link local shared assets while the workspace is available. When the learner
needs a portable/offline file, bundle those same assets into a standalone HTML
copy; do not invent a separate widget implementation for the export.

Browser clicks do not automatically update agent-side files. Do not claim to
have seen answers from an HTML file unless the host exposes its events. Offer
one-tap export of a compact result record, or accept a short answer code in chat,
and reconcile it before recording learner evidence. Local storage is optional
convenience, not the canonical learning record. Keep data local unless the user
explicitly asks for a hosted or shared lesson.

## Before presenting

Run each executable variant; verify the correct option and each distractor
against its stated assumptions. Check provenance, official sources, and the
counterexample's relevance. For HTML, test the actual answer/reveal/reset flows
and a narrow viewport when a browser is available. Record checks not performed.
Present one small unit and one unanswered question, then wait.
