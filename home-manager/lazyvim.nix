# Neovim settings

{ config, lib, pkgs, ... }:

{

  home.packages = with pkgs; [
    luajitPackages.luarocks
    nixfmt
    statix
    code-minimap
  ];

  xdg.configFile.nvim = {
    source = ~/nixpkgs-config/config/lazyvim;
    recursive = true;
  };

}
