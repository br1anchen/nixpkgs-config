# Lazygit settings

{ lib, pkgs, ... }:

{

  home.packages = with pkgs; lib.optionals pkgs.stdenv.hostPlatform.isLinux [ zed-editor ];

  xdg.configFile.zed = {
    source = ../config/zed;
    recursive = true;
  };
}
