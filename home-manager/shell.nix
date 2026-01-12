# Shell configuration for zsh
# Defines Zsh environment, aliases, and custom scripts for Git worktrees, Nix, and other tools.

{ pkgs, ... }:

let
  # Helper function to check if inside a bare Git repository
  checkBareRoot = ''
    if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      echo "Not inside a Git repository" >&2
      exit 1
    fi
    bare=$(git worktree list | grep 'bare' | awk '{print $1}')
    if [[ -z "$bare" ]]; then
      echo "No bare repository found" >&2
      exit 1
    fi
    current=$(pwd)
    if [[ "$current" != "$bare" ]]; then
      echo "Cannot run gwt command outside bare repository root" >&2
      exit 1
    fi
  '';

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

  # Run nix with flakes support
  nixFlakes = pkgs.writeScriptBin "nixFlakes" ''
    exec ${pkgs.nixVersions.latest}/bin/nix --experimental-features "nix-command flakes" "$@"
  '';

  # Initialize a bare Git repository with worktree support
  gwtInit = pkgs.writeScriptBin "gwtInit" ''
    if [[ -z "$1" ]]; then
      echo "Usage: gwtInit <url> [name]" >&2
      exit 1
    fi
    url="$1"
    name=''${2:-$(basename "$url")}

    if ! git clone --bare --no-checkout "$url" "$name"; then
      echo "Failed to clone repository" >&2
      exit 1
    fi
    cd "$name" || exit 1
    git config remote.origin.fetch '+refs/heads/*:refs/remotes/origin/*'
    git fetch
    git for-each-ref --format='%(refname:short)' refs/heads | xargs -n1 -I{} git branch --set-upstream-to=origin/{} {}
  '';

  # Return path to bare repository
  gwtBare = pkgs.writeScriptBin "gwtBare" ''
    git worktree list \
      | grep 'bare' \
      | awk '{print $1}'
  '';

  # Select a worktree branch using fzf
  gwtBranch = pkgs.writeScriptBin "gwtBranch" ''
    branch=$(git worktree list | fzf --ansi | awk '{print $1}')
    if [[ -z "$branch" ]]; then
      echo "$(pwd)"
    else
      echo "$branch"
    fi
  '';

  # Create a new Git worktree branch
  gwtNewBranch = pkgs.writeScriptBin "gwtNewBranch" ''
    ${checkBareRoot}
    if [[ -z "$1" || -z "$2" ]]; then
      echo "Usage: gwtNewBranch <branch> <baseBranch>" >&2
      exit 1
    fi
    branch="$1"
    baseBranch="$2"
    if ! git worktree add -b "$branch" "$branch" "$baseBranch"; then
      echo "Failed to create worktree" >&2
      exit 1
    fi
    if ! git push -u origin "$branch"; then
      echo "Failed to push branch" >&2
      exit 1
    fi
    echo "$(pwd)/$branch"
  '';

  # Checkout an existing Git branch as a worktree
  gwtCheckoutBranch = pkgs.writeScriptBin "gwtCheckoutBranch" ''
    ${checkBareRoot}
    if ! command -v fzf >/dev/null 2>&1; then
      echo "fzf not found" >&2
      exit 1
    fi
    if ! git fetch; then
      echo "Failed to fetch branches" >&2
      exit 1
    fi
    remote=$(git remote -v | grep 'fetch' | head -n 1 | awk '{print $1}')
    branch=$(git branch -r | fzf --ansi | awk '{print $1}' | sed "s/$remote\/\(.*\)/\1/")
    if [[ -z "$branch" ]]; then
      echo "Missing branch" >&2
      exit 1
    fi
    # If worktree for the branch already exists, return its path
    existing_path=$(git worktree list | awk -v b="$branch" '$0 ~ "\\[" b "\\]" {print $1; exit}')
    if [[ -n "$existing_path" ]]; then
      echo "$existing_path"
      exit 0
    fi
    if git show-ref -q --heads "$branch"; then
      if ! git worktree add "$branch" "$branch"; then
        echo "Failed to create worktree" >&2
        exit 1
      fi
    else
      if ! git worktree add --track -b "$branch" "$branch" "$remote/$branch"; then
        echo "Failed to create worktree" >&2
        exit 1
      fi
    fi
    echo "$(pwd)/$branch"
  '';

  # Delete a Git worktree and its branch
  gwtDeleteBranch = pkgs.writeScriptBin "gwtDeleteBranch" ''
    ${checkBareRoot}
    if ! command -v fzf >/dev/null 2>&1; then
      echo "fzf not found" >&2
      exit 1
    fi
    branch=$(git worktree list | fzf --ansi | awk '{print $3}' | sed 's/.*\[\([^]]*\)].*/\1/')
    if [[ -z "$branch" ]]; then
      echo "Missing branch" >&2
      exit 1
    fi
    if ! git worktree remove --force "./$branch"; then
      echo "Failed to remove worktree" >&2
      exit 1
    fi
    if ! git branch -D "$branch"; then
      echo "Failed to delete branch" >&2
      exit 1
    fi
    echo "$(pwd)"
  '';

  # Checkout a GitHub PR as a worktree
  gwtCheckoutPR = pkgs.writeScriptBin "gwtCheckoutPR" ''
    ${checkBareRoot}
    if ! command -v gh >/dev/null 2>&1; then
      echo "gh (GitHub CLI) not found" >&2
      exit 1
    fi
    if ! command -v fzf >/dev/null 2>&1; then
      echo "fzf not found" >&2
      exit 1
    fi
    if ! git fetch; then
      echo "Failed to fetch PRs" >&2
      exit 1
    fi
    pr_branch=$(gh pr list \
      | fzf --ansi --preview 'GH_FORCE_TTY=100% gh pr view {1}' --preview-window down \
      | awk -F'\t' '{print $3}')
    if [[ -z "$pr_branch" ]]; then
      echo "Missing PR branch" >&2
      exit 1
    fi
    # If worktree for the PR branch already exists, cd to it
    existing_path=$(git worktree list | awk -v b="$pr_branch" '$0 ~ "\\[" b "\\]" {print $1; exit}')
    if [[ -n "$existing_path" ]]; then
      echo "$existing_path"
      exit 0
    fi
    if ! git worktree add "$pr_branch" "$pr_branch"; then
      echo "Failed to create worktree" >&2
      exit 1
    fi
    echo "$(pwd)/$pr_branch"
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

    # Git and worktrees
    gi = "gitui";
    lg = "lazygit";
    gwt = "git worktree";
    gwtls = "git worktree list";
    gwtb = "gwt_bare";
    gwtt = "gwt_branch";
    vgwt = "gwt_view";
    gwt-new = "gwt_new";
    gwt-checkout = "gwt_checkout";
    gwt-pr = "gwt_pr";
    gwt-delete = "gwt_delete";

    # Nix
    hms = "home-manager switch --impure";
    garbage = "nix-collect-garbage -d && docker image prune --force";
    installed = "nix-env --query --installed";

    # Configuration reload
    szsh = "source ~/.zshrc";
    szenv = "source ~/.zshenv";
    stmux = "tmux source-file ~/.tmux.conf";
    iasdf = "asdf install";
    reload = "hms && szenv && szsh && stmux && iasdf";
  };
in
{
  programs = {
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
          "dotenv"
          "git"
          "sudo"
          "node"
          "tmux"
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
        ZSH_TMUX_AUTOSTART = true;
        ZSH_TMUX_AUTOCONNECT = true;
        ENABLE_CORRECTION = "true";
        COMPLETION_WAITING_DOTS = "true";
        EDITOR = "nvim";
        VISUAL = "nvim";
        NVIM_TUI_ENABLE_TRUE_COLOR = 1;
        TERM = "tmux-256color";
        LANG = "en_US.UTF-8";
        LC_ALL = "en_US.UTF-8";
      };

      envExtra = ''
        # Nix setup (environment variables, etc.)
        if [[ -e ~/.nix-profile/etc/profile.d/nix.sh ]]; then
          . ~/.nix-profile/etc/profile.d/nix.sh
        fi

        # Load environment variables from a file
        if [[ -e ~/.env ]]; then
          . ~/.env
        fi

        # asdf
        if [ -e $HOME/.asdf ]; then
          . $HOME/.asdf/asdf.sh
        fi
        export ASDF_DIR="$HOME/.asdf"
        export PATH="$ASDF_DIR:$PATH"
        fpath=($ASDF_DIR/completions $fpath)
        if [[ -e $HOME/.asdf/plugins/java/set-java-home.zsh ]]; then
          . $HOME/.asdf/plugins/java/set-java-home.zsh
        fi

        # Rust Cargo
        CARGO_PATH="$HOME/.cargo/bin"
        export PATH="$CARGO_PATH:$PATH"

        # Bob
        export PATH="$HOME/.local/share/bob/v0.11.5/bin:$PATH"

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
        if command -v asdf >/dev/null; then
          export PATH="$(asdf where python)/bin:$PATH"
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

        # tmux-plugin-manager
        export PATH="$HOME/.tmux/plugins/t-smart-tmux-session-manager/bin:$PATH"
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

        # Git worktree functions
        gwt_bare() {
          local dir; dir=$(gwtBare)
          [[ -n "$dir" ]] && cd "$dir"
        }
        gwt_branch() {
          local dir; dir=$(gwtBranch)
          [[ -n "$dir" ]] && cd "$dir"
        }
        gwt_view() {
          local dir; dir=$(gwtBranch)
          [[ -n "$dir" ]] && cd "$dir" && nvim .
        }
        gwt_new() {
          if [[ -z "$1" || -z "$2" ]]; then
            echo "Usage: gwt_new <branch> <baseBranch>" >&2
            return 1
          fi
          local dir; dir=$(gwtNewBranch "$1" "$2") && [[ -n "$dir" ]] && cd "$dir"
        }
        gwt_checkout() {
          local dir; dir=$(gwtCheckoutBranch)
          [[ -n "$dir" ]] && cd "$dir"
        }
        gwt_pr() {
          local dir; dir=$(gwtCheckoutPR)
          [[ -n "$dir" ]] && cd "$dir"
        }
        gwt_delete() {
          gwtDeleteBranch
        }
      '';
    };
  };

  home = {
    packages = scripts;

    file.".tool-versions".source = ../config/asdf/tool-versions;
    file.".czrc".source = ../config/czrc;
  };

  xdg.configFile."starship.toml".source = ../config/starship.toml;
}
