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
    la = "ls -lha";
    lg = "lazygit";
    md = "mdcat";
    start-docker = "docker-machine start default";
    vim = "nvim";

    # Reload zsh
    szsh = "source ~/.zshrc";

    # Reload tmux 
    stmux = "tmux source-file ~/.tmux.conf";

    # Reload home manager and zsh
    reload = "home-manager switch && szsh && stmux";

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
      plugins =
        [ "docker" "docker-compose" "dotenv" "git" "sudo" "node" "tmux" ];
    };

    plugins = [
      {
        name = "zsh-completions";
        src = pkgs.fetchFromGitHub {
          owner = "zsh-users";
          repo = "zsh-completions";
          rev = "b3876c59827c0f3365ece26dbe7c0b0b886b63bb";
          sha256 = "nfbOkHyH9wxcMF8V6zuDSFCyI8rqONEYrURogG3U9UA=";
          fetchSubmodules = true;
        };
      }
      {
        name = "zsh-autosuggestions";
        src = pkgs.fetchFromGitHub {
          owner = "zsh-users";
          repo = "zsh-autosuggestions";
          rev = "a411ef3e0992d4839f0732ebeb9823024afaaaa8";
          sha256 = "KLUYpUu4DHRumQZ3w59m9aTW6TBKMCXl2UcKi4uMd7w=";
          fetchSubmodules = true;
        };
      }
      {
        name = "zsh-syntax-highlighting";
        src = pkgs.fetchFromGitHub {
          owner = "zsh-users";
          repo = "zsh-syntax-highlighting";
          rev = "c7caf57ca805abd54f11f756fda6395dd4187f8a";
          sha256 = "YbNwQ960OTVuX+MBy5nFzFUlF0+HTSyoYtEg+/adSos=";
          fetchSubmodules = true;
        };
      }
    ];

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

      # Flutter/Android
      if command -v brew > /dev/null; then
        export ANDROID_HOME=/usr/local/share/android-commandlinetools
        export PATH=$ANDROID_HOME:$PATH
        export AVD=/usr/local/bin/avdmanager
        export PATH=$AVD:$PATH
        export SDK_MANAGER=/usr/local/bin/sdkmanager
        export PATH=$SDK_MANAGER:$PATH
        export ADB=/usr/local/bin/adb
        export PATH=$ADB:$PATH

        # Java
        export JABBA_VERSION="0.11.2"
        [ -s "/Users/$(whoami)/.jabba/jabba.sh" ] && source "/Users/$(whoami)/.jabba/jabba.sh"
        export JAVA_HOME=/Users/$(whoami)/.jabba/jdk/openjdk@1.16.0/Contents/Home
        export PATH=$JAVA_HOME:$PATH

        # Gradle
        export GRADLE_HOME=/usr/local/Cellar/gradle/7.3.3
        export PATH=$GRADLE_HOME/bin:$PATH
      elif command -v pacman > /dev/null; then
        export ANDROID_SDK="$HOME/Android/Sdk"
        ANDROID_PLATFORM_PATH="$ANDROID_SDK/platform-tools"
        export PATH=$ANDROID_PLATFORM_PATH:$PATH
        export FLUTTER_PUB="$HOME/snap/flutter/common/flutter/.pub-cache/bin"
        export CHROME_EXECUTABLE="/usr/bin/brave"
      else
          echo 'Unknown OS!'
      fi

      # Python
      eval "$(pyenv init -)"
      PYENV_ROOT="$HOME/.pyenv"

      # GO
      GO_PATH="$HOME/go/bin"

      export PATH="$RVM_PATH:$CARGO_PATH:$FNM_PATH:$ELIXI_PATH:$PYENV_ROOT/bin:$GO_PATH:$PATH"

      # Start up Starship shell
      eval "$(starship init zsh)"

      eval "$(fnm env --use-on-cd)"

      eval "$(zoxide init zsh)"

    '';
  };
}
