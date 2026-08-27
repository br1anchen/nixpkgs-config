# Git settings

{ pkgs, ... }:
let
  gitTools = with pkgs; [
    diff-so-fancy
    gitflow
    gh
    git-cliff
    jujutsu
    jj-spr
    lazyjj
    glab
  ];
in
{

  home.packages = gitTools;

  programs.git = {
    enable = true;
    settings = {
      user = {
        name = "Brian Chen";
        email = "brianchen8990@gmail.com";
      };
      core = {
        editor = "nvim";
        ignorecase = false;
      };
      color = {
        ui = true;
      };
      init = {
        defaultBranch = "main";
      };
      pull = {
        rebase = true;
      };
      submodule = {
        recurse = true;
      };
    };

    ignores = [
      "*.com"
      "*.class"
      "*.dll"
      "*.exe"
      "*.o"
      "*.so"
      "*.7z"
      "*.dmg"
      "*.gz"
      "*.iso"
      "*.jar"
      "*.rar"
      "*.tar"
      "*.zip"
      "log/"
      "*.log"
      ".DS_Store"
      ".DS_Store?"
      "._*"
      ".Spotlight-V100"
      ".Trashes"
      "ehthumbs.db"
      "Thumbs.db"
      "npm-debug.log"
      ".tern-project"
      "*~"
      ".vim/"
      "tags"
      "tags*"
      ".vscode/"
      ".elixir_ls/"
      "_esy/"
      ".netrwhist"
    ];
  };

  programs.delta = {
    enable = true;
    enableGitIntegration = true;
    options = {
      navigate = true;
      line-numbers = true;
      syntax-theme = "base16";
    };
  };

  xdg.configFile.jj = {
    source = ../config/jj;
    recursive = true;
  };
}
