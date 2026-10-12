# Muse Code as a pstack role

Meta's Muse Code CLI (`muse`) runs as a Herdr `muse` kind (Herdr 0.9.3 and
later recognize it on screen). Any role can use it: set `kind = "muse"` in a
roster entry, or pass `--kind muse` to `pair.sh spawn`, with Muse-native
arguments such as `--model muse-wonder-full --reasoning-effort max`. Catalog
ids include `muse-spark-1.3`, `muse-wonder` and `muse-wonder-full` (Wonder Full
needs a Muse Code subscription plan). Log in once with `muse login`.

What pstack adds when the native arguments do not set it:

- **Permissions.** `--approval-mode never --disable-sandbox`: Muse's default
  shell sandbox refuses writes outside the workspace, which a role makes to
  its run store and its gates make to their caches. `bypassPermissions`
  becomes `--yolo`; `plan` becomes `--approval-mode never --disable-write`.
  Any of `--approval-mode`, `--yolo`, `--disable-approval`,
  `--disable-sandbox` or `--permission-profile` in the native arguments wins.
- **Workspace trust.** `--trust-workspace`, so the first launch in a repo does
  not stop on "Do you trust this workspace?".
- **No MCP opt-out.** Muse loads only servers configured in its own settings;
  a `-c mcp_servers=...` override stops it from starting, so none is passed.
- **Preflight.** A sidekick, and a kitchen consultant, runs one
  `muse exec --model <model>` prompt before its pane starts. A logged-out account (`missing meta credentials`)
  or a spent plan (`Usage limit reached`, `wait for usage to reset at`)
  fails over to the roster fallback (`[sidekick.fallback]`,
  `[consultant.fallback]`) instead of starting.
- **Exit.** `/quit`; the process ends with the TUI, so close and failover
  leave nothing running.
- **Provider errors.** The usage-limit and credential messages count as
  provider errors on screen, and in the newest Muse session log that names
  the role's working directory (Herdr reports no Muse session id).

Muse keeps one conversation per pane like Claude and Codex, so it is not
rotated per brief.
