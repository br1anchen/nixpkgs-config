{ config, pkgs, ... }:

{
  # Home Manager needs a bit of information about you and the
  # paths it should manage.
  home.username = "br1anchen";
  home.homeDirectory = "/home/br1anchen";

  # This value determines the Home Manager release that your
  # configuration is compatible with. This helps avoid breakage
  # when a new Home Manager release introduces backwards
  # incompatible changes.
  #
  # You can update Home Manager without changing this value. See
  # the Home Manager release notes for a list of state version
  # changes in each release.
  home.stateVersion = "22.05";

  # Let Home Manager install and manage itself.
  programs.home-manager.enable = true;

  home.packages = with pkgs; [ ripgrep fzf cachix rnix-lsp nixfmt ];

  xdg.configFile.nvim = {
    source = ./config/neovim;
    recursive = true;
  };

  programs.bat = {
    enable = true;
    config = {
      theme = "base16";
      italic-text = "always";
    };
  };

  programs.git = {
    enable = true;
    userName = "Brian Chen";
    userEmail = "brianchen8990@gmailcom";
    extraConfig = {
      core = { editor = "nvim"; };
      color = { ui = true; };
      init = { defaultBranch = "main"; };
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
      "*.sql"
      "*.sqlite"
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
