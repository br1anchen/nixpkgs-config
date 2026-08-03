# Shell configuration for zsh
# Defines general Zsh environment, aliases, and custom scripts.

{ pkgs, ... }:

let
  # View dependency tree of a Nix package
  depends = pkgs.writeScriptBin "depends" ''
    if [[ -z "$1" ]]; then
      echo "Usage: depends <command>" >&2
      exit 1
    fi
    nix-store --query --requisites "$(which "$1")"
  '';

  # Fetch Git hash for a GitHub repository
  git-hash = pkgs.writeScriptBin "git-hash" ''
    if [[ $# -ne 3 ]]; then
      echo "Usage: git-hash <owner> <repo> <commit>" >&2
      exit 1
    fi
    nix-prefetch-url --unpack "https://github.com/$1/$2/archive/$3.tar.gz"
  '';

  # Show real path of a command
  wo = pkgs.writeScriptBin "wo" ''
    if [[ -z "$1" ]]; then
      echo "Usage: wo <command>" >&2
      exit 1
    fi
    readlink "$(which "$1")"
  '';

  # Run a command in a pure Nix shell
  run = pkgs.writeScriptBin "run" ''
    if [[ $# -eq 0 ]]; then
      echo "Usage: run <command>" >&2
      exit 1
    fi
    nix-shell --pure --run "$@"
  '';

  # Checkout a GitHub PR using fzf
  ghpr = pkgs.writeScriptBin "ghpr" ''
    if ! command -v gh >/dev/null 2>&1; then
      echo "gh (GitHub CLI) not found" >&2
      exit 1
    fi
    GH_FORCE_TTY=100% gh pr list \
      | fzf --ansi --preview 'GH_FORCE_TTY=100% gh pr view {1}' --preview-window down --header-lines 3 \
      | awk '{print $1}' \
      | xargs -r gh pr checkout
  '';

  # Checkout a GitLab MR using fzf
  glabmr = pkgs.writeScriptBin "glabmr" ''
    if ! command -v glab >/dev/null 2>&1; then
      echo "glab (GitLab CLI) not found" >&2
      exit 1
    fi
    glab mr list \
      | fzf --ansi --preview 'glab mr view {1}' --preview-window down \
      | awk '{print $1}' \
      | sed 's/^!//' \
      | xargs -r glab mr checkout
  '';

  # Run nix with flakes support
  nixFlakes = pkgs.writeScriptBin "nixFlakes" ''
    exec ${pkgs.nixVersions.latest}/bin/nix --experimental-features "nix-command flakes" "$@"
  '';

  # Clone a GitLab repository using fzf
  glabClone = pkgs.writeScriptBin "glabClone" ''
    if ! command -v glab >/dev/null 2>&1; then
      echo "glab (GitLab CLI) not found" >&2
      exit 1
    fi
    if ! command -v fzf >/dev/null 2>&1; then
      echo "fzf not found" >&2
      exit 1
    fi
    repo=$(glab repo list | fzf --ansi | awk '{print $1}')
    if [[ -z "$repo" ]]; then
      echo "No repository selected" >&2
      exit 1
    fi
    glab repo clone "$repo"
  '';

  # Clone a GitHub repository using fzf
  ghClone = pkgs.writeScriptBin "ghClone" ''
    if ! command -v gh >/dev/null 2>&1; then
      echo "gh (GitHub CLI) not found" >&2
      exit 1
    fi
    if ! command -v fzf >/dev/null 2>&1; then
      echo "fzf not found" >&2
      exit 1
    fi
    repo=$(gh repo list | fzf --ansi | awk '{print $1}')
    if [[ -z "$repo" ]]; then
      echo "No repository selected" >&2
      exit 1
    fi
    gh repo clone "$repo"
  '';

  # Safely terminate all Neovim processes
  killAllNvim = pkgs.writeScriptBin "killAllNvim" ''
    ps -u "$USER" | grep '[n]eovim' | awk '{print $2}' | xargs -r kill -TERM
  '';

  safeChain = pkgs."safe-chain";

  scripts = [
    depends
    git-hash
    run
    wo
    ghpr
    glabmr
    nixFlakes
    ghClone
    glabClone
    killAllNvim
    safeChain
  ];

  # Shell aliases grouped by category
  shellAliases = {
    # File and directory navigation
    cat = "bat";
    find = "fd";
    grep = "grep --color=auto";
    l = "eza";
    ll = "ls -lh";
    ls = "eza";
    la = "ls -lha";
    md = "mdcat";

    # Docker
    dc = "docker-compose";
    dk = "docker";
    start-docker = "docker-machine start default";

    # Editor
    vimdiff = "nvim -d";
    vf = "nvim";
    vd = "nvim .";

    # Git
    gi = "gitui";
    lg = "lazygit";

    # Nix
    hms = "home-manager switch --flake ~/nixpkgs-config#$(if [[ $(uname) == 'Darwin' ]]; then echo 'darwin'; else echo 'linux'; fi)";
    garbage = "nix-collect-garbage -d && docker image prune --force";
    installed = "nix-env --query --installed";

    # Aikido Safe Chain — wraps package managers from ./config/mise/config.toml
    # (nodejs, pnpm, bun, python) that safe-chain supports. Go/Deno/Zig skipped
    # since safe-chain doesn't cover them.
    npm = "aikido-npm";
    npx = "aikido-npx";
    yarn = "aikido-yarn";
    pnpm = "aikido-pnpm";
    pnpx = "aikido-pnpx";
    bun = "aikido-bun";
    bunx = "aikido-bunx";
    pip = "aikido-pip";
    pip3 = "aikido-pip3";
    uv = "aikido-uv";
    uvx = "aikido-uvx";
    poetry = "aikido-poetry";
    pipx = "aikido-pipx";

    # Configuration reload
    szsh = "source ~/.zshrc";
    szenv = "source ~/.zshenv";
    imise = "mise install";
    reload = "hms && szenv && szsh && imise";
  };
in
{
  programs = {
    mise = {
      enable = true;
      enableZshIntegration = true;
      enableBashIntegration = true;
    };

    direnv = {
      enable = true;
      enableZshIntegration = true;
    };

    broot = {
      enable = true;
      enableZshIntegration = true;
    };

    bat = {
      enable = true;
      config = {
        theme = "base16";
        italic-text = "always";
      };
    };

    fzf = {
      enable = true;
      enableBashIntegration = true;
      enableZshIntegration = true;
      defaultCommand = "${pkgs.ripgrep}/bin/rg --files";
    };

    skim = {
      enable = true;
    };

    nushell = {
      enable = true;
    };

    zsh = {
      inherit shellAliases;
      enable = true;
      autosuggestion.enable = true;
      enableCompletion = true;
      history.extended = true;

      oh-my-zsh = {
        enable = true;
        plugins = [
          "docker"
          "docker-compose"
          "git"
          "sudo"
          "node"
        ];
      };

      plugins = [
        {
          name = "zsh-syntax-highlighting";
          src = pkgs.fetchFromGitHub {
            owner = "zsh-users";
            repo = "zsh-syntax-highlighting";
            rev = "0.8.0";
            sha256 = "hjwsrn0FQBwmNQDXtoYAJF7ZRsGyirTneG1e+ykViDg=";
            fetchSubmodules = true;
          };
        }
        {
          name = "zsh-completions";
          src = pkgs.fetchFromGitHub {
            owner = "zsh-users";
            repo = "zsh-completions";
            rev = "0.35.0";
            sha256 = "GFHlZjIHUWwyeVoCpszgn4AmLPSSE8UVNfRmisnhkpg=";
            fetchSubmodules = true;
          };
        }
        {
          name = "zsh-autosuggestions";
          src = pkgs.fetchFromGitHub {
            owner = "zsh-users";
            repo = "zsh-autosuggestions";
            rev = "v0.7.1";
            sha256 = "vpTyYq9ZgfgdDsWzjxVAE7FZH4MALMNZIFyEOBLm5Qo=";
            fetchSubmodules = true;
          };
        }
      ];

      localVariables = {
        ENABLE_CORRECTION = "true";
        COMPLETION_WAITING_DOTS = "true";
        EDITOR = "nvim";
        VISUAL = "nvim";
        NVIM_TUI_ENABLE_TRUE_COLOR = 1;
        LANG = "en_US.UTF-8";
        LC_ALL = "en_US.UTF-8";
      };

      envExtra = ''
        # Nix setup (environment variables, etc.)
        if [[ -e ~/.nix-profile/etc/profile.d/nix.sh ]]; then
          . ~/.nix-profile/etc/profile.d/nix.sh
        fi

        # mise (runtime version manager - replaces asdf)
        # Shell integration is handled by programs.mise.enableZshIntegration

        # Rust Cargo
        CARGO_PATH="$HOME/.cargo/bin"
        export PATH="$CARGO_PATH:$PATH"

        # Bob
        export PATH="$HOME/.local/share/bob/nvim-bin:$PATH"

        # Flutter/Android
        if command -v brew >/dev/null; then
          export ANDROID_HOME="$HOME/Library/Android/Sdk"
          export PATH="$PATH:$ANDROID_HOME/cmdline-tools/latest/bin"
          export CHROME_EXECUTABLE="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
        elif command -v pacman >/dev/null; then
          export ANDROID_SDK="$HOME/Android/Sdk"
          export ANDROID_NDK_HOME="$ANDROID_SDK/ndk"
          export PATH="$ANDROID_SDK/platform-tools:$ANDROID_SDK/cmdline-tools/latest/bin:$PATH"
          export CHROME_EXECUTABLE="/usr/bin/chromium"
        elif command -v apt >/dev/null; then
          export ANDROID_HOME="$HOME/Android/Sdk"
          export PATH="$PATH:$ANDROID_HOME/cmdline-tools/latest/bin"
          export CHROME_EXECUTABLE="/usr/bin/firefox"
        else
          echo 'Unknown OS to set Flutter/Android env!' >&2
        fi

        # Dart
        export PATH="$PATH:$HOME/.pub-cache/bin"

        # GO
        export GOPATH="$HOME/go"
        export PATH="$GOPATH/bin:$PATH"

        # Python
        if command -v mise >/dev/null; then
          local python_path
          python_path="$(mise where python 2>/dev/null)" && export PATH="$python_path/bin:$PATH"
        fi

        # Swift/Mint
        export PATH="$HOME/.mint/bin:$PATH"

        # Local bin
        export PATH="$HOME/.local/bin:$PATH"

        # mason.nvim installs
        export PATH="$HOME/.local/share/nvim/mason/bin:$PATH"

        # PNPM
        export PNPM_HOME="$HOME/.local/share/pnpm"
        export PATH="$PNPM_HOME:$PATH"

        # BUN
        export BUN_HOME="$HOME/.bun"
        export PATH="$BUN_HOME/bin:$PATH"

        # Maestro
        export PATH="$PATH:$HOME/.maestro/bin"

        # distrobox
        if [[ -e $HOME/.distrobox ]]; then
          export PATH="$HOME/.distrobox/bin:$HOME/.distrobox/podman/bin:$PATH"
        fi

        # Google Cloud CLI
        if [[ -e /opt/homebrew/share/google-cloud-sdk ]]; then
          export PATH=/opt/homebrew/share/google-cloud-sdk/bin:"$PATH"
        fi
      '';

      initContent = ''
        source ${pkgs.zsh-vi-mode}/share/zsh-vi-mode/zsh-vi-mode.plugin.zsh
        autoload -Uz compinit && compinit
        source <(jj util completion zsh)
        bindkey -e
        eval "$(starship init zsh)"
        eval "$(zoxide init zsh)"
        eval "$(mcfly init zsh)"
        eval "$(minikube docker-env)"
        if [[ -e $HOME/.distrobox ]]; then
          xhost +si:localuser:$USER
        fi

        # Ghostty starts Herdr before this interactive shell initializes, so
        # the long-lived Herdr server does not retain shell-only secrets.
        if [[ -r "$HOME/.config/secrets/jotta-npm-token" ]]; then
          export NPM_TOKEN="$(< "$HOME/.config/secrets/jotta-npm-token")"
        fi
      '';
    };
  };

  home = {
    packages = scripts;

    file.".czrc".source = ../config/czrc;
  };

  xdg.configFile."mise/config.toml".source = ../config/mise/config.toml;
  xdg.configFile."starship.toml".source = ../config/starship.toml;
}
