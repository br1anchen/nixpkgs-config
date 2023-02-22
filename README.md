# nixpkgs-config

## Install

### Install Nix

```bash
sh <(curl -L https://nixos.org/nix/install)
```

### Install Home Manager

```bash
nix-channel --add https://github.com/nix-community/home-manager/archive/master.tar.gz home-manager

nix-channel --update

export NIX_PATH=$HOME/.nix-defexpr/channels:/nix/var/nix/profiles/per-user/root/channels${NIX_PATH:+:$NIX_PATH}

nix-shell '<home-manager>' -A install
```

### Install configuration

```bash
cd ~
git clone --recurse-submodules -j8 git@github.com:br1anchen/nixpkgs-config.git
cd ~/.config
rm -rf nixpkgs
ln -s ~/nixpkgs-config nixpkgs
```

### Install asdf

```bash
git clone https://github.com/asdf-vm/asdf.git ~/.asdf --branch v0.11.1
```

### Install Neovim

```bash
cargo install bob-nvim
```

### Patch after macOS updates

```bash
sudo bash ./fix_macos_updated.sh
```

### Git commit

```bash
npm install -g cz-git commitizen
```
