# lazygit. Config lives in config/lazygit/config.yml, delivered by ./dotfiles.nix.
# Omarchy ships a zero-byte placeholder at this path, so nothing is lost by
# taking ours. Its theme block already uses named ANSI colors, so it follows
# `omarchy theme set` correctly.

{ pkgs, ... }:
{
  home.packages = [ pkgs.lazygit ];
}
