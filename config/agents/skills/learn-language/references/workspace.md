# Learning workspace

Use `.learning/learn-language/<target-language>/` inside the current repo by
default. If separate goals need independent courses, add a short mission slug.
Honor an existing user-selected teaching directory. Do not overwrite a repo's
root `MISSION.md`, `NOTES.md`, reference directory, or existing tests.

Create files lazily. Learning artifacts stay untracked unless the user chooses
to version them. Do not edit ignore rules or stage files solely to hide lessons.
The agent can perform sandboxed experiments under `/tmp` and retain their code,
commands, outputs, and runtime version in the learning workspace when useful.

## Mission and preferences

`MISSION.md` should fit on one screen:

```markdown
# Mission: target language in this repository

## Why
The concrete contribution, review, or debugging task the learner wants to do.

## Starting point
- Known language and self-reported depth; separately note demonstrated skills.
- Target language, frameworks, runtime versions, and relevant repo areas.

## Success looks like
- Observable repo tasks and depth comparable to the learner's known-language work.

## Constraints
- Mobile, short sessions, choice-based input, available tools, and time budget.

## Scope
- Required ecosystem areas and any explicitly deferred topics.
```

Infer the mission from an explicit request when possible. If the motivation is
unknown, offer a concise choice such as read/review, debug/change, or build a
feature. Let the learner supply another answer. Confirm a substantive mission
change rather than silently replacing it.

`NOTES.md` holds durable preferences, pending question/variant IDs, and the exact
next interaction. Read it on resume to avoid revealing an unanswered solution.
Do not store private repo content in an external teaching service by default.

## Sources and reference

`RESOURCES.md` contains a few annotated official language, standard-library,
framework, package/build-tool, and runtime documents. Note version applicability,
retrieval date, what each source establishes, and any gaps. Prefer the repo's
pinned version over today's latest docs. Mark an unverified source as such.
Community recommendations are optional, relevant to a practical question, and
never a prerequisite for continuing a lesson.

`reference/` holds concise HTML or Markdown comparisons and a consistent
glossary. Each comparison says what transfers from the known language, what
fails, the target idiom, and its repo use. Link sources and related lessons.
Preserve each term's language/library/framework/tool scope.

## Coverage and evidence

`COVERAGE.md` maps mission needs to examples and evidence. Use a compact table:

| Area | Repo anchor | Current evidence | Next useful case |
| --- | --- | --- | --- |
| Language semantics | Relevant symbol/file | Unassessed, observed, transferred, or retained | One concept |
| Standard library | Actual API call | Evidence link | Boundary case |
| Framework/dependencies | Actual handler/module | Evidence link | Lifecycle or contract |
| Ecosystem/modules | Manifest or package boundary | Evidence link | Dependency/version case |
| Build/test/debug | Repo command or CI step | Evidence link | Diagnostic or patch choice |

Add relevant runtime, concurrency, interoperability, or performance areas as
the mission requires. Do not manufacture progress from every visited topic.
Keep authoring evidence distinct from reading/selection evidence.

`learning-records/0001-<slug>.md` records a meaningful demonstrated insight,
corrected misconception, declared prior knowledge, or confirmed mission change.
Increment the largest existing prefix. Record the concept, repo and runtime
anchor, initial conjecture, first submitted choice, observed result, revised
rule, transfer evidence, hints used, and what should be revisited. A short
paragraph plus a small evidence table is enough. Mark self-reported knowledge
as self-reported; do not score unanswered questions.

If a later experiment revises a rule, retain the old record and point to its
successor. Schedule a fresh retrieval case for the next appropriate session
and a later session. Adapt spacing to actual responses; no timer service or
automatic reminders are required. Repeated exposure or post-feedback success
is weaker evidence than a new delayed case answered without hints.

## Lessons, assets, and experiments

- `lessons/0001-<slug>.html` or `.md`: one short lesson tied to the mission.
  Record source paths/symbols, commit and dirty-content hash, relevant versions,
  the problem, known-language bridge, experiment choices, and primary sources.
- `assets/`: shared CSS and choice/trace components. Read and reuse these before
  adding another lesson. A shared stylesheet is the first HTML component.
- `experiments/0001-<slug>/`: minimal target code, fixture inputs, native outputs,
  and exact commands. Keep teaching variants separate from repo source.

Lesson and experiment numbering can share an ID. Check existing files before
assigning a number; never overwrite a prior lesson to change its answer key.
Do not create these directories until an actual lesson needs them.

## End and resume

Save the pending question, observed evidence, fragile rules, and next case.
On resume, check for changed code or tool versions, offer a short retrieval
choice for a previously learned concept, and continue at the stored point.
When the learner stops, stop. Explain progress and remaining mission gaps
without substituting a quiz score for equivalent professional expertise.
