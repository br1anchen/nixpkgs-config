---
name: defensive-code-cleaner
description: Scans code in any programming language for unnecessary null checks, impossible error handling, redundant validation, and dead catch blocks, tracing data flow to prove each defense is unneeded before flagging it. Use when asked to find unnecessary defensive code, audit defensive programming, or remove validation noise without weakening boundary safety.
---

# Defensive code cleaner

Identify defensive programming that adds complexity without protecting against a
real risk. Support every programming language in the repository. Follow each
language's actual type system, compiler or interpreter settings, error model,
and framework contracts rather than assuming TypeScript semantics.

This is a read-only review. Never apply a removal automatically. Defensive-code
cleanup has a high false-positive cost, so every finding needs a proof chain.

## What to find

1. Null, nil, `None`, missing-value, or optional checks on values proven present.
2. Exception, error, or result handling around operations proven unable to fail.
3. Validation repeated inside trusted code after an upstream boundary established
   the same invariant.
4. Empty or dead handlers that silently discard errors without an intentional
   reason.
5. Redundant boolean comparisons, default values, casts, assertions, and fallback
   branches that cannot change behavior.
6. Repeated guards made obsolete by control-flow narrowing, pattern matching,
   constructors, validated types, or earlier checks.

Do not treat these patterns as findings until the surrounding data flow proves
they are unnecessary.

## Review process

### 1. Discover the language guarantees

Before scanning, inspect the repository and affected build targets:

- Identify each language, version, compiler or interpreter, framework, and
  relevant lint or static-analysis configuration.
- Determine whether nullability, option types, exhaustiveness, checked errors,
  contracts, assertions, and unreachable-code checks are enforced.
- Read repository instructions and use the project's own tools. Prefer an AST,
  language server, compiler, linter, or analyzer over text matching when one is
  available.
- Treat generated code, unsafe features, reflection, dynamic dispatch, foreign
  function interfaces, deserialization, and unchecked casts as places where
  compile-time guarantees may not hold at runtime.

Examples of settings and models to inspect include strict nullability in
TypeScript or Kotlin, nullable annotations in Java or C#, `Option` and `Result`
in Rust, `Optional` and type-checker settings in Python, pointers and error
returns in Go, optionals and throwing functions in Swift, and pointer ownership
or exception settings in C and C++. This list is illustrative, not exhaustive.

### 2. Scan for candidate patterns

Adapt searches to the languages present. Candidate syntax often includes:

| Pattern | Examples |
|---------|----------|
| Presence checks | `x != null`, `x is not None`, `if x != nil`, optional chaining, pointer checks, matching `Some`/`None` |
| Error handling | `try`/`catch`, `try`/`except`, `do`/`catch`, ignored error returns, `match` on infallible results |
| Empty handlers | empty `catch` or `except`, ignored `Result`, blank callbacks, catch-and-return-default |
| Repeated validation | range, shape, state, type, or format checks already enforced by a caller or validated type |
| Redundant expressions | `flag == true`, fallback on a required value, a cast to the inferred type, unreachable default branch |

Text search only finds candidates. It does not prove redundancy. Avoid declaring
code unnecessary from syntax alone.

### 3. Trace data flow

For every candidate:

1. Read the declaration, type, constructor, schema, or contract that defines the
   value or operation.
2. Trace every reachable caller and producer. Record what they pass, return, or
   guarantee.
3. Check earlier guards, parsing, validation, pattern matching, and state
   transitions along each path.
4. Check framework and standard-library contracts for the exact configured
   version.
5. Identify trust boundaries such as user input, network responses, databases,
   files, environment variables, IPC, plugins, and foreign code.
6. Look for paths that bypass the claimed guarantee, including tests, reflection,
   dependency injection, unsafe casts, mutation, concurrency, and partial
   initialization.
7. Confirm that removing the defense preserves observable behavior, including
   logging, metrics, cleanup, retries, compatibility, and error translation.

A type alone is not proof when runtime data can violate it. A caller-only proof
is not enough if other callers can appear through a public API or dynamic
mechanism.

### 4. Classify the candidate

| Evidence | Verdict |
|----------|---------|
| Language and control flow prove the value is present or the operation cannot fail; all paths are trusted | Flag as unnecessary |
| The type or error model permits the checked case | Keep |
| The value comes from an external or weakly typed boundary | Keep unless validated into a trusted representation first |
| Compiler guarantees are disabled, bypassed, or contradicted by unsafe or dynamic code | Keep |
| An upstream invariant covers every reachable path and cannot be bypassed | Flag as unnecessary |
| The guard records telemetry, translates errors, performs cleanup, or documents a required assertion | Keep or report separately as intentional |
| Evidence is incomplete | Do not recommend removal; list what must be verified |

### 5. Score confidence

- **High:** The language, configured tooling, and full call graph prove the
  defense cannot affect behavior, with no external or unsafe path.
- **Medium:** Strong evidence exists, but a public, dynamic, generated, or
  boundary-adjacent path leaves a runtime assumption to verify.
- **Low:** A heuristic suggests redundancy, but the data flow is incomplete or
  crosses modules that cannot be inspected.

Only recommend removal for high-confidence findings. Medium- and low-confidence
candidates belong in a verification section, not a cleanup list.

## Quality rules

- Prove, do not guess. Show the declaration or contract, caller chain, configured
  guarantee, and absence of a bypass.
- Preserve validation at trust boundaries. Prefer parsing external data into a
  validated domain type, then remove repeated checks only inside the trusted
  region.
- Distinguish narrowing from redundancy. Type tests, pattern matches, and
  presence checks may establish the invariant used by later code.
- Distinguish assertions from guards. An assertion may intentionally fail fast
  or document a contract even when normal callers satisfy it.
- Do not assume empty handlers are wrong. Optional features, best-effort cleanup,
  probing, cancellation, and idempotent teardown may intentionally ignore an
  error, though the intent should be clear.
- Respect concurrency and mutation. A value proven valid at one point may change
  before use.
- Prefer the repository's terminology and language-specific idioms in suggested
  code.

## Report format

````markdown
## Defensive code report

**Languages and guarantee settings:** <language/tooling summary>
**Files scanned:** N
**Findings:** N high-confidence removals

### Flagged for review

| File | Line | Pattern | Confidence | Proof |
|------|------|---------|------------|-------|
| path/to/file | 42 | `<exact code>` | High | <declaration -> callers -> configured guarantee -> no bypass> |

### Verification needed

- `path/to/file:line`: <candidate and the missing evidence preventing removal>

### Intentionally kept

- `path/to/file:line`: <defense> remains because <boundary, valid failure mode,
  narrowing, side effect, or documented contract>.

### Detailed reasoning

**Finding:** `path/to/file:line`
**Declaration or contract:** <evidence>
**Callers and producers:** <evidence>
**Toolchain guarantees:** <evidence>
**Boundary and bypass check:** <evidence>
**Behavior after removal:** <why behavior is unchanged>
**Suggested removal:**

```<language>
<code after removal>
```

### Summary

N findings, M high-confidence removals, K candidates needing verification, and
J intentional defenses kept.
````

If there are no proven removals, say so. Do not inflate the report with weak
candidates.

Adapted from Jeremy Longshore's
[`defensive-code-cleaner`](https://github.com/jeremylongshore/claude-code-plugins-plus-skills/blob/main/plugins/testing/code-cleanup/agents/defensive-code-cleaner.md)
agent and rewritten as language-neutral guidance.
