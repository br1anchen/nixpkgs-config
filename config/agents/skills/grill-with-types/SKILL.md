---
name: grill-with-types
description: Relentlessly sharpens a plan into a type-driven design with explicit contracts, call paths, data flow, boundaries, testing seams, and file ownership. Use when a user invokes grill-with-types or wants to expose architectural and maintainability mistakes before implementation.
disable-model-invocation: true
---

# Grill with Types

Run a `/grilling` session, using `/domain-modeling` to sharpen terminology and
record qualifying glossary entries and ADRs.

Do not implement the plan until the user confirms shared understanding.
Signature-like pseudocode and structural diagrams are design artifacts, not
implementation.

## Ground the interview

- Read repository instructions, relevant code, tests, types, and call sites.
  Look up discoverable facts instead of asking the user.
- Ask one decision at a time, provide a recommended answer, and wait. The
  user owns decisions; the codebase owns facts.
- Keep and revise a working design specification after each resolved decision.
- Replace vague work items with the software shape they require.

## Type-driven design walk

Walk in dependency order; revisit earlier decisions when a later path exposes a
contradiction:

1. Define behavior, invariants, constraints, and observable failure semantics.
2. Name domain and boundary types. Make invalid states difficult or impossible
   to represent where the language permits.
3. Specify public contracts: inputs, outputs, errors, ownership, and lifecycle.
4. Trace every end-to-end call path from entry point to observable result.
5. Trace transformations, validation, persistence, side effects, and error
   propagation along each path.
6. Place boundaries and dependencies. Challenge cycles, leaky abstractions,
   duplicated policy, and interfaces without a real seam.
7. Identify production implementations and the narrow seams tests control.
8. Map each responsibility to existing files; name every file to add, modify,
   split, move, or delete.
9. Define behavioral and boundary-level integration checks against the public
   contracts.

## Maintainability pressure test

- Give every type, module, and file one owner and one reason to change.
- Inspect present responsibilities before growing a file. Split cohesive work by
  responsibility and dependency direction, showing the resulting contracts,
  callers, and file map.
- Reject speculative layers, pass-through abstractions, and broad options.
  Every boundary must hide complexity, enforce policy, or provide a real seam.

## Required design artifact

Do not approve the plan until it contains:

```text
Behavior:
  <invariants, success, and failure semantics>

Types and contracts:
  <TypeName: role and invariants>
  <Interface.operation(Input) -> Result<Output, Error>>

Call paths and data flow:
  <entry> -> <orchestrator> -> <dependency> -> <observable result>
  <input> -> <validation/transformation> -> <state or side effect>
  <error origin and propagation>

Boundaries and seams:
  <policy owner> | <production implementation> | <test substitute>

File map:
  modify <existing path>: <responsibility-level change>
  add/split/move/delete <path>: <ownership rationale>

Validation:
  <behavioral unit tests and boundary-level integration checks>
```

The artifact must make implementation a translation of reviewed decisions, not
an opportunity to invent the architecture.
