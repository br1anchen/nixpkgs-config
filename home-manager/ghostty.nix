# Ghostty settings

{
  config,
  lib,
  ...
}:

{

  xdg.configFile.ghostty = {
    source = ../config/ghostty;
    recursive = true;
  };

}
