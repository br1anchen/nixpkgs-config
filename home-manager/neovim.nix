# Neovim settings

{ config, lib, pkgs, ... }:

{

  home.packages = with pkgs; [
    rnix-lsp
    stylua
    luajitPackages.luacheck
    nixfmt
    shellcheck
    shfmt
    statix
    code-minimap
    sqlfluff
    jupyter
    black
  ];

  xdg.configFile.nvim = {
    source = ../config/neovim;
    recursive = true;
  };

  xdg.configFile."nvim/init.vim".text = ''
    luafile ./init.lua
  '';

}
