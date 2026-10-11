# Herdr Prime Agent patch

`default.nix` patches the Herdr v0.9.3 flake package pinned in `flake.nix`.
Home Manager and `nix build .#herdr` use this same package.

The patch registers the `prime-agent` kind and executable, grants lifecycle
authority to Prime's built-in `(herdr:pi, prime-agent)` reporter, and supports
session path persistence and `prime-agent --resume`. Prime is hook-only;
there is no speculative screen-detection manifest or separate integration hook.
The new Rust tests cover identity, initial readiness, ordered state transitions,
release, snapshot restoration, and resume. Initial and replacement reporting
are tested both before and after foreground detection, with stale reports rejected.

After building `.#herdr`, run the real-binary smoke test with explicit binaries:

```bash
python3 tests/prime_herdr_smoke.py --herdr /nix/store/.../bin/herdr --prime-agent /absolute/path/to/prime-agent
```

It creates its own named Herdr session, Prime daemon socket, and local mock model
provider. It checks lifecycle reporting, steering, provider failure, worker
cleanup, and a fresh conversation in the same pane without paid model calls.

When upstream includes equivalent support, remove the patch and override,
update the pin, and re-run pstack's Prime tests. Do not rename the accepted
reporter source independently of Prime Agent.
