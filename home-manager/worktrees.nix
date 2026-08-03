# Legacy Git worktree helpers.
# Herdr owns the primary worktree workflow; these remain available as a fallback.

{ pkgs, ... }:

let
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

  gwtBare = pkgs.writeScriptBin "gwtBare" ''
    git worktree list \
      | grep 'bare' \
      | awk '{print $1}'
  '';

  gwtBranch = pkgs.writeScriptBin "gwtBranch" ''
    branch=$(git worktree list | fzf --ansi | awk '{print $1}')
    if [[ -z "$branch" ]]; then
      echo "$(pwd)"
    else
      echo "$branch"
    fi
  '';

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

  gwtCheckoutMR = pkgs.writeScriptBin "gwtCheckoutMR" ''
    ${checkBareRoot}
    if ! command -v glab >/dev/null 2>&1; then
      echo "glab (GitLab CLI) not found" >&2
      exit 1
    fi
    if ! command -v fzf >/dev/null 2>&1; then
      echo "fzf not found" >&2
      exit 1
    fi
    if ! command -v jq >/dev/null 2>&1; then
      echo "jq not found" >&2
      exit 1
    fi
    if ! git fetch; then
      echo "Failed to fetch MRs" >&2
      exit 1
    fi
    mr_id=$(glab mr list \
      | fzf --ansi --preview 'glab mr view {1}' --preview-window down \
      | awk '{print $1}' \
      | sed 's/^!//')
    if [[ -z "$mr_id" ]]; then
      echo "Missing MR id" >&2
      exit 1
    fi
    mr_branch=$(glab mr view "$mr_id" -F json | jq -r '.source_branch')
    if [[ -z "$mr_branch" || "$mr_branch" == "null" ]]; then
      echo "Failed to resolve MR source branch" >&2
      exit 1
    fi
    existing_path=$(git worktree list | awk -v b="$mr_branch" '$0 ~ "\\[" b "\\]" {print $1; exit}')
    if [[ -n "$existing_path" ]]; then
      echo "$existing_path"
      exit 0
    fi
    remote=$(git remote -v | grep 'fetch' | head -n 1 | awk '{print $1}')
    if git show-ref -q --heads "$mr_branch"; then
      if ! git worktree add "$mr_branch" "$mr_branch"; then
        echo "Failed to create worktree" >&2
        exit 1
      fi
    else
      if ! git worktree add --track -b "$mr_branch" "$mr_branch" "$remote/$mr_branch"; then
        echo "Failed to create worktree" >&2
        exit 1
      fi
    fi
    echo "$(pwd)/$mr_branch"
  '';
in
{
  home.packages = [
    gwtInit
    gwtBare
    gwtBranch
    gwtNewBranch
    gwtCheckoutBranch
    gwtDeleteBranch
    gwtCheckoutPR
    gwtCheckoutMR
  ];

  programs.zsh = {
    shellAliases = {
      gwt = "git worktree";
      gwtls = "git worktree list";
      gwtb = "gwt_bare";
      gwtt = "gwt_branch";
      vgwt = "gwt_view";
      gwt-new = "gwt_new";
      gwt-checkout = "gwt_checkout";
      gwt-pr = "gwt_pr";
      gwt-mr = "gwt_mr";
      gwt-delete = "gwt_delete";
    };

    initContent = ''
      # Legacy Git worktree functions. Prefer Herdr's built-in worktree UI.
      gwt_bare() {
        local dir
        dir=$(gwtBare)
        local exit_code=$?
        if [[ $exit_code -ne 0 ]]; then
          return $exit_code
        fi
        if [[ -n "$dir" && -d "$dir" ]]; then
          cd "$dir"
        else
          echo "Directory not found: $dir" >&2
          return 1
        fi
      }
      gwt_branch() {
        local dir
        dir=$(gwtBranch)
        local exit_code=$?
        if [[ $exit_code -ne 0 ]]; then
          return $exit_code
        fi
        if [[ -n "$dir" && -d "$dir" ]]; then
          cd "$dir"
        else
          echo "Directory not found: $dir" >&2
          return 1
        fi
      }
      gwt_view() {
        local dir
        dir=$(gwtBranch)
        local exit_code=$?
        if [[ $exit_code -ne 0 ]]; then
          return $exit_code
        fi
        if [[ -n "$dir" && -d "$dir" ]]; then
          cd "$dir" && nvim .
        else
          echo "Directory not found: $dir" >&2
          return 1
        fi
      }
      gwt_new() {
        if [[ -z "$1" || -z "$2" ]]; then
          echo "Usage: gwt_new <branch> <baseBranch>" >&2
          return 1
        fi
        local dir
        dir=$(gwtNewBranch "$1" "$2")
        local exit_code=$?
        if [[ $exit_code -ne 0 ]]; then
          return $exit_code
        fi
        if [[ -n "$dir" && -d "$dir" ]]; then
          cd "$dir"
        else
          echo "Directory not found: $dir" >&2
          return 1
        fi
      }
      gwt_checkout() {
        local dir
        dir=$(gwtCheckoutBranch)
        local exit_code=$?
        if [[ $exit_code -ne 0 ]]; then
          return $exit_code
        fi
        if [[ -n "$dir" && -d "$dir" ]]; then
          cd "$dir"
        else
          echo "Directory not found: $dir" >&2
          return 1
        fi
      }
      gwt_pr() {
        local dir
        dir=$(gwtCheckoutPR)
        local exit_code=$?
        if [[ $exit_code -ne 0 ]]; then
          return $exit_code
        fi
        if [[ -n "$dir" && -d "$dir" ]]; then
          cd "$dir"
        else
          echo "Directory not found: $dir" >&2
          return 1
        fi
      }
      gwt_mr() {
        local dir
        dir=$(gwtCheckoutMR)
        local exit_code=$?
        if [[ $exit_code -ne 0 ]]; then
          return $exit_code
        fi
        if [[ -n "$dir" && -d "$dir" ]]; then
          cd "$dir"
        else
          echo "Directory not found: $dir" >&2
          return 1
        fi
      }
      gwt_delete() {
        gwtDeleteBranch
      }
    '';
  };
}
