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
home-manager --switch --impure -b backup

cd ~/.config/nixpkgs
ln -s ~/nixpkgs-config/config.nix config.nix
```

### Install asdf

```bash
bash ./config/asdf/setup.sh
```

````

### Install Neovim

```bash
mkdir ~/.local/share/bob
rustup default stable
cargo install bob-nvim
bob install latest
bob use latest
````

### Patch after macOS updates

```bash
sudo bash ./fix_macos_updated.sh
```

### Git commit

```bash
npm install -g cz-git commitizen
```
