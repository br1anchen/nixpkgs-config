---
name: grill-with-types
description: Relentlessly sharpens a plan into a type-driven design with explicit APIs, call paths, data flow, boundaries, testing seams, and file ownership before implementation. Use when a user invokes grill-with-types or wants to expose architectural and maintainability mistakes before generating code.
disable-model-invocation: true
---

# Grill with Types

Run a `/grilling` session, using `/domain-modeling` to sharpen terminology and
record qualifying glossary entries and ADRs.

Do not generate implementation code or act on the plan until the user confirms
shared understanding. Signature-like pseudocode and structural diagrams are
design artifacts, not implementation.

## Ground the interview

- Read repository instructions, relevant code, tests, types, and call sites.
- Look up discoverable facts instead of asking the user.
- Ask one decision question at a time, include a recommended answer, and wait.
- Replace vague checklist items such as "add authentication" with a description
  of the actual software shape.
- Keep a working design specification and revise it after each resolved decision.

## Walk the design in dependency order

1. Define the behavior, invariants, constraints, and failure semantics.
2. Name the important domain and boundary types; make invalid states difficult
   or impossible to represent where the language permits.
3. Specify public APIs and interface signatures, including inputs, outputs,
   errors, ownership, and lifecycle.
4. Trace each end-to-end call path from entry point through orchestration and
   dependencies to its observable result.
5. Trace data transformations, validation, persistence, side effects, and error
   propagation along those paths.
6. Place abstraction boundaries and dependencies; challenge cycles, leaky
   abstractions, duplicated policy, and interfaces with no meaningful seam.
7. Identify production implementations and the narrow seams tests will control.
8. Map responsibilities to existing files and name every file to add, modify,
   split, move, or delete.
9. Define behavioral tests and integration checks against the public contracts.

Return to an earlier decision whenever a later call path exposes a contradiction.

## Maintainability pressure test

Treat the planned code shape as seriously as the requested behavior:

- State one clear owner and reason to change for each type, module, and file.
- Inspect current file size and responsibilities, then estimate how the design
  changes both. Do not rely on a universal line-count threshold.
- Flag a file before adding code when it already mixes responsibilities, gains
  another reason to change, coordinates unrelated call paths, or accumulates
  branching that belongs behind a named abstraction.
- Propose a split by cohesive responsibility and dependency direction. Show the
  resulting types, APIs, callers, and file map; do not merely say "refactor."
- Reject needless layers, speculative interfaces, and pass-through abstractions.
  Every boundary must hide complexity, enforce policy, or provide a real seam.

## Required design artifact

Do not approve the plan until it contains:

```text
Behavior:
  <invariants, success, and failure semantics>

Types and APIs:
  <TypeName: role and invariants>
  <Interface.operation(Input) -> Result<Output, Error>>

Call paths:
  <entry> -> <orchestrator> -> <dependency> -> <observable result>

Data flow:
  <input> -> <validation/transformation> -> <state or side effect>
  <where errors originate and how they propagate>

Boundaries and seams:
  <policy owner> | <production implementation> | <test substitute>

File map:
  modify <existing path>: <responsibility-level change>
  add/split/move/delete <path>: <ownership rationale>

Validation:
  <behavioral unit tests and boundary-level integration checks>
```

The artifact should be specific enough that implementation becomes translation
of reviewed decisions rather than an opportunity to invent the architecture.
