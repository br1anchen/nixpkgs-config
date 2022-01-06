{ config, lib, ... }:

let
  nigpkgsRev = "nixpkgs-unstable";
  pkgs = import (fetchTarball
    "https://github.com/nixos/nixpkgs/archive/${nigpkgsRev}.tar.gz") { };

  # Import other Nix files
  imports = [
    ./git.nix
    ./neovim.nix
    ./shell.nix
    ./tmux.nix
    ./gitui.nix
    ./alacritty.nix
  ] ++ lib.optionals pkgs.stdenv.isLinux [ ./arch_i3.nix ]
    ++ lib.optionals pkgs.stdenv.isDarwin [ ./mac.nix ];

  # Handly shell command to view the dependency tree of Nix packages
  depends = pkgs.writeScriptBin "depends" ''
    dep=$1
    nix-store --query --requisites $(which $dep)
  '';

  git-hash = pkgs.writeScriptBin "git-hash" ''
    nix-prefetch-url --unpack https://github.com/$1/$2/archive/$3.tar.gz
  '';

  wo = pkgs.writeScriptBin "wo" ''
    readlink $(which $1)
  '';

  run = pkgs.writeScriptBin "run" ''
    nix-shell --pure --run "$@"
  '';

  scripts = [ depends git-hash run wo ];

  gitTools = with pkgs.gitAndTools; [
    delta
    diff-so-fancy
    git-codeowners
    gitflow
    gh
  ];

in {
  inherit imports;

  # Let Home Manager install and manage itself.
  programs.home-manager.enable = true;

  home = {
    username = "br1anchen";
    homeDirectory =
      if pkgs.stdenv.isDarwin then "/Users/br1anchen" else "/home/br1anchen";
    stateVersion = "22.05";
  };

  home.sessionVariables = {
    EDITOR = "nvim";
    TERMINAL = "alacritty";
  };

  home.packages = with pkgs; [
    bash # /bin/bash
    cachix # Nix build cache
    cargo
    curl # An old classic
    docker # World's #1 container tool
    docker-compose # Local multi-container Docker environments
    exa # ls replacement written in Rust
    fd # find replacement written in Rust
    fnm
    gitui
    gh
    go
    htop # Resource monitoring
    httpie # Like curl but more user friendly
    jq # JSON parsing for the CLI
    kitty
    lazygit
    luajitPackages.luacheck
    mdcat # Markdown converter/reader for the CLI
    neovim
    nix-prefetch-github
    nixfmt
    nodejs # node and npm
    ripgrep # grep replacement written in Rust
    rnix-lsp
    shellcheck
    shfmt
    starship # Fancy shell that works with zsh
    stylua
    yarn # Node.js package manager
    zoxide
  ];

}
