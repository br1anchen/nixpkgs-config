{ lib, pkgs, ... }:

let
  depends = pkgs.writeScriptBin "depends" ''
    if [[ -z "$1" ]]; then
      echo "Usage: depends <command>" >&2
      exit 1
    fi
    nix-store --query --requisites "$(which "$1")"
  '';

  git-hash = pkgs.writeScriptBin "git-hash" ''
    if [[ $# -ne 3 ]]; then
      echo "Usage: git-hash <owner> <repo> <commit>" >&2
      exit 1
    fi
    nix-prefetch-url --unpack "https://github.com/$1/$2/archive/$3.tar.gz"
  '';

  wo = pkgs.writeScriptBin "wo" ''
    if [[ -z "$1" ]]; then
      echo "Usage: wo <command>" >&2
      exit 1
    fi
    readlink "$(which "$1")"
  '';

  run = pkgs.writeScriptBin "run" ''
    if [[ $# -eq 0 ]]; then
      echo "Usage: run <command>" >&2
      exit 1
    fi
    nix-shell --pure --run "$@"
  '';

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

  nixFlakes = pkgs.writeScriptBin "nixFlakes" ''
    exec ${pkgs.nixVersions.latest}/bin/nix --experimental-features "nix-command flakes" "$@"
  '';

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

  killAllNvim = pkgs.writeScriptBin "killAllNvim" ''
    ps -u "$USER" | grep '[n]eovim' | awk '{print $2}' | xargs -r kill -TERM
  '';

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
    text = builtins.readFile ../../config/nix-temp-gc.sh;
  };
in
{
  home = {
    packages = [
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
      pkgs."safe-chain"
    ];

    file.".czrc".source = ../../config/czrc;
  };
}
