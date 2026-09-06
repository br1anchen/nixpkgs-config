# Git tooling.
#
# Config content lives in config/git/{config,ignore} and is delivered by
# ./dotfiles.nix (symlink on macOS, dotfiles-sync push on Omarchy). The
# programs.git / programs.delta modules are NOT used: they render into
# ~/.config/git/config, which on Omarchy is the file `git config --global`
# resolves to (there is no ~/.gitconfig) and which Omarchy's installer writes.

{ pkgs, ... }:
{
  home.packages = with pkgs; [
    git
    delta
    diff-so-fancy
    gitflow
    git-cliff
    jujutsu
    jj-spr
    lazyjj
    glab
    # `gh` is deliberately absent: Omarchy installs it as a global mise tool and
    # mise's shim dir is PREPENDED to PATH, so a nix gh could never win anyway.
  ];
}
