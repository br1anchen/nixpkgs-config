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
  ];

  xdg.configFile.nvim = {
    source = ./config/neovim;
    recursive = true;
  };

}
