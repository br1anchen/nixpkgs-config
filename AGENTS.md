# Repository Guidelines

## Project Structure & Module Organization

- `flake.nix`/`flake.lock` are the entrypoints; `shell.nix` provides a bootstrap shell.
- Home Manager configuration is centered on `home-manager/home.nix`, with shared modules in `modules/home-manager/` and tool-specific files under `home-manager/` and `config/`.
- This repo is home-manager only; there is no NixOS host. The supported targets are macOS and Arch + **Omarchy** (the only supported Linux distro).
- Shared dotfiles are listed in `dotfiles/manifest.tsv` and delivered two ways: **symlinks on macOS** (`home-manager/dotfiles.nix`) and **file copies on Omarchy** via `scripts/dotfiles-sync.sh`. Omarchy's write paths (`cp -f`, `sed -i`) corrupt symlinks silently, so no file Omarchy reads/writes/migrates may be a home-manager symlink. A small set of `programs.*` paths Omarchy never touches (broot, bat, the herdr plugin drop-ins, HM infrastructure) are accepted exceptions — see the header of `home-manager/dotfiles.nix`.
- Overlays and custom packages sit in `overlay/` and `pkgs/`; helper scripts (e.g., `fix_macos_updated.sh`) stay in `config/` or repo root.
- Runtime version management uses mise (installed via Home Manager `programs.mise`); config lives at `config/mise/config.toml`.

## Build, Test, and Development Commands

- `nix develop` — drop into a dev shell with Nix and Home Manager available.
- `nix flake check` — evaluate the flake and run defined checks; add `--show-trace` if debugging.
- Apply Home Manager configs: `home-manager switch --flake .#darwin` (macOS) or `.#omarchy` (Arch + Omarchy).
- Sync dotfiles on Omarchy: `dotfiles-sync status` / `pull` / `push` (see `scripts/dotfiles-sync.sh`).
- One-time Omarchy wiring: `./scripts/omarchy-bootstrap.sh`.
- Tooling helpers: run `mise install` to install configured runtimes; after macOS updates, run `sudo bash ./fix_macos_updated.sh`.
- mise owns language runtimes on both platforms (Omarchy's `mise activate bash` prepends its shims ahead of the nix profile). `config/mise/config.toml` must keep Omarchy's `claude`/`codex`/`gh` entries.

## Coding Style & Naming Conventions

- Keep Nix files formatted via `nix fmt` (or `nixpkgs-fmt`); prefer small, composable modules over monoliths.
- Name scopes and files by tool/area (`config/wezterm`, `home-manager/neovim`, `modules/home-manager/tmux.nix`).
- Keep platform-specific config behind the `isDarwin` / `isOmarchy` flags passed from `flake.nix`; shared logic goes in `modules/`.

## Testing Guidelines

- Use `nix flake check` as the baseline validation before commits.
- For Home Manager changes, dry-run with `home-manager build --flake .#<profile>`. Always check **both** `.#darwin` and `.#omarchy` build before switching.
- When altering overlays/packages, build them explicitly (`nix build .#<pkg>`), and prefer small, host-scoped diffs.

## Commit & Pull Request Guidelines

- Commitizen is configured (`cz commit` / `git cz`); choose a type (feat/fix/docs/...) and a scope matching the touched path (e.g., `home-manager/tmux`, `config/wezterm`). Write imperative, concise subjects.
- Keep commits atomic and include notes on host(s) impacted.
- PRs: summarize the change, mention commands run (`nix flake check`, rebuild/switch commands), and call out any manual steps (e.g., rerunning `fix_macos_updated.sh`).

## Security & Configuration Tips

- Do not commit secrets; keep tokens/keys out of the repo and prefer host-level environment configuration.
- When unsure about the impact of a change, run flake checks and host-specific builds before switching to avoid partial system states.
