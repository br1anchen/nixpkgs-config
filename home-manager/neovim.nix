# Neovim settings

{ config, lib, pkgs, ... }:

{

  home.packages = with pkgs;
    [
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
    ] ++ lib.optionals pkgs.stdenv.isLinux [ python39Packages.cairosvg ];

  xdg.configFile.nvim = {
    source = ~/nixpkgs-config/config/neovim;
    recursive = true;
  };

  xdg.configFile.helix = {
    source = ../config/helix;
    recursive = true;
  };

  # xdg.configFile."nvim/init.vim".text = ''
  #   luafile ~/.config/nvim/init.lua
  # '';

}
