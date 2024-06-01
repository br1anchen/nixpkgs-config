# nixpkgs-config

## Install

### Install Nix

```bash
sh <(curl -L https://nixos.org/nix/install)
```

### Install Home Manager [ref](https://nix-community.github.io/home-manager/index.html#ch-nix-flakes)

```bash
nix run home-manager/master -- init --switch
```

### Install configuration

```bash
cd ~
git clone --recurse-submodules -j8 git@github.com:br1anchen/nixpkgs-config.git
cd ~/.config

rm -rf home-manager
ln -s ~/nixpkgs-config home-manager

cd ~/.config/nixpkgs
ln -s ~/nixpkgs-config/config.nix config.nix
```

### Install asdf

```bash
bash ./config/asdf/setup.sh
```
```

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
