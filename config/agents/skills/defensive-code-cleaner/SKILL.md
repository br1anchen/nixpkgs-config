---
name: defensive-code-cleaner
description: Prevents and reviews unnecessary guards, nullable contracts, error paths, exports, and speculative abstractions in typed internal code across programming languages. Use when writing or reviewing defensive code, validation, fallbacks, optional values, or internal APIs.
---

# Defensive code cleaner

Validate untrusted data once, convert it to a trusted representation, then trust the language's enforced internal contracts. Apply this skill while implementing code or as a read-only review. In review mode, report findings without editing.

## Core rule

Before adding or keeping a defense, answer:

> What concrete runtime path can produce the invalid state this handles?

If no reachable path exists, do not add it. Recommend removal only when the configured toolchain and complete reachable data flow prove it unnecessary.

## Trust model

Validate at real boundaries: user input, network data, deserialization, environment variables, files, IPC, FFI, unreliable libraries, plugins, and persisted data with an uncertain schema.

```text
untrusted value -> parse and validate -> trusted typed value -> internal code
```

Inside compiler-checked code, trust non-null parameters, required fields, typed collections, enums, exhaustive matches, constructors, private functions, and values produced by validated boundaries. Do not spread uncertainty downstream through optional parameters, repeated guards, or fallback defaults.

Trust only guarantees the project enforces. Account for permissive compiler settings, dynamic dispatch, reflection, unsafe casts, generated code, mutation, concurrency, and public extension points.

## Workflow

1. **Inspect guarantees.** Identify languages, versions, compiler settings, error models, visibility rules, analyzers, and framework contracts. Prefer compilers, linters, language servers, or AST tools over text search.
2. **Find candidates.** Check guards, validation, catches, defaults, optional values, error wrappers, exports, generic helpers, switches, overloads, compatibility paths, and abstractions.
3. **Trace paths.** Read declarations, constructors, producers, and every reachable caller. Locate the claimed failure source and check for boundary, unsafe, dynamic, test, plugin, mutation, and concurrency bypasses.
4. **Check behavior.** Preserve meaningful logging, metrics, cleanup, retries, compatibility, error translation, assertions, narrowing, and failure modes.
5. **Classify.** Flag only high-confidence removals. Put incomplete proofs in "Verification needed" and state what evidence is missing.
6. **Fix the contract.** Remove impossible-state handling, move validation to the boundary, require internal parameters, narrow visibility, or replace speculative abstractions with the smallest API current callers need. If runtime behavior contradicts the type, correct the type or boundary first.

## Common findings

- null checks, optional chaining, or defaults on guaranteed values
- record, object, array, or primitive guards on already established types
- `Option`, `Optional`, `Result`, or exception handling without a real absent or failure state
- validation repeated after parsing into a trusted type
- silent early returns or catch-all handlers for impossible states
- optional parameters, switches, overloads, or generic helpers for hypothetical callers
- exported symbols with no external consumer
- assertions, casts, boolean comparisons, and fallbacks that cannot change reachable behavior

For example, after `parse(raw) -> Config` validates a boundary, prefer `build(config: Config)` over `build(config?: Config)` plus another null check.

## Language guidance

Apply the rule idiomatically. Trust strict TypeScript types after parsing `unknown`; Rust structs, enums, ownership, and visibility; enforced non-null Kotlin, Swift, Java, and C# contracts; Go types and error returns; and configured Python type checkers. For C, C++, dynamic languages, FFI, or weak compiler settings, require stronger runtime evidence before removing a guard. Never assume one language's guarantees in another.

## Valid exceptions

Keep defenses for concrete risks such as unsafe code, unchecked casts, mutable shared state, old persisted schemas, partial migrations, runtime plugins, external interface implementations, known dependency violations, documented production failures, cancellation, or best-effort cleanup. Keep the check near the uncertainty and document how the invariant can fail when the reason is not obvious.

## Review output

Report:

1. languages and enforced guarantee settings;
2. high-confidence findings with file, line, exact code, contract, caller and producer chain, bypass check, behavior impact, and suggested fix;
3. boundary or type corrections needed before cleanup;
4. medium- or low-confidence candidates under "Verification needed";
5. intentional defenses kept and the concrete risk each handles;
6. totals for findings, verification items, and retained defenses.

If nothing is proven unnecessary, say so. Do not inflate the report with syntax matches or hypothetical callers.

Default to strong types, narrow contracts, boundary validation, and simple internal code. Add a branch, nullable value, fallback, export, or abstraction only when a current runtime path or requirement needs it.

Adapted from Jeremy Longshore's [`defensive-code-cleaner`](https://github.com/jeremylongshore/claude-code-plugins-plus-skills/blob/main/plugins/testing/code-cleanup/agents/defensive-code-cleaner.md) and combined with `trust-internal-types` guidance.
