{
  lib,
  pkgs,
  inputs,
  isDarwin,
  ...
}:

let
  shared = import ./shared.nix;

  aliases = shared.aliases // {
    hms = "home-manager switch -b backup --flake ~/nixpkgs-config#darwin";
    l = "eza";
    ls = "eza";
    ll = "eza -lh";
    la = "eza -lha";
    szsh = "source ~/.zshrc";
    szenv = "source ~/.zshenv";
    reload = "hms && szenv && szsh && imise";
  };

  environment = ''
    ${shared.environment}

    # Flutter/Android
    export ANDROID_HOME="$HOME/Library/Android/Sdk"
    export PATH="$PATH:$ANDROID_HOME/cmdline-tools/latest/bin"
    export CHROME_EXECUTABLE="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
  '';
in
lib.mkIf isDarwin {
  programs = {
    mise = {
      enable = true;
      # doCheck = false: brew cask tests fail in the Nix sandbox.
      package = inputs.mise-flake.packages.${pkgs.stdenv.hostPlatform.system}.mise.overrideAttrs (_: {
        doCheck = false;
      });
      enableZshIntegration = true;
    };

    zsh = {
      shellAliases = aliases;
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

        ${environment}

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
}
