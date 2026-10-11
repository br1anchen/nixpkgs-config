# Prime Agent and Herdr integration research

Investigated 2026-10-10. This note records source findings, not a tested integration.

## Version and evidence

- The official project is [PrimeIntellect-ai/prime-agent](https://github.com/PrimeIntellect-ai/prime-agent).
- Local `prime-agent --version` returned **0.10.0**. Its installed `package.json` describes a Rust build. Its CLI help was inspected without starting an agent turn.
- Upstream source was inspected at commit [2ee7e623a70d8ccd9c72ffc6c4f25be2cc1bc02d](https://github.com/PrimeIntellect-ai/prime-agent/tree/2ee7e623a70d8ccd9c72ffc6c4f25be2cc1bc02d), dated 2026-10-10, in `/tmp/prime-agent-research-source`.
- Indexed documentation under `packages/coding-agent/` describes the previous TypeScript implementation. Current source uses Rust `crates/`; do not assume the old Pi extension APIs remain available.
- Installed binary strings contain `herdr:pi`, `pane.report_agent`, `pane.release_agent`, and both Herdr reporter tuning variables. This corroborates that the installed binary includes the connector, but does not establish an exact source commit or validate it against the installed Herdr.

## Prime already reports its lifecycle to Herdr

The Rust daemon has a [built-in Herdr connector](https://github.com/PrimeIntellect-ai/prime-agent/blob/2ee7e623a70d8ccd9c72ffc6c4f25be2cc1bc02d/crates/pa-daemon/src/herdr.rs). A separate Pi extension is unnecessary for this reporting path.

- It activates when the session's client environment includes `HERDR_ENV=1`, a nonempty `HERDR_PANE_ID`, and `HERDR_SOCKET_PATH`.
- Reports call `pane.report_agent` with **source `herdr:pi` and agent `prime-agent`**. Preserve this existing identity when accepting Prime reports in Herdr.
- Reports include monotonic `seq`, `working` / `blocked` / `idle`, and `agent_session_path`, falling back to `agent_session_id` for unsaved sessions. Current source additionally includes `resume_argv: ["prime-agent", "--resume", target]` for valid session references.
- Session creation and reattachment bind pane identity from client-supplied allowlisted variables, rather than inheriting whichever pane booted the shared daemon. See [the environment contract](https://github.com/PrimeIntellect-ai/prime-agent/blob/2ee7e623a70d8ccd9c72ffc6c4f25be2cc1bc02d/crates/pa-types/src/daemon/herdr_env.rs) and [worker reattachment](https://github.com/PrimeIntellect-ai/prime-agent/blob/2ee7e623a70d8ccd9c72ffc6c4f25be2cc1bc02d/crates/pa-daemon/src/worker/connection.rs).
- On Unix, the reporter connects only to a nonsymlink socket owned by its effective user. The state reporter is best effort and bounds socket operations.
- Successful turn completion settles to idle. Queued messages delay idle by 250 ms (`HERDR_PI_IDLE_DEBOUNCE_MS`). A terminal assistant row with `stopReason: "error"` holds working for 2,500 ms (`HERDR_PI_RETRY_GRACE_MS`), then reports blocked with `errorMessage` or `provider error`. Automatic retry clears the hold and keeps working. See [turn event wiring](https://github.com/PrimeIntellect-ai/prime-agent/blob/2ee7e623a70d8ccd9c72ffc6c4f25be2cc1bc02d/crates/pa-daemon/src/worker/turn.rs).
- Worker stop/shutdown sends `pane.release_agent`. Merely exiting the TUI does not stop the daemon session.

## CLI contract for launch, prompting, and rotation

The installed 0.10.0 help confirms:

```text
prime-agent --provider <name> --model <id> --thinking <level>
prime-agent --cwd <dir>
prime-agent --resume <path|id>
prime-agent --session-dir <dir> --no-session
prime-agent --skill <path>                 # repeatable
prime-agent --no-skills --no-context-files --no-prompt-templates
prime-agent --print                       # one response, then exit
prime-agent --mode text|json|rpc|acp|daemon
prime-agent send [--from <agent>] [--steer|--follow-up] [--json] <agent> <message>
prime-agent stop <agent>
prime-agent session export <file> [output] # HTML
```

`--thinking` accepts `off`, `minimal`, `low`, `medium`, `high`, `xhigh`, or `max`. The source [model resolver](https://github.com/PrimeIntellect-ai/prime-agent/blob/2ee7e623a70d8ccd9c72ffc6c4f25be2cc1bc02d/crates/pa-core/src/models/resolver.rs) also accepts a canonical `provider/id` model reference with a thinking suffix. Explicit `--provider`, `--model`, and `--thinking` avoid guessing from a Pi profile.

The current [argument parser](https://github.com/PrimeIntellect-ai/prime-agent/blob/2ee7e623a70d8ccd9c72ffc6c4f25be2cc1bc02d/crates/pa-cli/src/args.rs) has no Pi `--extension` / `-e`, `--tools`, or permission/trust bypass flags. Launch Prime without copying those flags. Its runtime executes Python and shell commands with the user's permissions, as described in the official README.

The TUI supports `/new` (alias `/clear`), `/resume`, `/export`, `/reload`, and `/quit`; `/export` can also write `.jsonl`. See [the command registry](https://github.com/PrimeIntellect-ai/prime-agent/blob/2ee7e623a70d8ccd9c72ffc6c4f25be2cc1bc02d/crates/pa-types/src/slash_commands.rs). **`/quit` and `/exit` detach the TUI while the session remains alive**; see [TUI dispatch](https://github.com/PrimeIntellect-ai/prime-agent/blob/2ee7e623a70d8ccd9c72ffc6c4f25be2cc1bc02d/crates/pa-tui/src/session_ui/commands.rs). A worker rotation must stop the exact retired session through `prime-agent stop <agent>` and verify release. Do not use `prime-agent shutdown`, which stops every agent and service.

Live implementation testing later found a mismatch between help and the Rust
parser: 0.10.0 rejects `send --steer` and `--follow-up`. Its
[daemon CLI](https://github.com/PrimeIntellect-ai/prime-agent/blob/2ee7e623a70d8ccd9c72ffc6c4f25be2cc1bc02d/crates/pa-cli/src/daemon_command.rs)
passes no delivery mode, and the worker defaults to steering. Use plain
`send --json` and check the receipt's `deliveryMode`, target ID, and status.
Herdr's terminal prompt transport is verified separately by the integration smoke test.

## Preflight and provider failure handling

Current [print runtime](https://github.com/PrimeIntellect-ai/prime-agent/blob/2ee7e623a70d8ccd9c72ffc6c4f25be2cc1bc02d/crates/pa-cli/src/print_runtime.rs) makes a material distinction:

- Text `--print` reports terminal provider errors on stderr and exits nonzero.
- JSON mode emits events but deliberately does **not** derive its exit code from the terminal provider result. A JSON preflight must inspect the last assistant's `stopReason` / `errorMessage`; an exit code of zero is insufficient.

A future provider preflight can use a disposable cwd with `--print --no-session --no-context-files --no-skills --no-prompt-templates`, the selected provider/model/thinking, and a bounded external timeout. Keep the real authentication/model settings available. `PRIME_AGENT_CODING_AGENT_DIR` changes the entire config root, so replacing it with an empty temporary directory also loses credentials and custom model definitions. `--session-dir` and `PRIME_AGENT_SESSION_DIR` control session storage separately. These isolation flags suppress resource discovery, not arbitrary model tool execution; the probe prompt still needs to ask for a minimal answer without tool use.

Prime's provider error text already reaches Herdr's blocked report. Reusing pstack's existing failure classifier may be possible, but matching Prime errors and model fallback requires dedicated verification.

## Shared skills are discovered already

The [resource resolver](https://github.com/PrimeIntellect-ai/prime-agent/blob/2ee7e623a70d8ccd9c72ffc6c4f25be2cc1bc02d/crates/pa-core/src/packages/resolve/auto.rs) discovers:

- `~/.agents/skills`;
- project `.agents/skills` directories from cwd up to the Git root, nearest first;
- `~/.prime/agent/skills` and project `.prime/agent/skills`;
- configured package resources, explicit `--skill` paths, and bundled skills.

The [ancestor scan](https://github.com/PrimeIntellect-ai/prime-agent/blob/2ee7e623a70d8ccd9c72ffc6c4f25be2cc1bc02d/crates/pa-core/src/packages/resolve/discovery.rs) stops at the Git root, or filesystem root outside a Git repository. Existing shared pstack skills under `~/.agents/skills` therefore need no duplicate Prime deployment. Frontmatter still needs to satisfy Prime's skill loader; live skill inventory should be checked in the eventual integration smoke test.

## Implementation follow-up

The initial source investigation did not start agent turns or alter Herdr sessions.
The subsequent implementation is described in
[the integration notes](prime-agent-herdr-plan.md). Its reusable
[real-binary smoke test](../tests/prime_herdr_smoke.py) uses an isolated session,
daemon socket, and local provider. The native send parser discrepancy above was
found during that test; CLI help alone was insufficient evidence.
