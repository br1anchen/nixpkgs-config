# Project Context: Nixpkgs Config

## Overview
This repository contains **Nix** and **Home Manager** configurations for managing system environments and dotfiles. It utilizes **Nix Flakes** for reproducible builds and manages configurations for multiple systems, including macOS (Darwin) and Linux (NixOS).

## Configurations

The project defines the following configurations in `flake.nix`:

### NixOS Systems
- **`br1anchen@dune`** (`x86_64-linux`): A standard NixOS system configuration.

### Home Manager Configurations
- **`br1anchen`** (`aarch64-darwin`): The primary macOS configuration.
- **`brian`** (`x86_64-linux`): A generic Linux home configuration.
- **`deck`** (`x86_64-linux`): A configuration likely for the Steam Deck.

## Directory Structure

*   **`flake.nix`**: The entry point defining inputs (nixpkgs, home-manager) and outputs (system configurations).
*   **`home-manager/`**: Contains Home Manager modules.
    *   `home.nix`: The main entry point for user environment configuration.
    *   `*.nix`: Modularized configurations (e.g., `git.nix`, `lazyvim.nix`, `tmux.nix`).
*   **`nixos/`**: Contains NixOS system configurations.
    *   `configuration.nix`: Main NixOS system config.
*   **`config/`**: Contains raw configuration files (dotfiles) for various tools (nvim, alacritty, starship, etc.).
*   **`modules/`**: Intended for reusable custom modules (currently empty).
*   **`pkgs/`**: Custom packages defined within this flake.
*   **`overlay/`**: Custom Nix overlays.
*   **`shell.nix`**: A development shell for bootstrapping the environment with `nix` and `home-manager`.

## Key Commands

### Installation & Updates
The project uses `home-manager` for applying user configurations.

```bash
# Apply Home Manager configuration (backup existing files)
home-manager --switch --impure -b backup
```

### Bootstrapping
To enter a shell with `nix` and `home-manager` available:

```bash
nix-shell
# or
nix develop
```

### Commit Guidelines
The project uses `commitizen` for formatted git commits.

```bash
# Install commitizen tools
npm install -g cz-git commitizen

# Commit changes
git cz
```

## Conventions
- **Modular Configs:** Home Manager settings are split into separate files (e.g., `git.nix`, `zsh.nix`) in `home-manager/` and imported into `home.nix`.
- **Dotfiles:** Application-specific config files are often stored in `config/` and referenced or linked.
- **Flakes:** All dependencies and outputs are managed via `flake.nix`.
