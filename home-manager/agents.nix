# Code agents CLI configuration

{ lib, ... }:

let
  customSkillsDir = ../config/agents/skills;
  customSkillNames = builtins.attrNames (
    lib.filterAttrs (_: type: type == "directory") (builtins.readDir customSkillsDir)
  );
  customSkills = builtins.listToAttrs (
    map (
      name: {
        name = ".agents/skills/${name}";
        value = {
          source = "${toString customSkillsDir}/${name}";
          force = true;
        };
      }
    )
    customSkillNames
  );
in
{
  home.file = {
    ".codex/AGENTS.md" = {
      source = ../config/codex/AGENTS.md;
      force = true;
    };

    ".codex/RTK.md" = {
      source = ../config/codex/RTK.md;
      force = true;
    };

    ".gemini/GEMINI.md".source = ../config/gemini/GEMINI.md;
  } // customSkills;

  # Point ~/.agent/skills and ~/.claude/skills at the repo-managed skill set.
  #
  # A real directory at either path is MOVED ASIDE, never deleted: Omarchy ships
  # its own skills (diagnose-crash, omarchy) under
  # /usr/share/omarchy/default/agents/skills, and agent tools write into these
  # directories themselves. The previous `rm -rf` here would have destroyed
  # whatever was present on the first switch.
  home.activation.linkDotAgentSkills = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    mkdir -p "$HOME/.agent" "$HOME/.claude"

    for target in "$HOME/.agent/skills" "$HOME/.claude/skills"; do
      if [ -e "$target" ] && [ ! -L "$target" ]; then
        backup="$target.bak.$(date +%s)"
        $VERBOSE_ECHO "moving existing $target aside to $backup"
        mv "$target" "$backup"
      fi
    done

    if [ -d "$HOME/.agents/skills" ]; then
      ln -sfn "$HOME/.agents/skills" "$HOME/.agent/skills"
      ln -sfn "$HOME/.agents/skills" "$HOME/.claude/skills"
    fi
  '';
}
