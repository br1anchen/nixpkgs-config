# Code agents CLI configuration

{ ... }:

{
  home.file.".codex" = {
    source = ../config/codex;
    recursive = true;
  };

  home.file.".gemini/GEMINI.md".source = ../config/gemini/GEMINI.md;
}
