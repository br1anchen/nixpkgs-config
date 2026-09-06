# Home-manager entrypoint.
#
# Layering rule for this repo: the cross-platform ("shared") layer — dev and
# application-level packages and config that exist on both macOS and Omarchy —
# is owned here. The Linux OS layer (Hyprland, bar, terminals-as-system, fonts,
# daemons) belongs to Omarchy and is not managed from Nix.
#
# Delivery differs per platform: macOS gets home-manager symlinks; Omarchy gets
# real file copies pushed by ./scripts/dotfiles-sync.sh, because Omarchy's own
# write paths (`cp -f` in `omarchy refresh config`, `sed -i` in migrations) do
# not respect symlinks and corrupt them silently.

{
  lib,
  pkgs,
  isDarwin,
  isOmarchy,
  ...
}:
{
  imports = [
    ./dotfiles.nix
    ./git.nix
    ./lazyvim.nix
    ./shell.nix
    ./worktrees.nix
    ./agents.nix
    ./agent-workflow.nix
    ./tmux.nix
    ./lazygit.nix
  ];

  # Omarchy owns fonts on Linux (ttf-jetbrains-mono-nerd-basic, which its themes
  # reference) and writes ~/.config/fontconfig/fonts.conf wholesale via
  # `omarchy font set`. Registering a second nix fontconfig path there fights it.
  fonts.fontconfig.enable = isDarwin;

  nixpkgs.config.allowUnfree = true;

  # Single-user nix settings only. On Omarchy nix comes from pacman and runs as a
  # multi-user daemon, so gc lives in a systemd timer and experimental-features
  # in /etc/nix/nix.conf; setting them here would fight the system installation.
  nix = lib.mkIf isDarwin {
    gc = {
      automatic = true;
      dates = "daily";
      options = "--delete-older-than 14d";
    };
    package = pkgs.nixVersions.stable;
    settings = {
      experimental-features = [
        "nix-command"
        "flakes"
      ];
    };
  };

  programs.home-manager.enable = true;

  systemd.user.startServices = "sd-switch";

  home.packages =
    with pkgs;
    [
      bob-nvim # Neovim version manager; owns the nvim binary on both platforms
      cachix # Nix build cache
      cheat
      cocogitto
      eza # ls replacement written in Rust
      fd # find replacement written in Rust
      gnumake
      jq # JSON parsing for the CLI
      mdcat # Markdown converter/reader for the CLI
      mkcert
      fastfetch
      nix-prefetch-github
      ncdu
      pandoc
      procs
      prime-agent
      protobuf
      ripgrep # grep replacement written in Rust
      rtk
      rustup
      starship
      watchexec
      weave
      wget
      xh
      zoxide
      _1password-cli
    ]
    ++ lib.optionals isDarwin [
      # Carve-out: these shadow system binaries that Omarchy's shell chain and
      # scripts depend on (bash is the login shell; omarchy scripts call
      # util-linux getopt; gnupg bakes agent socket paths at build time), so on
      # Linux they stay with pacman.
      bash
      curl
      getopt
      gnupg
      gnutar

      # Daemon-backed: need systemd units, /etc/containers, subuid/subgid or a
      # socket that a non-NixOS nix profile cannot provide. pacman owns these
      # on Omarchy.
      docker
      docker-compose
      podman
      tailscale

      nerd-fonts.fira-code
    ]
    ++ lib.optionals isOmarchy [
      google-cloud-sdk # gcloud CLI; macOS gets it from Homebrew (see shell.nix)
      wl-clipboard # Wayland replacement for xclip
    ];
}
