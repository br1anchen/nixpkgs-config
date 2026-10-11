# Prime Agent in Herdr and pstack

Implemented 2026-10-10. See [Prime Agent research](prime-agent-research.md)
for the inspected Prime CLI and reporter contract, and the
[Prime workflow reference](../config/pstack/skills/pstack-pair/references/prime-sidekick.md)
for launch examples and operational behavior.

The Herdr pin is updated from v0.8.2 to the latest stable release,
[v0.9.3](https://github.com/herdrdev/herdr/releases/tag/v0.9.3).
That release still lacks native Prime Agent registration. The
[local package patch](../pkgs/herdr/README.md) adds its kind, foreground
recognition, built-in lifecycle authority, initial combined session/state
report, session persistence, and resume. Home Manager and `.#herdr` use the
same patched package.

The shared pair runtime supplies Prime-native preflight, generation-scoped
session records, fresh conversations after completed briefs, daemon steering,
and exact worker shutdown for rotation, failover, and close. Pair, guided
pair, trio, and kitchen share this adapter. Kitchen also stops Prime verifiers
before removing their scratch worktrees, and preserves failed starts or
cleanup attempts for inspection.

No duplicate Pi extension or Prime skill installation is required. The existing
`~/.agents/skills` deployment is discovered by Prime. Choose a model configured
in Prime's own settings; Pi provider plugins are not transferred. The host
roster is not changed by this implementation. Set `kind = "prime-agent"` in
its sidekick, consultant, or verifier entries when selecting Prime.

Validation includes daemon fixtures that model detach-without-stop behavior,
provider errors, exact session ownership, ambiguous matches, native steering,
rotation and cleanup failure. The Rust patch includes identity, report ordering,
initial readiness, release, snapshot, and resume tests. Live validation uses
a disposable named Herdr session and a local mock provider without paid model
requests.

## Completed validation

- `nix flake check`, `nix build .#herdr`, and the Omarchy activation-package
  build pass. No Home Manager configuration was activated.
- Darwin's activation package evaluates successfully. A full build was attempted
  but requires a macOS builder; this host is x86_64 Linux.
- The 232-test pstack run passed 229 tests. Its three help snapshots were updated
  for the intentional Prime wording and all three passed on rerun. The 17
  Prime-specific workflow tests also passed after correcting native steering.
- All six Prime Rust regression tests pass, including session handoff with both
  report arrival orders, stale-report rejection, and early resume reporting.
- The real-binary smoke test passes with patched Herdr v0.9.3 and installed
  Prime Agent 0.10.0: preflight, initial session identity, working-to-idle,
  receipt-confirmed steering, provider-error blocked, exact worker stop,
  shell recovery, transcript preservation, and a fresh session in the same pane.
  Its dedicated Herdr session and Prime daemon were cleaned up.

Apply Home Manager and start a fresh Herdr server with the patched binary before
using the new kind. Existing servers keep their running version.
