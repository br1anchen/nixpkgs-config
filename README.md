# nixpkgs-config

## Install

```bash
cd ~
git clone git@github.com:br1anchen/nixpkgs-config.git
cd ~/.config
rm -rf nixpkgs
ln -s ~/nixpkgs-config nixpkgs

export NIX_PATH=${NIX_PATH:+$NIX_PATH:}$HOME/.nix-defexpr/channels:/nix/var/nix/profiles/per-user/root/channels
```
