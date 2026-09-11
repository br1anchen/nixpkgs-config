# Shared dotfiles delivery.
#
# One manifest (../dotfiles/manifest.tsv), two delivery mechanisms:
#
#   macOS   - home-manager symlinks, the normal declarative path.
#   Omarchy - this module writes nothing. Omarchy's own write paths corrupt
#             symlinks silently (`cp -f` writes THROUGH them into the repo,
#             `sed -i` REPLACES them with regular files, and a read-only
#             /nix/store symlink is unlinked and replaced), so the live file is
#             authoritative and `dotfiles-sync` moves content explicitly.
#
# ACCEPTED EXCEPTIONS on Omarchy. This module writes nothing, but home-manager's
# programs.* modules and its own infrastructure still create symlinks under
# ~/.config. These are accepted deliberately: every path below is one Omarchy
# never reads or writes, so there is nothing for it to corrupt and nothing for
# dotfiles-sync to reconcile.
#
#   programs.broot   -> broot/{conf,verbs}.hjson, broot/skins/*, broot/launcher/
#   programs.bat     -> bat/config   (Omarchy's BAT_THEME=ansi overrides it anyway)
#   agent-workflow   -> opencode/plugins/herdr-agent-state.js
#                       nvim/after/plugin/herdr_nav.lua
#   home-manager     -> environment.d/10-home-manager.conf, systemd/user/tray.target
#
# The rule that matters is narrower than "nothing under ~/.config": no file that
# Omarchy reads, writes, migrates or themes may be a home-manager symlink.

{
  lib,
  pkgs,
  isDarwin,
  ...
}:
let
  platform = if isDarwin then "darwin" else "omarchy";

  manifestLines = lib.filter (
    l: l != "" && !(lib.hasPrefix "#" l)
  ) (map (lib.removeSuffix "\r") (lib.splitString "\n" (builtins.readFile ../dotfiles/manifest.tsv)));

  parse =
    line:
    let
      f = lib.splitString "\t" line;
    in
    {
      repo = lib.elemAt f 0;
      live = lib.elemAt f 1;
      kind = lib.elemAt f 2;
      platforms = lib.elemAt f 3;
    };

  entries = lib.filter (
    e: e.platforms == "both" || e.platforms == platform
  ) (map parse manifestLines);

  toHomeFile = e: {
    name = e.live;
    value = {
      source = ../. + "/${e.repo}";
      recursive = e.kind == "dir";
    };
  };

  dotfilesSync = pkgs.writeShellScriptBin "dotfiles-sync" (builtins.readFile ../scripts/dotfiles-sync.sh);
in
{
  # macOS: declarative symlinks. Omarchy: deliberately empty.
  home.file = lib.mkIf isDarwin (builtins.listToAttrs (map toHomeFile entries));

  # Available on both so `dotfiles-sync status` works anywhere; `push` refuses
  # to run on macOS, where home-manager owns these paths.
  home.packages = [ dotfilesSync ];
}
