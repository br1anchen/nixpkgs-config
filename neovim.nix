# Neovim settings

{ config, lib, pkgs, ... }:

{

  home.packages = with pkgs; [
    luajitPackages.luarocks
    nixfmt
    statix
    code-minimap
    jupyter
    zathura
    python39Packages.pynvim
    python39Packages.ueberzug
    python39Packages.pillow
    python39Packages.plotly
  ];

  xdg.configFile.nvim = {
    source = ./config/neovim;
    recursive = true;
  };

}
