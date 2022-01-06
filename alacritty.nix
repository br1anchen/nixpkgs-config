# Alacritty settings

{ config, lib, pkgs, ... }:

{

  home.packages = with pkgs; [ alacritty ];

  xdg.configFile.alacritty = {
    source = ./config/alacritty;
    recursive = true;
  };

}
