# Prime Agent

Prime works as a sidekick, consultant, or kitchen verifier. It uses the same
store, READY, PLAN, BRIEF, STEER, and REPORT protocol as other agents. Use the
repository's patched Herdr v0.9.3 and Prime Agent 0.10.0 or later with built-in
Herdr reporting. No Pi extension is needed. Prime discovers `~/.agents/skills`.

## Launch

Choose a model configured in Prime's own settings. Pi's provider plugins and
permission flags are not portable to Prime.

```bash
pair.sh spawn <store> --kind prime-agent --fallback devin -- --model <provider/model> --thinking high
```

For trio, use `--sidekick prime-agent` or `--consultant prime-agent` with the
`--only sidekick` or `--only consultant` when their native arguments differ;
arguments after `--` apply to every role spawned by that call. For kitchen,
set these entries in the host roster (`~/.config/pstack/kitchen.toml`):

```toml
[sidekick]
kind = "prime-agent"
args = ["--model", "provider/model", "--thinking", "high"]
[sidekick.fallback]
kind = "devin"
[verifier]
kind = "prime-agent"
args = ["--model", "provider/model", "--thinking", "high"]
```

Replace `provider/model` with your configured model. `--kind` overrides a
kitchen roster entry. `--daemon-socket PATH` is preserved and used for daemon
management too. Keep the master's and spawned panes' Prime version and global
configuration consistent. Per-pane configuration-root overrides are not supported.

Prime executes tools without approval dialogs. The helper adds no permission
or trust flags. `--permission plan` cannot enforce read-only execution.
Complete Prime's first-run onboarding interactively before an unattended launch.
The helper never answers onboarding consent or provider-login prompts.

Before launching a sidekick, the helper sends a minimal print-mode model
request in a disposable directory, without session persistence, context files,
skills, or prompt templates. It retries once. Two failures start the recorded
fallback, or exit 2 without starting an agent. A live sidekick skips preflight.

## Sessions and steering

After a completed brief, the master runs `pair.sh rotate <store>` before
dispatching another task. Partial and blocked reports keep their session.
The queue, transcript, progress, and step log survive rotation. Resume flags
are rejected when spawning task agents; recover through the store instead.

A working sidekick receives `pair.sh steer` through `prime-agent send --json`
at its exact live daemon ID, with a receipt confirming steering delivery.
Prime 0.10.0 advertises `send --steer` in help but rejects it; plain `send`
defaults to steering. The running tool call continues. `--interrupt`
explicitly requests cancellation through Herdr first.

`/quit` detaches Prime's UI and leaves its worker alive. The helper records the
Herdr session path or ID, resolves it against `prime-agent list --json`, and
stops only the matching `activeSessionId`. It verifies that ID is gone and
the pane is back at its shell. A blocked provider-error client is detached with
its default Ctrl+D binding before stopping the worker; custom keybindings that
keep the client open cause cleanup to fail safely. It never uses session-name/prefix matching,
deletes transcripts, or shuts down the shared daemon. An unavailable daemon,
ambiguous reference, failed stop, or client that stays alive prevents replacement
and preserves the pane. Kitchen also preserves the scratch worktree.

## Provider failure

Prime reports provider errors as `blocked` after its retry grace. The helper
reads the latest assistant error from that role's recorded transcript. A blocked
provider error calls for `pair.sh failover <store> --reason provider-error`;
a blocked question without a provider error still needs inspection. No automatic
screen-text error guessing is used for Prime.

Failover stops the owned session before starting the fallback, which recovers
from the store. A kitchen verifier retries once on its configured fallback
after successful cleanup. If cleanup fails, inspect the preserved pane and
rerun `verify-wait` after resolving it. Never use `prime-agent shutdown`.
