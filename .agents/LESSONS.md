# Kitchen lessons

Rules learned from trouble that repeated in one area across kitchen runs.
`kitchen.py lessons` proposes them from the run ledger, the master writes each
rule, and the human approves every promotion into a check or a standard.
How often each held or recurred is counted on the host, not here.

## L001: A test that waits for a condition polls in a bounded loop marked kitchen-allow: test-sleep with a reason, never another blocking call that slips past the rule.

status: proposed
kind: catch
class: policy
layer: policy
area: config/pstack
since: 2026-10-16
evidence:
- 2026-10-16 kitchen-perf 011: test-sleep rule misses threading.Event().wait polls; a sidekick used it to sidestep the rule instead of kitchen-allow

## L002: When Acceptance counts rows per return, test the exact rows added on every entry point that can return (dispatch, wait, verify, retry), taking before first.

status: proposed
kind: catch
class: verify
layer: verify
area: config/pstack
since: 2026-10-16
evidence:
- 2026-10-16 kitchen-perf 002: kitchen.sh dispatch logs a checkin wake for a swallowed first check-in (core_dispatch without PAIR_QUIET_WAIT), then quiet_wait logs its own: two rows per return
- 2026-10-16 kitchen-perf 002: verify provider path logs verify:provider then execs the fallback retry, which logs a second wake for the same return
