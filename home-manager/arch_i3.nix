# Manjaro/Arch settings

{
  xdg = {
    configFile = {
      i3 = {
        source = ../config/i3-endeavouros;
        recursive = true;
      };

      polybar = {
        source = ../config/polybar;
        recursive = true;
      };

      dunst = {
        source = ../config/dunst;
        recursive = true;
      };
    };
  };

  #
  # xdg.configFile."networkmanager-dmenu" = {
  #   source = ./config/networkmanager-dmenu;
  #   recursive = true;
  # };
}
