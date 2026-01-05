# Repository Guidelines

## Project Structure & Module Organization

- `flake.nix`/`flake.lock` are the entrypoints; `shell.nix` provides a bootstrap shell.
- NixOS modules live in `nixos/` (main file: `nixos/configuration.nix`) with reusable pieces in `modules/nixos/`.
- Home Manager configuration is centered on `home-manager/home.nix`, with shared modules in `modules/home-manager/` and tool-specific files under `home-manager/` and `config/`.
- Overlays and custom packages sit in `overlay/` and `pkgs/`; helper scripts (e.g., `fix_macos_updated.sh`, `config/asdf/setup.sh`) stay in `config/` or repo root.

## Build, Test, and Development Commands

- `nix develop` — drop into a dev shell with Nix and Home Manager available.
- `nix flake check` — evaluate the flake and run defined checks; add `--show-trace` if debugging.
- Apply Home Manager configs: `home-manager switch --flake .#br1anchen` (macOS), `.#brian` (Linux), or `.#deck` (Steam Deck).
- Build NixOS host: `sudo nixos-rebuild switch --flake .#br1anchen@dune`.
- Tooling helpers: run `bash ./config/asdf/setup.sh` to install asdf; after macOS updates, run `sudo bash ./fix_macos_updated.sh`.

## Coding Style & Naming Conventions

- Keep Nix files formatted via `nix fmt` (or `nixpkgs-fmt`); prefer small, composable modules over monoliths.
- Name scopes and files by tool/area (`config/wezterm`, `home-manager/neovim`, `modules/home-manager/tmux.nix`).
- Keep host-specific overrides in host files (`nixos/configuration.nix`, `home-manager/home.nix`) and shared logic in `modules/`.

## Testing Guidelines

- Use `nix flake check` as the baseline validation before commits.
- For Home Manager changes, dry-run with `home-manager build --flake .#<profile>`; for NixOS, use `sudo nixos-rebuild test --flake .#<host>`.
- When altering overlays/packages, build them explicitly (`nix build .#<pkg>`), and prefer small, host-scoped diffs.

## Commit & Pull Request Guidelines

- Commitizen is configured (`cz commit` / `git cz`); choose a type (feat/fix/docs/...) and a scope matching the touched path (e.g., `home-manager/tmux`, `config/wezterm`). Write imperative, concise subjects.
- Keep commits atomic and include notes on host(s) impacted.
- PRs: summarize the change, mention commands run (`nix flake check`, rebuild/switch commands), and call out any manual steps (e.g., rerunning `fix_macos_updated.sh`).

## Security & Configuration Tips

- Do not commit secrets; keep tokens/keys out of the repo and prefer host-level environment configuration.
- When unsure about the impact of a change, run flake checks and host-specific builds before switching to avoid partial system states.
