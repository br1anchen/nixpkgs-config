# Neovim settings

{ pkgs, ... }:

{

  home.packages = with pkgs; [
    luajitPackages.luarocks
    nixfmt-rfc-style
    statix
    code-minimap
    tree-sitter
  ];

  xdg.configFile.bob = {
    source = ../config/bob;
    recursive = true;
  };

  xdg.configFile.nvim = {
    source = ~/nixpkgs-config/config/lazyvim;
    recursive = true;
  };
}
