# Shell configuration for zsh

{ config, lib, pkgs, ... }:

let
  # Set all shell aliases programatically
  shellAliases = {
    cat = "bat";
    diff = "diff --color=auto";
    dc = "docker-compose";
    dk = "docker";
    find = "fd";
    grep = "grep --color=auto";
    hms = "home-manager switch";
    l = "exa";
    ll = "ls -lh";
    ls = "exa";
    lg = "lazygit";
    md = "mdcat";
    start-docker = "docker-machine start default";
    vim = "nvim";

    # Reload zsh
    szsh = "source ~/.zshrc";

    # Reload home manager and zsh
    reload = "home-manager switch && source ~/.zshrc";

    # Nix garbage collection
    garbage = "nix-collect-garbage -d && docker image prune --force";

    # See which Nix packages are installed
    installed = "nix-env --query --installed";
  };

in {
  # Fancy filesystem navigator
  programs.broot = {
    enable = true;
    enableZshIntegration = true;
  };

  programs.bat = {
    enable = true;
    config = {
      theme = "base16";
      italic-text = "always";
    };
  };

  programs.fzf = {
    enable = true;
    enableBashIntegration = true;
    enableZshIntegration = true;
    defaultCommand = "${pkgs.ripgrep}/bin/rg --files";
  };

  # zsh settings
  programs.zsh = {
    inherit shellAliases;
    enable = true;
    enableAutosuggestions = true;
    enableCompletion = false;
    history.extended = true;

    oh-my-zsh = {
      enable = true;
      plugins = [
        "docker"
        "docker-compose"
        "dotenv"
        "git"
        "sudo"
        "node"
        "tmux"
        "zsh-completions"
        "zsh-autosuggestions"
        "zsh-syntax-highlighting"
      ];
    };

    localVariables = {
      # TMUX
      # Automatically start tmux
      ZSH_TMUX_AUTOSTART = true;

      # Automatically connect to a previous session if it exists
      ZSH_TMUX_AUTOCONNECT = true;

      # Enable command auto-correction.
      ENABLE_CORRECTION = "true";

      # Display red dots whilst waiting for completion.
      COMPLETION_WAITING_DOTS = "true";

      EDITOR = "nvim";
      VISUAL = "nvim";
      NVIM_TUI_ENABLE_TRUE_COLOR = 1;
      TERM = "screen-256color";
      LANG = "en_US.UTF-8";
      LC_ALL = "en_US.UTF-8";
    };

    # Called whenever zsh is initialized
    initExtra = ''
      bindkey -e

      # Nix setup (environment variables, etc.)
      if [ -e ~/.nix-profile/etc/profile.d/nix.sh ]; then
        . ~/.nix-profile/etc/profile.d/nix.sh
      fi

      # Load environment variables from a file; this approach allows me to not
      # commit secrets like API keys to Git
      if [ -e ~/.env ]; then
        . ~/.env
      fi

      # Add RVM to PATH for scripting. Make sure this is the last PATH variable change.
      RVM_PATH="$HOME/.rvm/bin"

      # Rust Cargo
      CARGO_PATH="$HOME/.cargo/bin"

      # fnm
      FNM_PATH="$HOME/.fnm"

      # elixir
      ELIXI_PATH="/usr/lib/elixir/bin"

      # Android
      export ANDROID_SDK="$HOME/Android/Sdk"
      ANDROID_PLATFORM_PATH="$HOME/Android/Sdk/platform-tools"

      export FLUTTER_PUB="$HOME/snap/flutter/common/flutter/.pub-cache/bin"

      export CHROME_EXECUTABLE="/usr/bin/brave"

      export PYENV_ROOT="$HOME/.pyenv"

      GO_PATH="$HOME/go/bin"

      export PATH="$RVM_PATH:$CARGO_PATH:$FNM_PATH:$ELIXI_PATH:$ANDROID_PLATFORM_PATH:$PYENV_ROOT/bin:$GO_PATH:$PATH"

      # Start up Starship shell
      eval "$(starship init zsh)"

      eval "`fnm env`"

      eval "$(zoxide init zsh)"

    '';
  };
}
