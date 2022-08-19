# Gitui settings

{ config, lib, pkgs, ... }:

{

  xdg.configFile.gitui = {
    source = ../config/gitui;
    recursive = true;
  };

}
