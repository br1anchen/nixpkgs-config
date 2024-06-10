# Lazygit settings

{
  config,
  lib,
  pkgs,
  ...
}:

{

  home.packages = with pkgs; lib.optionals pkgs.stdenv.isLinux [ zed-editor ];

  xdg.configFile.zed = {
    source = ../config/zed;
    recursive = true;
  };
}
