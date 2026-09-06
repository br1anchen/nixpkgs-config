# Neovim (LazyVim).
#
# The config itself is the config/lazyvim submodule, delivered by ./dotfiles.nix.
# Omarchy's own `omarchy-nvim` package is removed on this host: while installed,
# it owns ~9,982 files under /etc/skel and `omarchy reinstall configs`
# (`cp -af /etc/skel/. ~/`) would bulldoze this config.

{ pkgs, ... }:
{
  home.packages = with pkgs; [
    luajitPackages.luarocks
    nixfmt
    pyright
    ruff
    statix
    code-minimap
    tree-sitter
  ];
}
