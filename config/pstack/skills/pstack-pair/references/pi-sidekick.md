# Pi sidekick and fallback

A pi sidekick suits the role: it can run a cheaper or subscription model, such
as SWE-2 through the `pi-devin-local` package, and Herdr reads its state from
pi's own lifecycle events instead of the screen. That leaves out the screen
checks a Devin sidekick needs. Like Devin, pi starts a fresh session for each
completed brief, so one long compacted conversation never carries earlier
briefs into the next: after a `done` report the queue waits, and the master
runs `pair.sh rotate`, which quits pi and restarts it in the same pane with its
recorded arguments, checks the new READY, and dispatches. Partial and blocked
work keeps its session, and spawn refuses resume flags (`--continue`,
`--session`, `--fork`). [The Devin session lifecycle](devin-sessions.md)
applies to pi as written.

## What differs from Devin

- **State.** Herdr's pi integration reports working, blocked, and idle, so a
  settle is real. Devin's state is screen-detected and needs the busy checks.
- **Steers.** A message typed while pi works queues as a steer and arrives
  after the running tool call; the command keeps running. `pair.sh steer`
  sends it as it would to any non-Devin kind.
- **Approvals.** pi asks for none, so it takes no permission arguments, and
  `--permission plan` has no pi translation: pi cannot run read-only. Its one
  gate is project trust, which prompts in a repo with `.agents/skills` and
  would hang an unattended agent, so `spawn` passes `--approve`.
- **Exit.** `/quit`, which `failover` sends.

## Spawning with a fallback

Name a fallback whenever the model sits behind a route that can fail:

```bash
pair.sh spawn <store> --kind pi --fallback devin -- --model devin/swe-2 --thinking high
```

`--fallback-arg ARG`, once per argument, gives the fallback its own native
arguments; without them it starts with its kind's defaults (Devin: bypass).
`pair.json` keeps the fallback, so a later spawn without `--fallback` keeps
it too.

Before the pane starts, `spawn` sends pi one print-mode prompt with the same
model arguments, without the repo's resources. When that fails (no
credentials, capacity, a protocol change), it prints the reason and starts the
fallback in its place. Without a fallback it exits 2 and starts nothing. A
live sidekick skips the check. The check runs the master's `pi`, while the
pane runs its own shell's; after upgrading pi, restart the master's session so
both see the same version. The failure reason names the version and path.

## Failing over mid-run

A wait that ends with `report: missing` checks the pane for provider errors.

- `provider_error: <line>` with the pi agent still up: prompt the sidekick
  once to continue. On a second provider error within the brief, fail over.
- `provider_error: the pi sidekick exited`: fail over now.

```bash
pair.sh failover <store> --reason provider-error
```

It quits pi, starts the fallback in the same pane, and bootstraps it; the new
agent runs session pickup from the store (step log, progress, the dispatched
brief), so every committed step survives and uncommitted edits stay in the
tree for it to inspect. It prints the brief to re-dispatch; put "resumed after
failover from pi" and the last recorded step in its Context. A working
sidekick needs `pair.sh stop` first, or `--force`, which interrupts it.

A run stays on the fallback: `failover` refuses once the sidekick already runs
it. Spawn pi again only on purpose, after the cause is fixed. Each failover is
recorded under `sidekick.failovers` in `pair.json` and as an event that
`pair.sh metrics` counts.
