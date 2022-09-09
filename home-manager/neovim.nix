# Neovim settings

{ config, lib, pkgs, ... }:

{

  home.packages = with pkgs; [
    rnix-lsp
    stylua
    luajitPackages.luacheck
    nixfmt
    shellcheck
    shfmt
    statix
    code-minimap
    sqlfluff
    black
    zathura
    python39Packages.pynvim
    python39Packages.jupyter
    python39Packages.ueberzug
    python39Packages.pillow
    python39Packages.cairosvg
    python39Packages.plotly
  ];

  xdg.configFile.nvim = {
    source = ~/nixpkgs-config/config/neovim;
    recursive = true;
  };

  # xdg.configFile."nvim/init.vim".text = ''
  #   luafile ~/.config/nvim/init.lua
  # '';

}
