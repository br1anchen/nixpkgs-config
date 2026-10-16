{
  lib,
  pkgs,
  inputs,
  ...
}:

let
  # Pstack lives in github:br1anchen/open-pstack, pinned by flake.lock.
  skills = "${inputs.pstack}/skills";
  # The open-pstack rev that built the skills; a local path override has none.
  rev = inputs.pstack.rev or inputs.pstack.dirtyRev or "unknown";
in
{
  # Each runtime gets individual links; unrelated skills and directory aliases
  # stay intact. Replaced pstack installs are archived before linking.
  home.activation.syncPstackSkills = lib.hm.dag.entryAfter [ "linkDotAgentSkills" ] ''
    $DRY_RUN_CMD ${pkgs.python3}/bin/python3 ${inputs.pstack}/scripts/pstack-sync.py \
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
