# This is your home-manager configuration file
# Use this to configure your home environment (it replaces ~/.config/nixpkgs/home.nix)

{
  lib,
  pkgs,
  ...
}:
{
  imports = [
    # If you want to use home-manager modules from other flakes (such as nix-colors), use something like:
    # inputs.nix-colors.homeManagerModule

    # Feel free to split up your configuration and import pieces of it here.
    ./git.nix
    ./lazyvim.nix
    ./shell.nix
    ./tmux.nix
    ./gitui.nix
    ./alacritty.nix
    ./lazygit.nix
    ./hypr.nix
    ./kitty.nix
    ./wezterm.nix
    ./ghostty.nix
  ];

  fonts.fontconfig.enable = true;

  # Comment out if you wish to disable unfree packages for your system
  nixpkgs.config.allowUnfree = true;
  nixpkgs.config.allowBroken = true;

  # nix settings...use only for single user installs
  nix = {
    package = pkgs.nixVersions.stable;
    settings = {
      experimental-features = [
        "nix-command"
        "flakes"
      ];
    };
  };

  # Add stuff for your user as you see fit:
  # programs.neovim.enable = true;
  # home.packages = with pkgs; [ steam ];

  # Enable home-manager and git
  programs.home-manager.enable = true;
  programs.git.enable = true;

  # Nicely reload system units when changing configs
  systemd.user.startServices = "sd-switch";

  home.packages =
    with pkgs;
    [
      bash
      cachix # Nix build cache
      cheat
      curl # An old classic
      colima
      cocogitto
      docker # World's #1 container tool
      docker-compose
      entr
      eza # ls replacement written in Rust
      fd # find replacement written in Rust
      fswatch
      gitui
      glow
      gnumake
      go
      getopt
      htop # Resource monitoring
      # httpie # Like curl but more user friendly
      jq # JSON parsing for the CLI
      kubectl
      mcfly
      mdcat # Markdown converter/reader for the CLI
      mkcert
      minikube
      nerd-font-patcher
      neofetch
      nix-prefetch-github
      ncdu
      pandoc
      procs
      protobuf
      ripgrep # grep replacement written in Rust
      rustup
      scientifica
      wget
      xclip
      xh
      zoxide
      _1password-cli
      _1password-gui
      nerd-fonts.fira-code
      watchexec
    ]
    ++ lib.optionals pkgs.stdenv.isLinux [
      starship # Fancy shell that works with zsh
    ];
}
