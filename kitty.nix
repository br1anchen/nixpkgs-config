# Kitty settings

{ config, lib, pkgs, ... }:

{

  xdg.configFile.kitty = {
    source = ./config/kitty;
    recursive = true;
  };

}
