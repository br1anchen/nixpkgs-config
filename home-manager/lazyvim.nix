# Neovim (LazyVim).
#
# The config itself is the config/lazyvim submodule, delivered by ./dotfiles.nix.
# Omarchy's own `omarchy-nvim` package is removed on this host: while installed,
# it owns ~9,982 files under /etc/skel and `omarchy reinstall configs`
# (`cp -af /etc/skel/. ~/`) would bulldoze this config.

{ pkgs, ... }:

let
  # Providers get their own interpreters instead of going on PATH, so mise
  # keeps owning `node`/`python3` for projects.
  neovimPython = pkgs.python3.withPackages (ps: [ ps.pynvim ]);
in
{
  home.packages = with pkgs; [
    lua5_1 # lazy.nvim/luarocks need a 5.1 interpreter
    luajitPackages.luarocks
    luajitPackages.luacheck
    nixfmt
    pyright
    ruff
    shellcheck
    statix
    stylelint
    code-minimap
    tree-sitter
  ];

  # Read back in `config/lazyvim/lua/config/options.lua`.
  home.sessionVariables = {
    NVIM_NODE_HOST_PROG = "${pkgs.neovim-node-client}/bin/neovim-node-host";
    NVIM_PYTHON3_HOST_PROG = "${neovimPython}/bin/python3";
  };
}
