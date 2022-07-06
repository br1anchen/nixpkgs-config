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
    jupyter
    black
    python39Packages.pyqt5
    python39Packages.qtconsole
    python39Packages.jupytext
    python39Packages.ipython
    python39Packages.ipykernel
    python39Packages.matplotlib-inline
    python39Packages.matplotlib
    python39Packages.numpy
    python39Packages.pandas
    python39Packages.scipy
    python39Packages.scikit-learn
    python39Packages.joblib
  ];

  xdg.configFile.nvim = {
    source = ./config/neovim;
    recursive = true;
  };

}
