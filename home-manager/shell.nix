# Shell configuration.
#
# One source of aliases and environment, rendered per shell:
#   macOS   - zsh (programs.zsh), the normal home-manager path.
#   Omarchy - bash. home-manager must NOT own ~/.bashrc there: Omarchy's own
#             ~/.bashrc sources $OMARCHY_PATH/default/bash/rc, which exports
#             OMARCHY_PATH and initialises mise, starship, zoxide, fzf and every
#             Omarchy alias. Setting programs.bash.enable would delete that line
#             and take the whole Omarchy shell layer with it.
#
# Instead the shared layer is installed into the profile at
# ~/.nix-profile/etc/profile.d/shared-shell.sh (a stable path across rebuilds)
# and ~/.bashrc gets a single `source` line, added once by
# scripts/omarchy-bootstrap.sh.

{
  lib,
  pkgs,
  inputs,
  isDarwin,
  isOmarchy,
  ...
}:

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

  # Remove old temporary directories leaked by `nix develop`.
  nixTempGc = pkgs.writeShellApplication {
    name = "nix-temp-gc";
    runtimeInputs =
      with pkgs;
      [
        coreutils
        findutils
        lsof
      ]
      ++ lib.optionals stdenv.hostPlatform.isLinux [ procps ];
    text = builtins.readFile ../config/nix-temp-gc.sh;
  };

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
    nixTempGc
    safeChain
  ];


  # Aliases Omarchy's bash layer does not already provide.
  #
  # Omarchy's aliases win on collision (Q24), so `ls`, `cd` (its zoxide `zd`
  # wrapper), `d` (docker), `c` (opencode), `g` (git), `t` (tmux) and `h` (herdr)
  # are deliberately absent here and only defined for macOS below.
  sharedAliases = {
    cat = "bat";
    find = "fd";
    grep = "grep --color=auto";
    md = "mdcat";

    dc = "docker-compose";
    dk = "docker";

    vimdiff = "nvim -d";
    vf = "nvim";
    vd = "nvim .";

    lg = "lazygit";

    # herdr helpers. Previously defined under programs.zsh only, so on a bash
    # login shell they never loaded at all.
    hdr = "herdr";
    herdr-reload = "herdr server reload-config";
    gsh = "ghostty-shell";

    hms = "home-manager switch -b backup --flake ~/nixpkgs-config#$(if [[ $(uname) == 'Darwin' ]]; then echo 'darwin'; else echo 'omarchy'; fi)";
    garbage = "nix-collect-garbage -d && nix-temp-gc && { command -v docker >/dev/null && docker image prune --force || true; }";
    installed = "nix-env --query --installed";
    imise = "mise install";
    dots = "dotfiles-sync";

    # Aikido Safe Chain. These were also zsh-only, which meant supply-chain
    # interception was silently OFF on this bash-login-shell machine.
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
  };

  darwinAliases = {
    l = "eza";
    ls = "eza";
    ll = "eza -lh";
    la = "eza -lha";
    szsh = "source ~/.zshrc";
    szenv = "source ~/.zshenv";
    reload = "hms && szenv && szsh && imise";
  };

  omarchyAliases = {
    reload = "hms && source ~/.bashrc && mise install";
  };

  # PATH and environment shared by both shells. Deliberately POSIX-compatible so
  # the bash layer can source it verbatim.
  sharedEnv = ''
    # Rust Cargo
    export PATH="$HOME/.cargo/bin:$PATH"

    # Bob stores the active Neovim version in `used`.
    if [ -f "$HOME/.local/share/bob/used" ]; then
      export PATH="$HOME/.local/share/bob/$(cat "$HOME/.local/share/bob/used")/bin:$PATH"
    fi

    # Flutter/Android
    if command -v brew >/dev/null 2>&1; then
      export ANDROID_HOME="$HOME/Library/Android/Sdk"
      export PATH="$PATH:$ANDROID_HOME/cmdline-tools/latest/bin"
      export CHROME_EXECUTABLE="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
    elif command -v pacman >/dev/null 2>&1; then
      export ANDROID_SDK="$HOME/Android/Sdk"
      export ANDROID_NDK_HOME="$ANDROID_SDK/ndk"
      export PATH="$ANDROID_SDK/platform-tools:$ANDROID_SDK/cmdline-tools/latest/bin:$PATH"
      export CHROME_EXECUTABLE="/usr/bin/chromium"
    fi

    # Dart / Go / Swift
    export PATH="$PATH:$HOME/.pub-cache/bin"
    export GOPATH="$HOME/go"
    export PATH="$GOPATH/bin:$PATH"
    export PATH="$HOME/.mint/bin:$PATH"

    # mason.nvim installs
    export PATH="$HOME/.local/share/nvim/mason/bin:$PATH"

    # PNPM / BUN / Maestro
    export PNPM_HOME="$HOME/.local/share/pnpm"
    export PATH="$PNPM_HOME:$PATH"
    export BUN_HOME="$HOME/.bun"
    export PATH="$BUN_HOME/bin:$PATH"
    export PATH="$PATH:$HOME/.maestro/bin"

    # Local bin
    export PATH="$HOME/.local/bin:$PATH"
  '';

  renderAliases =
    aliases:
    lib.concatStringsSep "\n" (
      lib.mapAttrsToList (k: v: "alias ${k}=${lib.escapeShellArg v}") aliases
    );

  # The Omarchy bash layer. Installed into the profile rather than written to
  # ~/.bashrc, so the path stays stable across rebuilds and Omarchy keeps
  # ownership of ~/.bashrc.
  #
  # Note what is NOT here: starship, zoxide, mise and fzf initialisation.
  # Omarchy's default/bash/init already does all four, and doing them again
  # would double-initialise every interactive shell.
  sharedShellInit = pkgs.writeTextFile {
    name = "shared-shell-init";
    destination = "/etc/profile.d/shared-shell.sh";
    text = ''
      # Shared shell layer, generated by nixpkgs-config (home-manager/shell.nix).
      # Sourced from ~/.bashrc by scripts/omarchy-bootstrap.sh.

      ${sharedEnv}

      ${renderAliases (sharedAliases // omarchyAliases)}

      # direnv and broot are not part of Omarchy's shell layer, so they are
      # initialised here. starship/zoxide/mise/fzf deliberately are not.
      if command -v direnv >/dev/null 2>&1; then
        eval "$(direnv hook bash)"
      fi
      if [ -r "$HOME/.config/broot/launcher/bash/br" ]; then
        . "$HOME/.config/broot/launcher/bash/br"
      fi

      # Ghostty starts herdr before this interactive shell initialises, so the
      # long-lived herdr server does not retain shell-only secrets.
      if command -v glab >/dev/null 2>&1; then
        NPM_TOKEN="$(glab config get token --host git.jotta.us 2>/dev/null)"
        export NPM_TOKEN
      fi
    '';
  };
in
{
  programs = {
    # macOS only. On Omarchy, mise is pacman's `mise-bin`: Omarchy's
    # default/bash/init runs `mise activate bash` and `omarchy update` runs
    # `omarchy-update-mise`, so the distro owns the binary. Shipping a second
    # mise from nix put it ahead on PATH and left a flake bump silently
    # changing the tool Omarchy depends on, against shared state in
    # ~/.local/share/mise. The tool *versions* are still ours, via
    # config/mise/config.toml.
    mise = lib.mkIf isDarwin {
      enable = true;
      # doCheck = false: brew cask tests fail in nix sandbox
      package = inputs.mise-flake.packages.${pkgs.stdenv.hostPlatform.system}.mise.overrideAttrs (_: {
        doCheck = false;
      });
      enableZshIntegration = true;
    };

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
        # "ansi" rather than a pinned scheme, so bat follows the terminal
        # palette. Omarchy exports BAT_THEME=ansi, and env beats this file --
        # pinning base16 gave different highlighting in bash vs zsh.
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

    zsh = lib.mkIf isDarwin {
      shellAliases = sharedAliases // darwinAliases;
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

        ${sharedEnv}

        # Python (mise-managed)
        if command -v mise >/dev/null; then
          python_path="$(mise where python 2>/dev/null)" && export PATH="$python_path/bin:$PATH"
        fi

        # Google Cloud CLI
        if [[ -e /opt/homebrew/share/google-cloud-sdk ]]; then
          export PATH=/opt/homebrew/share/google-cloud-sdk/bin:"$PATH"
        fi
      '';

      profileExtra = ''
        if [ -e /opt/homebrew/bin/brew ]; then
          eval "$(/opt/homebrew/bin/brew shellenv)"
        fi
      '';

      initContent = ''
        source ${pkgs.zsh-vi-mode}/share/zsh-vi-mode/zsh-vi-mode.plugin.zsh
        autoload -Uz compinit && compinit
        source <(jj util completion zsh)
        eval "$(starship init zsh)"
        eval "$(zoxide init zsh)"

        # Ghostty starts herdr before this interactive shell initialises, so the
        # long-lived herdr server does not retain shell-only secrets.
        if command -v glab >/dev/null 2>&1; then
          export NPM_TOKEN="$(glab config get token --host git.jotta.us 2>/dev/null)"
        fi
      '';
    };
  };

  home = {
    packages = scripts ++ lib.optionals isOmarchy [ sharedShellInit ];

    file.".czrc".source = ../config/czrc;
  };
}
