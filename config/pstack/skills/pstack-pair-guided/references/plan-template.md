# Plan {{SEQ}}: {{SLUG}}

round: {{1, or the previous round plus one}}
scale: {{small | medium | large}}
supersedes: {{none, or the previous plan path}}
store: {{STORE}}

## Scale

{{Why this tier. small: one or two units inside one module, fully reversible.
medium: several units or a crossed module boundary, still reversible. large:
architecture or data-shape change, new dependency, migration, anything
irreversible, or a plan that needed three discussion rounds. The sidekick may
challenge the tier in its response.}}

## Goal

{{One sentence: the behaviour change or fix, and how we will know it holds.}}

## Design

{{The master's implementation, architecture, and system design. Data shape and
organizing structure first (state machine, table, typed model, boundary, per
principle-model-the-domain), then module boundaries, interfaces, and how the
change sits in the system.}}

## Alternatives and trade-offs

{{Every option the master weighed, from architect or its own exploration. One
row per option; the chosen one marked.}}

| Option | Pros | Cons | Chosen |
| --- | --- | --- | --- |
| | | | |

{{Why the chosen option wins on these trade-offs, in two or three sentences.}}

## Steps

{{One numbered step per future brief. Each names the files it touches, the
playbook it runs, and the check that proves it, so the sequence proves itself
per principle-sequence-verifiable-units.}}

1.

## Verification

{{How the finished work is proven on the real artifact, not a proxy.}}

## Risks

{{What could break elsewhere, what is uncertain, what the timebox does not cover.}}

## Open questions

{{Questions the sidekick should answer from the code, or "none".}}

## Disagreements resolved

{{Round 2 onward: each objection from the previous response and how this round
answers it, adopted or declined with the reason. "none" in round 1.}}
