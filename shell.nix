# Shell configuration for zsh

{ config, lib, pkgs, ... }:

let
  # Set all shell aliases programatically
  shellAliases = {
    cat = "bat";
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
    vf = "nvim";
    vd = "nvim .";

    # Reload zsh
    szsh = "source ~/.zshrc";
    szenv = "source ~/.zshenv";

    # Reload tmux
    stmux = "tmux source-file ~/.tmux.conf";

    # Reload home manager and zsh
    reload = "home-manager switch && szenv && szsh && stmux";

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

  home.file.".tool-versions".source = ./config/asdf/tool-versions;

  # zsh settings
  programs.zsh = {
    inherit shellAliases;
    enable = true;
    enableAutosuggestions = true;
    enableCompletion = true;
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
        "asdf"
      ];
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

    envExtra = ''
      # Nix setup (environment variables, etc.)
      if [ -e ~/.nix-profile/etc/profile.d/nix.sh ]; then
        . ~/.nix-profile/etc/profile.d/nix.sh
      fi

      # Load environment variables from a file; this approach allows me to not
      # commit secrets like API keys to Git
      if [ -e ~/.env ]; then
        . ~/.env
      fi

      if command -v pacman > /dev/null; then
        . /opt/asdf-vm/asdf.sh
      else
        . $HOME/.asdf/asdf.sh
      fi

      if [ -e $HOME/.asdf/plugins/java/set-java-home.zsh ]; then
        . $HOME/.asdf/plugins/java/set-java-home.zsh
      fi

      # Rust Cargo
      CARGO_PATH="$HOME/.cargo/bin"
      export PATH="$CARGO_PATH:$PATH"

      # Flutter/Android
      if command -v brew > /dev/null; then
        export ANDROID_HOME="$HOME/Library/Android/Sdk"
        export PATH=$PATH:$ANDROID_HOME/cmdline-tools/latest/bin
        export CHROME_EXECUTABLE="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"

        #Cocoapods
        export GEM_HOME=$HOME/.gem
        export PATH=$GEM_HOME/ruby/2.7.0/bin:$PATH

      elif command -v pacman > /dev/null; then
        export ANDROID_SDK="$HOME/Android/Sdk"
        export ANDROID_NDK_HOME=$ANDROID_SDK/ndk
        export PATH=$ANDROID_SDK/platform-tools:$ANDROID_SDK/cmdline-tools/latest/bin:$PATH
        export CHROME_EXECUTABLE=/usr/bin/chromium

      elif command -v apt > /dev/null; then
        # Export the Android SDK path
        export ANDROID_HOME=~/Android/Sdk
        export PATH=$PATH:$ANDROID_HOME/cmdline-tools/latest/bin
        export CHROME_EXECUTABLE="/usr/bin/firefox"
      else
        echo 'Unknown OS to set Flutter/Android env!'
      fi

      # Dart
      export PATH="$PATH":"$HOME/.pub-cache/bin"

      # GO
      GO_PATH="$HOME/go/bin"
      export PATH="$GO_PATH:$PATH"
    '';

    # Called whenever zsh is initialized
    initExtra = ''
      bindkey -e

      # Start up Starship shell
      eval "$(starship init zsh)"

      eval "$(zoxide init zsh)"

      eval "$(mcfly init zsh)"
    '';
  };
}
