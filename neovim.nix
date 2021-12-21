# Neovim settings

{ config, lib, pkgs, ... }:

{

  xdg.configFile.nvim = {
    source = ./config/neovim;
    recursive = true;
  };

}
