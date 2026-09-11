{ lib, pkgs, ... }:

{
  # Each runtime gets individual links; unrelated skills and directory aliases
  # stay intact. Replaced pstack installs are archived before linking.
  home.activation.syncPstackSkills = lib.hm.dag.entryAfter [ "linkDotAgentSkills" ] ''
    $DRY_RUN_CMD ${pkgs.python3}/bin/python3 ${../scripts/pstack-sync.py} \
      --source ${../config/pstack/skills} --home "$HOME" --apply
  '';
}
