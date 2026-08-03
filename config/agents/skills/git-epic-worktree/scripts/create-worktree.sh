#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  create-worktree.sh --issue <number> --title <title> [--base <branch>]

Creates a sibling Git worktree and matching local branch from the current
branch of the primary checkout. Pass --base to select another local branch.
EOF
}

issue=""
title=""
base=""

while (($#)); do
  case "$1" in
    --issue)
      [[ $# -ge 2 ]] || { usage >&2; exit 2; }
      issue="$2"
      shift 2
      ;;
    --title)
      [[ $# -ge 2 ]] || { usage >&2; exit 2; }
      title="$2"
      shift 2
      ;;
    --base)
      [[ $# -ge 2 ]] || { usage >&2; exit 2; }
      base="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      printf 'Unknown argument: %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

[[ "$issue" =~ ^[0-9]+$ ]] || {
  printf 'Issue must be a numeric issue number.\n' >&2
  exit 2
}
[[ -n "$title" ]] || {
  printf 'Title must not be empty.\n' >&2
  exit 2
}
command -v git >/dev/null || {
  printf 'git is required.\n' >&2
  exit 1
}

repo_root="$(git rev-parse --show-toplevel 2>/dev/null)" || {
  printf 'Run this helper inside a non-bare Git working tree.\n' >&2
  exit 1
}
git_dir="$(git rev-parse --git-dir)"
common_dir="$(git rev-parse --git-common-dir)"
git_dir_absolute="$(cd "$git_dir" && pwd -P)"
common_dir_absolute="$(cd "$common_dir" && pwd -P)"
[[ "$git_dir_absolute" == "$common_dir_absolute" ]] || {
  printf 'Run this helper from the primary checkout, not a linked worktree.\n' >&2
  exit 1
}

if [[ -z "$base" ]]; then
  base="$(git -C "$repo_root" branch --show-current)"
  [[ -n "$base" ]] || {
    printf 'HEAD is detached; pass --base <local-branch>.\n' >&2
    exit 1
  }
fi

if ! git -C "$repo_root" show-ref --verify --quiet "refs/heads/$base"; then
  printf 'Local base branch does not exist: %s\n' "$base" >&2
  exit 1
fi

slug="$(
  printf '%s' "$title" |
    tr '[:upper:]' '[:lower:]' |
    sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//'
)"
[[ -n "$slug" ]] || {
  printf 'Title did not produce a usable ASCII slug.\n' >&2
  exit 2
}

issue_branch="${issue}-${slug}"
git check-ref-format --branch "$issue_branch" >/dev/null
repo_name="$(basename "$repo_root")"
destination="$(dirname "$repo_root")/${repo_name}-${issue_branch}"

[[ ! -e "$destination" ]] || {
  printf 'Destination already exists: %s\n' "$destination" >&2
  exit 1
}

if git -C "$repo_root" show-ref --verify --quiet \
  "refs/heads/$issue_branch"; then
  printf 'Local branch already exists: %s\n' "$issue_branch" >&2
  exit 1
fi

remote_collision="$(
  git -C "$repo_root" for-each-ref --format='%(refname)' refs/remotes |
    awk -v suffix="/${issue_branch}" '
      length($0) >= length(suffix) &&
      substr($0, length($0) - length(suffix) + 1) == suffix {
        print
      }
    '
)"
if [[ -n "$remote_collision" ]]; then
  printf 'Remote branch already exists for %s:\n%s\n' \
    "$issue_branch" "$remote_collision" >&2
  exit 1
fi

base_commit="$(git -C "$repo_root" rev-parse "$base^{commit}")"
if [[ -n "$(git -C "$repo_root" status --porcelain)" ]]; then
  printf 'Warning: primary checkout is dirty; uncommitted files are excluded.\n' \
    >&2
fi

git -C "$repo_root" worktree add \
  -b "$issue_branch" \
  "$destination" \
  "$base"

printf 'Worktree created.\n'
printf '  base branch:  %s\n' "$base"
printf '  base commit:  %s\n' "$base_commit"
printf '  directory:    %s\n' "$destination"
printf '  issue branch: %s\n' "$issue_branch"
printf '\nStart a fresh coding-agent task from this directory:\n'
printf '  cd %q\n' "$destination"
