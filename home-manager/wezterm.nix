# Wezterm settings

{ config, lib, pkgs, ... }:

{

  xdg.configFile.wezterm = {
    source = ../config/wezterm;
    recursive = true;
  };

}