# Lazygit settings

{ config, lib, pkgs, ... }:

{

  home.packages = with pkgs; [ lazygit ];

  xdg.configFile.lazygit = {
    source = ./config/lazygit;
    recursive = true;
  };

  # macOS:
  # ln -s ~/.config/lazygit/config.yml ~/Library/Application\ Support/lazygit/config.yml

}
