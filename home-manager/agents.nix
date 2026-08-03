# Code agents CLI configuration

{ ... }:

{
  home.file.".codex/AGENTS.md" = {
    source = ../config/codex/AGENTS.md;
    force = true;
  };

  home.file.".codex/RTK.md" = {
    source = ../config/codex/RTK.md;
    force = true;
  };

  home.file.".gemini/GEMINI.md".source = ../config/gemini/GEMINI.md;

  home.file.".agents/skills/github-child-issue-loop" = {
    source = ../config/agents/skills/github-child-issue-loop;
    force = true;
  };

  home.file.".agents/skills/git-epic-worktree" = {
    source = ../config/agents/skills/git-epic-worktree;
    force = true;
  };

  home.file.".agents/skills/grill-with-types" = {
    source = ../config/agents/skills/grill-with-types;
    force = true;
  };

  home.file.".agents/skills/jj-epic-workspace" = {
    source = ../config/agents/skills/jj-epic-workspace;
    force = true;
  };

  home.file.".agents/skills/unit-testing-best-practices" = {
    source = ../config/agents/skills/unit-testing-best-practices;
    force = true;
  };

  xdg.configFile."opencode/AGENTS.md".source = ../config/opencode/AGENTS.md;
  xdg.configFile."opencode/opencode.json".source = ../config/opencode/opencode.json;
}
