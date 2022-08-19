# This is your home-manager configuration file
# Use this to configure your home environment (it replaces ~/.config/nixpkgs/home.nix)

{ inputs, lib, config, pkgs, ... }: {
  imports = [
    # If you want to use home-manager modules from other flakes (such as nix-colors), use something like:
    # inputs.nix-colors.homeManagerModule

    # Feel free to split up your configuration and import pieces of it here.
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

  # Comment out if you wish to disable unfree packages for your system
  nixpkgs.config.allowUnfree = true;
  nixpkgs.config.allowBroken = true;

  home = {
    username = "br1anchen";
    homeDirectory =
      if pkgs.stdenv.isDarwin then "/Users/br1anchen" else "/home/br1anchen";
    # https://nixos.wiki/wiki/FAQ/When_do_I_update_stateVersion
    stateVersion = "22.05";
    sessionVariables = {
      EDITOR = "nvim";
      TERMINAL = "kitty";
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
    ] ++ lib.optionals pkgs.stdenv.isLinux [
      starship # Fancy shell that works with zsh
    ];
}
