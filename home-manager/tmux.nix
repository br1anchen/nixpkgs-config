# tmux.
#
# Config is Omarchy's, vendored to config/tmux/tmux.conf and delivered by
# ./dotfiles.nix. programs.tmux is not used (it would render a second, competing
# ~/.config/tmux/tmux.conf), and the old ~/.tmux.conf oh-my-tmux drop is gone:
# tmux reads ~/.tmux.conf in preference to the XDG path, so it silently won.
#
# Omarchy's config is required rather than merely preferred: SUPER+ALT+K and
# `bind ?` render the `-N` descriptions from it, and its `extended-keys csi-u`
# is what the terminals' \e[13;2u Shift+Enter sequence is aimed at.

{ pkgs, ... }:
{
  home.packages = [ pkgs.tmux ];
}
