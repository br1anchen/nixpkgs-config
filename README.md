# nixpkgs-config

## Install

### Install Nix [ref](https://zero-to-nix.com/start/install/#run)

```bash
curl --proto '=https' --tlsv1.2 -sSf -L https://install.determinate.systems/nix | sh -s -- install
```

### Install Home Manager [ref](https://nix-community.github.io/home-manager/index.xhtml#sec-install-standalone)

```bash
nix-channel --add https://github.com/nix-community/home-manager/archive/master.tar.gz home-manager

nix-channel --update

nix run home-manager/master -- init --switch -b backup
```

### Install configuration

```bash
cd ~
git clone --recurse-submodules -j8 git@github.com:br1anchen/nixpkgs-config.git
cd ~/.config

rm -rf home-manager
ln -s ~/nixpkgs-config home-manager
home-manager switch --flake .#darwin -b backup

cd ~/.config/nixpkgs
ln -s ~/nixpkgs-config/config.nix config.nix
```

### Install runtimes via mise

Mise is installed via Nix/Home Manager. After switching, install configured tool versions:

```bash
mise install
```

## Agent workflow

Ghostty starts Herdr as the default control plane. Herdr opens login zsh
shells, stores worktrees under `~/.herdr/worktrees`, and restores supported
agent sessions. Start a plan-gated Pi session with:

```bash
pi --plan
```

Use Pi's `/tree` command to branch a conversation. Plannotator intercepts
plans for review; run it explicitly for a final code or diff review before a
commit or handoff.

Herdr keeps `Ctrl-a` as its prefix. Direct `Ctrl-h/j/k/l` navigation crosses
Neovim splits and Herdr panes. The same mappings fall back to tmux when tmux
is launched manually.

Useful fallbacks:

```bash
gsh   # Open a plain Ghostty login shell without Herdr
tmux  # Launch the retained tmux configuration manually
```

The legacy `gwt-*` worktree helpers remain installed, but Herdr's worktree UI
is the primary path. After the first Home Manager activation, open Codex and
run `/hooks` once to review and trust the generated user hooks.

### Install Neovim

```bash
mkdir ~/.local/share/bob
rustup default stable
cargo install bob-nvim
bob install latest
bob use latest
```

### Patch after macOS updates

```bash
sudo bash ./fix_macos_updated.sh
```

### Git commit

```bash
npm install -g cz-git commitizen
```
