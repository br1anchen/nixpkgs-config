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

  xdg.configFile."opencode/AGENTS.md".source = ../config/opencode/AGENTS.md;
  xdg.configFile."opencode/opencode.json".source = ../config/opencode/opencode.json;

  home.activation.linkDotAgentSkills = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    mkdir -p "$HOME/.agent" "$HOME/.claude"

    if [ -e "$HOME/.agent/skills" ] && [ ! -L "$HOME/.agent/skills" ]; then
      rm -rf "$HOME/.agent/skills"
    fi
    if [ -e "$HOME/.claude/skills" ] && [ ! -L "$HOME/.claude/skills" ]; then
      rm -rf "$HOME/.claude/skills"
    fi

    if [ -d "$HOME/.agents/skills" ]; then
      ln -sfn "$HOME/.agents/skills" "$HOME/.agent/skills"
      ln -sfn "$HOME/.agents/skills" "$HOME/.claude/skills"
    fi
  '';
}
