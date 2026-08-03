# Ghostty settings

{ ... }:

{

  xdg.configFile."ghostty/config".text = builtins.readFile ../config/ghostty/config;

}
