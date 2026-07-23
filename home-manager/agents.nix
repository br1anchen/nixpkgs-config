# Code agents CLI configuration

{ ... }:

{
  home.file.".codex" = {
    source = ../config/codex;
    recursive = true;
    force = true;
  };

  home.file.".gemini/GEMINI.md".source = ../config/gemini/GEMINI.md;

  home.file.".agents/skills/github-child-issue-loop" = {
    source = ../config/agents/skills/github-child-issue-loop;
    force = true;
  };

  xdg.configFile.opencode = {
    source = ../config/opencode;
    recursive = true;
  };
}
