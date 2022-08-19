# Alacritty settings

{ config, lib, pkgs, ... }:

{

  xdg.configFile.alacritty = {
    source = ../config/alacritty;
    recursive = true;
  };

}
