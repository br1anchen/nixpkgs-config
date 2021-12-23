# tmux settings

{ config, lib, pkgs, ... }:

{
  programs.tmux = { enable = true; };

  home.file.".tmux.conf".source = ./config/tmux/.tmux.conf;
  home.file.".tmux.conf.local".source = ./config/tmux/.tmux.conf.local;
}
