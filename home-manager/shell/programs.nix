{
  pkgs,
  isDarwin,
  ...
}:

{
  programs = {
    direnv = {
      enable = true;
      enableZshIntegration = isDarwin;
    };

    broot = {
      enable = true;
      enableZshIntegration = isDarwin;
    };

    bat = {
      enable = true;
      config = {
        # Follow the terminal palette on both platforms.
        theme = "ansi";
        italic-text = "always";
      };
    };

    fzf = {
      enable = true;
      # Omarchy sources /usr/share/fzf/{completion,key-bindings}.bash itself.
      enableBashIntegration = false;
      enableZshIntegration = isDarwin;
      defaultCommand = "${pkgs.ripgrep}/bin/rg --files";
    };

    skim.enable = true;
  };
}
