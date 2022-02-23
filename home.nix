{ config, lib, ... }:

let
  # TODO: remove maneul fix for ipython
  # https://github.com/NixOS/nixpkgs/issues/160133
  ipythonFix = self: super: {
    python3 = super.python3.override {
      packageOverrides = pySelf: pySuper: {
        ipython = pySuper.ipython.overridePythonAttrs (old: {
          preCheck = old.preCheck
            + super.lib.optionalString super.stdenv.isDarwin ''
              echo '#!${pkgs.stdenv.shell}' > pbcopy
              chmod a+x pbcopy
              cp pbcopy pbpaste
              export PATH="$(pwd)''${PATH:+":$PATH"}"
            '';
        });
      };
      self = self.python3;
    };
  };
  nigpkgsRev = "nixpkgs-unstable";
  pkgs = import (fetchTarball
    "https://github.com/nixos/nixpkgs/archive/${nigpkgsRev}.tar.gz") {
      overlays = [ ipythonFix ];
    };

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
    cachix # Nix build cache
    cheat
    curl # An old classic
    docker # World's #1 container tool
    exa # ls replacement written in Rust
    fd # find replacement written in Rust
    gh
    gitui
    glow
    go
    htop # Resource monitoring
    httpie # Like curl but more user friendly
    jq # JSON parsing for the CLI
    mcfly
    mdcat # Markdown converter/reader for the CLI
    nix-prefetch-github
    procs
    protobuf
    ripgrep # grep replacement written in Rust
    rustup
    starship # Fancy shell that works with zsh
    wget
    xclip
    zoxide
  ];

}
