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
    ./lazygit.nix
    ./kitty.nix
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

  ghpr = pkgs.writeScriptBin "ghpr" ''
    GH_FORCE_TTY=100% gh pr list \
    | fzf --ansi --preview 'GH_FORCE_TTY=100% gh pr view {1}' --preview-window down --header-lines 3 \
    | awk '{print $1}' \
    | xargs gh pr checkout
  '';

  scripts = [ depends git-hash run wo ghpr ];

  gitTools = with pkgs.gitAndTools; [ diff-so-fancy git-codeowners gitflow gh ];

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

  home.packages = with pkgs;
    [
      cachix # Nix build cache
      cheat
      curl # An old classic
      docker # World's #1 container tool
      exa # ls replacement written in Rust
      fd # find replacement written in Rust
      gitui
      glow
      go
      htop # Resource monitoring
      # httpie # Like curl but more user friendly
      jq # JSON parsing for the CLI
      mcfly
      mdcat # Markdown converter/reader for the CLI
      nix-prefetch-github
      ncdu
      procs
      protobuf
      ripgrep # grep replacement written in Rust
      rustup
      wget
      xclip
      zoxide
    ] ++ scripts ++ gitTools ++ lib.optionals pkgs.stdenv.isLinux [
      starship # Fancy shell that works with zsh
    ];

}
