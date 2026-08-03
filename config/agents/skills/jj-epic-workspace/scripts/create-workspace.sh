#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  create-workspace.sh --issue <number> --title <title> [--base <bookmark>]

Creates a sibling jj workspace and matching local bookmark from the nearest
bookmark in the default workspace. Pass --base when that bookmark is ambiguous.
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
  printf 'Issue must be a numeric GitHub issue number.\n' >&2
  exit 2
}
[[ -n "$title" ]] || {
  printf 'Title must not be empty.\n' >&2
  exit 2
}
command -v jj >/dev/null || {
  printf 'jj is required.\n' >&2
  exit 1
}

repo_root="$(jj --ignore-working-copy workspace root)"
workspace_name="$(
  jj --ignore-working-copy log -r '@' --no-graph \
    -T 'working_copies.map(|w| w.name()).join("\n") ++ "\n"'
)"
[[ -z "$workspace_name" || "$workspace_name" == "default" ]] || {
  printf 'Run this helper from the default jj workspace; current workspace is %s.\n' \
    "$workspace_name" >&2
  exit 1
}

if [[ -z "$base" ]]; then
  candidates="$(
    jj --ignore-working-copy log \
      -r 'heads(ancestors(@) & bookmarks())' \
      --no-graph \
      -T 'bookmarks.map(|b| b.name()).join("\n") ++ "\n"'
  )"
  candidate_count="$(
    printf '%s\n' "$candidates" |
      awk 'NF { count += 1 } END { print count + 0 }'
  )"
  if [[ "$candidate_count" -ne 1 ]]; then
    printf 'Could not infer exactly one base bookmark. Candidates:\n%s\n' \
      "${candidates:-<none>}" >&2
    printf 'Pass --base <bookmark>.\n' >&2
    exit 1
  fi
  base="$(printf '%s\n' "$candidates" | awk 'NF { print; exit }')"
fi

base_listing="$(jj --ignore-working-copy bookmark list "$base")"
if ! awk -v bookmark="$base" '
  index($0, bookmark ":") == 1 { found = 1 }
  END { exit(found ? 0 : 1) }
' <<<"$base_listing"; then
  printf 'Local base bookmark does not exist exactly: %s\n' "$base" >&2
  exit 1
fi

base_change_id="$(
  jj --ignore-working-copy log -r "$base" --no-graph \
    -T 'change_id ++ "\n"'
)"
working_copy_change_id="$(
  jj --ignore-working-copy log -r '@' --no-graph \
    -T 'change_id ++ "\n"'
)"
if [[ "$base_change_id" == "$working_copy_change_id" ]]; then
  printf 'Base bookmark %s points at the active default working-copy change.\n' \
    "$base" >&2
  printf 'At a safe boundary, describe that slice and run jj new, then retry.\n' \
    >&2
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

issue_bookmark="${issue}-${slug}"
repo_name="$(basename "$repo_root")"
destination="$(dirname "$repo_root")/${repo_name}-${issue_bookmark}"

[[ ! -e "$destination" ]] || {
  printf 'Destination already exists: %s\n' "$destination" >&2
  exit 1
}

bookmark_listing="$(
  jj --ignore-working-copy bookmark list --all-remotes "$issue_bookmark"
)"
if awk -v bookmark="$issue_bookmark" '
  index($0, bookmark ":") == 1 || index($0, bookmark "@") == 1 { found = 1 }
  END { exit(found ? 0 : 1) }
' <<<"$bookmark_listing"; then
  printf 'Local or remote bookmark already exists: %s\n' "$issue_bookmark" >&2
  exit 1
fi

jj --ignore-working-copy workspace add \
  "$destination" \
  --name "$issue_bookmark" \
  --revision "$base" \
  --sparse-patterns full

jj -R "$destination" describe -m "wip: ${title} (#${issue})"
jj -R "$destination" bookmark create "$issue_bookmark" -r '@'

printf 'Workspace created.\n'
printf '  base bookmark:  %s\n' "$base"
printf '  directory:      %s\n' "$destination"
printf '  workspace:      %s\n' "$issue_bookmark"
printf '  issue bookmark: %s\n' "$issue_bookmark"
printf '\nStart a fresh coding-agent task from this directory:\n'
printf '  cd %q\n' "$destination"
