---
name: unit-testing-best-practices
description: Writes and reviews clear, resilient unit tests that verify observable behavior while remaining fast, isolated, and deterministic. Use when adding, refactoring, or reviewing unit tests, choosing test cases or doubles, improving testability, or diagnosing brittle and flaky tests in any programming language.
---

# Unit Testing Best Practices

## Goal

Write tests that provide fast, trustworthy feedback and serve as executable
documentation. Follow the repository's test framework, naming, layout, and
commands before applying these general rules.

A unit is a small observable behavior, not necessarily one function or class.
Keep tests that require a real database, network, file system, process, or
service in an integration-test suite.

## Workflow

1. Inspect the behavior contract and nearby tests before editing.
2. Select the smallest valuable cases: normal behavior, meaningful boundaries,
   invalid input, and the regression being fixed.
3. Identify inputs the test must control, including time, randomness, IDs,
   environment, locale, concurrency, and external services.
4. Write one focused Arrange-Act-Assert or Given-When-Then test per case.
5. Run the narrowest relevant test first, then the broader affected suite.

## Quality standard

Every unit test should be:

- **Fast:** cheap enough to run frequently as part of the normal feedback loop.
- **Isolated:** independent of infrastructure, global mutable state, test order,
  and other tests.
- **Repeatable:** deterministic across machines, time zones, and repeated or
  parallel runs.
- **Self-checking:** pass or fail automatically with a useful failure message.
- **Timely:** proportionate to the production behavior; difficult setup is a
  prompt to consider a narrower dependency seam or simpler design.

## Writing rules

- Name the behavior, scenario, and expected result, using local syntax. A
  failure should identify the broken contract without reading the test body.
- Keep setup minimal and make meaningful values explicit. Name unusual literals
  after the role they play; do not obscure ordinary values with needless
  constants.
- Prefer one Act per test. Multiple assertions are fine when they describe one
  coherent outcome and preserve a clear failure.
- Keep logic out of test bodies. Use framework-supported parameterized tests for
  input/output tables rather than loops, branches, or computed expectations.
- Prefer local setup or intention-revealing helpers/builders over broad shared
  setup and teardown. Do not hide behavior-relevant data in fixtures.
- Assert through the public or externally observable contract. Do not test
  private helpers directly or duplicate the production algorithm in the
  expected result.
- Introduce explicit dependency seams for nondeterministic or external inputs.
  Prefer small fakes or stubs; verify interactions with mocks only when the
  interaction itself is part of the contract.
- Use precise test-double terminology: a stub supplies controlled data, a mock
  verifies an expected interaction, and a fake is a working substitute.
- Avoid sleeps, real clocks, random values, ambient environment, and shared
  resources. Use controllable clocks, generators, schedulers, and in-memory
  substitutes.
- Assert the specific error or exception and contractually relevant details;
  avoid coupling to incidental wording, call order, or internal structure.
- Keep unit and integration tests visibly separate so their speed and dependency
  expectations remain clear.

## Language-neutral example

```text
test "discount on promotion day returns half price":
    clock = fixed_clock(PROMOTION_DAY)
    calculator = price_calculator(clock)

    actual = calculator.discounted_price(10)

    assert actual == 5
```

The controlled clock makes the contract readable and repeatable without
depending on the day the suite runs.

## Review checklist

- Would the test fail if the named behavior regressed?
- Does it verify behavior rather than implementation details or a configured
  test double?
- Can it run alone, in any order, and in parallel?
- Is the arrangement only as complex as the behavior requires?
- Are important boundaries and failure paths covered without redundant cases?
- Does each failure point to one broken contract?
- Is coverage used to find gaps rather than as proof of quality?

Adapted into language-neutral guidance from
[Microsoft's unit testing best practices](https://learn.microsoft.com/en-us/dotnet/core/testing/unit-testing-best-practices).
