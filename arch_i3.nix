# Manjaro/Arch settings

{
  xdg.configFile.i3 = {
    source = ./config/i3;
    recursive = true;
  };

  xdg.configFile.polybar = {
    source = ./config/polybar;
    recursive = true;
  };

  xdg.configFile."networkmanager-dmenu" = {
    source = ./config/networkmanager-dmenu;
    recursive = true;
  };
}
