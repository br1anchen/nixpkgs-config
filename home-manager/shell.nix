# Shell configuration for zsh

{ config, lib, pkgs, ... }:

let

  # Handly shell command to view the dependency tree of Nix packages
  depends = pkgs.writeScriptBin "depends" ''
    dep=$1
    nix-store --query --requisites $(which $dep)
  '';

  git-hash = pkgs.writeScriptBin "git-hash" ''
    nix-prefetch-url --unpack https://github.com/$1/$2/archive/$3.tar.gz
  '';

  wo = pkgs.writeScriptBin "wo" ''
    readlink $(which $1)
  '';

  run = pkgs.writeScriptBin "run" ''
    nix-shell --pure --run "$@"
  '';

  ghpr = pkgs.writeScriptBin "ghpr" ''
    GH_FORCE_TTY=100% gh pr list \
    | fzf --ansi --preview 'GH_FORCE_TTY=100% gh pr view {1}' --preview-window down --header-lines 3 \
    | awk '{print $1}' \
    | xargs gh pr checkout
  '';

  nixFlakes = pkgs.writeScriptBin "nixFlakes" ''
    exec ${pkgs.nixUnstable}/bin/nix --experimental-features "nix-command flakes" "$@"
  '';

  gwtInit = pkgs.writeScriptBin "gwtInit" ''
    url=$1
    name=''${2:-$(basename $url)}

    git clone --bare --no-checkout $url $name
    cd $name
    git config remote.origin.fetch '+refs/heads/*:refs/remotes/origin/*'
    git fetch
    git for-each-ref --format='%(refname:short)' refs/heads | xargs -n1 -I{} git branch --set-upstream-to=origin/{} {}
  '';

  gwtBare = pkgs.writeScriptBin "gwtBare" ''
    git worktree list \
    | grep 'bare'  \
    | awk '{print $1}'
  '';

  gwtBranch = pkgs.writeScriptBin "gwtBranch" ''
    branch=$(git worktree list | fzf --ansi | awk '{print $1}')

    if [[ -z "$branch" ]]; then
      echo $(pwd)
    else
      echo $branch
    fi
  '';

  checkBareRoot = ''
    bare=$(git worktree list | grep 'bare' | awk '{print $1}')
    current=$(pwd)
    if [ "$current" != "$bare" ]; then
      echo "Cannot run gwt command under directory other than bare repo root"
      exit 1
    fi

  '';

  gwtNewBranch = pkgs.writeScriptBin "gwtNewBranch" ''
    ${checkBareRoot}

    branch=$1
    baseBranch=$2

    git worktree add -b $branch $branch $baseBranch
    git push -u origin $branch
  '';

  gwtCheckoutBranch = pkgs.writeScriptBin "gwtCheckoutBranch" ''
    ${checkBareRoot}

    git fetch

    remote=$(git remote -v | grep 'fetch' | awk '{print $1}')
    branch=$(git branch -r | fzf --ansi | awk '{print $1}' | sed "s/$remote\/\(.*\)/\1/")

    if [[ -z "$branch" ]]; then
      echo "Missing branch"
      exit 1
    elif git show-ref -q --heads "$branch"; then
      git worktree add $branch $branch
    else
      git worktree add --track -b $branch $branch $remote/$branch
    fi
  '';

  gwtDeleteBranch = pkgs.writeScriptBin "gwtDeleteBranch" ''
    ${checkBareRoot}

    branch=$(git worktree list | fzf --ansi | awk '{print $3}' | sed 's/.*\[\([^]]*\)].*/\1/')

    if [[ -z "$branch" ]]; then
      echo "Missing branch"
      exit 1
    else
      git worktree remove --force ./$branch
      git branch -D $branch
    fi
  '';

  gwtCheckoutPR = pkgs.writeScriptBin "gwtCheckoutPR" ''
    ${checkBareRoot}

    git fetch

    gh pr list \
    | fzf --ansi --preview 'GH_FORCE_TTY=100% gh pr view {1}' --preview-window down \
    | awk -F'\t' '{print $3}' \
    | xargs -I{} git worktree add {} {}
  '';

  ghClone = pkgs.writeScriptBin "ghClone" ''
    gh repo list \
    | fzf --ansi \
    | awk '{print $1}' \
    | xargs -I{} gh repo clone {}
  '';

  killAllNvim = pkgs.writeScriptBin "killAllNvim" ''
    ps -ef | grep "neovim" | grep -v grep | awk '{print $2}' | xargs kill -9
  '';

  scripts = [
    depends
    git-hash
    run
    wo
    ghpr
    nixFlakes
    gwtInit
    gwtBare
    gwtBranch
    gwtNewBranch
    gwtCheckoutBranch
    gwtDeleteBranch
    gwtCheckoutPR
    ghClone
    killAllNvim
  ];

  # Set all shell aliases programatically
  shellAliases = {
    cat = "bat";
    dc = "docker-compose";
    dk = "docker";
    find = "fd";
    grep = "grep --color=auto";
    hms = "home-manager switch --impure";
    l = "eza";
    ll = "ls -lh";
    ls = "eza";
    la = "ls -lha";
    lg = "lazygit";
    md = "mdcat";
    start-docker = "docker-machine start default";
    vimdiff = "nvim -d";
    vf = "nvim";
    vd = "nvim .";
    gi = "gitui";
    gwt = "git worktree";
    gwtt = "cd $(gwtBranch)";
    gwtb = "cd $(gwtBare)";
    vgwt = "cd $(gwtBranch) && nvim .";

    # Reload zsh
    szsh = "source ~/.zshrc";
    szenv = "source ~/.zshenv";

    # Reload tmux
    stmux = "tmux source-file ~/.tmux.conf";

    # Reload asdf-vm
    iasdf = "asdf install";

    # Reload home manager and zsh
    reload = "hms && szenv && szsh && stmux && iasdf";

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

  programs.skim = { enable = true; };

  home.packages = with pkgs; scripts;

  programs.nushell = { enable = true; };

  home.file.".tool-versions".source = ../config/asdf/tool-versions;
  home.file.".czrc".source = ../config/czrc;

  xdg.configFile."starship.toml".source = ../config/starship.toml;

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
        name = "zsh-syntax-highlighting";
        src = pkgs.fetchFromGitHub {
          owner = "zsh-users";
          repo = "zsh-syntax-highlighting";
          rev = "0.7.1";
          sha256 = "gOG0NLlaJfotJfs+SUhGgLTNOnGLjoqnUp54V9aFJg8=";
          fetchSubmodules = true;
        };
      }
      {
        name = "zsh-completions";
        src = pkgs.fetchFromGitHub {
          owner = "zsh-users";
          repo = "zsh-completions";
          rev = "0.34.0";
          sha256 = "qSobM4PRXjfsvoXY6ENqJGI9NEAaFFzlij6MPeTfT0o=";
          fetchSubmodules = true;
        };
      }
      {
        name = "zsh-autosuggestions";
        src = pkgs.fetchFromGitHub {
          owner = "zsh-users";
          repo = "zsh-autosuggestions";
          rev = "v0.7.0";
          sha256 = "KLUYpUu4DHRumQZ3w59m9aTW6TBKMCXl2UcKi4uMd7w=";
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
      TERM =
        if pkgs.stdenv.isDarwin then "screen-256color" else "tmux-256color";
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

      if [ -e /opt/asdf-vm/asdf.sh ]; then
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

      # Bob
      export PATH="$HOME/.local/share/bob/nvim-bin:$PATH"

      # Flutter/Android
      if command -v brew > /dev/null; then
        export ANDROID_HOME="$HOME/Library/Android/Sdk"
        export PATH=$PATH:$ANDROID_HOME/cmdline-tools/latest/bin
        export CHROME_EXECUTABLE="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"

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
      # Chinese dart mirrors
      # export PUB_HOSTED_URL=https://mirrors.tuna.tsinghua.edu.cn/dart-pub
      # export FLUTTER_STORAGE_BASE_URL=https://mirrors.tuna.tsinghua.edu.cn/flutter

      # GO
      export GOPATH="$HOME/go"
      export PATH="$GO_PATH/bin:$PATH"

      # Python
      export PATH=$(asdf where python)/bin:$PATH

      # Swift/Mint
      export PATH=~/.mint/bin:$PATH

      export PATH=$HOME/.local/bin:$PATH

      # mason.nvim installs
      export PATH=$HOME/.local/share/nvim/mason/bin/:$PATH

      # PNPM
      export PNPM_HOME=$HOME/.local/share/pnpm
      export PATH=$PNPM_HOME:$PATH

      # Maestro
      export PATH=$PATH:$HOME/.maestro/bin

      # distrobox
      if [ -e $HOME/.distrobox ]; then
        export PATH=$HOME/.distrobox/bin:$PATH
        export PATH=$HOME/.distrobox/podman/bin:$PATH
      fi

      # tmux-plugin-manager
      export PATH=$HOME/.tmux/plugins/t-smart-tmux-session-manager/bin:$PATH
    '';

    # Called whenever zsh is initialized
    initExtra = ''
      source ${pkgs.zsh-vi-mode}/share/zsh-vi-mode/zsh-vi-mode.plugin.zsh

      bindkey -e

      # Start up Starship shell
      eval "$(starship init zsh)"

      eval "$(zoxide init zsh)"

      eval "$(mcfly init zsh)"

      eval "$(minikube docker-env)"

      if command -v op > /dev/null; then
        eval "$(op signin)"
      fi

      # distrobox
      if [ -e $HOME/.distrobox ]; then
        xhost +si:localuser:$USER
      fi
    '';
  };
}
