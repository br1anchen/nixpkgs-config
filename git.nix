# Git settings

{ config, lib, pkgs, ... }:

{
  programs.git = {
    enable = true;
    userName = "Brian Chen";
    userEmail = "brianchen8990@gmail.com";
    extraConfig = {
      core = { editor = "nvim"; };
      color = { ui = true; };
      init = { defaultBranch = "main"; };
      pull = { rebase = true; };
      submodule = { recurse = true; };
    };

    delta = {
      enable = true;
      options = {
        navigate = true;
        line-numbers = true;
        syntax-theme = "GitHub";
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
}
