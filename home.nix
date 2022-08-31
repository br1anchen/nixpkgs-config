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
in {
  inherit imports;

  fonts.fontconfig.enable = true;

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
    TERMINAL = "kitty";
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
      tree
      wget
      xclip
      zoxide
      (nerdfonts.override { fonts = [ "FiraCode" "JetBrainsMono" ]; })
    ] ++ lib.optionals pkgs.stdenv.isLinux [
      starship # Fancy shell that works with zsh
    ];

}
