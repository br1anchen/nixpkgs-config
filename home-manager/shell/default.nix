# Shell configuration entrypoint.
#
# macOS configures zsh through Home Manager and keeps the account's /bin/zsh
# login shell. Omarchy keeps its upstream-managed Bash login shell until it
# supports zsh; our additions are sourced from its existing ~/.bashrc.

{
  imports = [
    ./darwin.nix
    ./omarchy.nix
    ./programs.nix
    ./scripts.nix
  ];
}
