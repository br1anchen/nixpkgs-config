{
  lib,
  pkgs,
  inputs,
  ...
}:

let
  skills = ../config/pstack/skills;
  # A dirty tree has no rev; the build is still recorded, as dirtyRev or unknown.
  rev = inputs.self.rev or inputs.self.dirtyRev or "unknown";
in
{
  # Each runtime gets individual links; unrelated skills and directory aliases
  # stay intact. Replaced pstack installs are archived before linking.
  home.activation.syncPstackSkills = lib.hm.dag.entryAfter [ "linkDotAgentSkills" ] ''
    $DRY_RUN_CMD ${pkgs.python3}/bin/python3 ${../scripts/pstack-sync.py} \
      --source ${skills} --home "$HOME" --apply
  '';

  # One row per distinct skills build: epoch, flake rev, skills store path.
  # kitchen runs and feedback map the path they ran from back to a rev. It
  # never fails the switch.
  home.activation.recordPstackBuild = lib.hm.dag.entryAfter [ "syncPstackSkills" ] ''
    if [ -z "''${DRY_RUN:-}" ]; then
      builds="''${XDG_STATE_HOME:-$HOME/.local/state}/pstack/builds.tsv"
      last="$(tail -n 1 "$builds" 2>/dev/null | cut -f3 || true)"
      if [ "$last" != "${skills}" ]; then
        { mkdir -p "$(dirname "$builds")" &&
          printf '%s\t%s\t%s\n' "$(date +%s)" ${lib.escapeShellArg rev} "${skills}" >>"$builds"; } || true
      fi
    fi
  '';
}
