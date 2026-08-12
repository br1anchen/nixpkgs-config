# Remove stale temporary directories leaked by `nix develop`.
#
# Nix replaces itself with the development shell before its temporary-directory
# cleanup runs. Keep recent directories, directories tied to a live Nix shell
# PID, and directories with open files.

minimum_age_minutes=1440
uid="$(id -u)"
deleted=0
skipped=0
roots=(/tmp)

if [[ -d /private/tmp ]]; then
  roots+=(/private/tmp)
fi

if [[ -n "${TMPDIR:-}" && -d "$TMPDIR" ]]; then
  roots+=("$TMPDIR")
fi

seen_roots=""
process_scan_ok=false
declare -A referenced_temp_dirs=()

if process_environments="$(ps eww -U "$uid" -o command= 2>/dev/null)"; then
  process_scan_ok=true
  set -f
  while IFS= read -r process; do
    for token in $process; do
      if [[ "$token" =~ /(nix-develop-[0-9]+-[0-9]+|nix-shell\.[a-zA-Z0-9]{6})(/|$) ]]; then
        referenced_temp_dirs["${BASH_REMATCH[1]}"]=1
      fi
    done
  done <<< "$process_environments"
  set +f
fi

for root in "${roots[@]}"; do
  root="$(cd "$root" && pwd -P)"

  case $'\n'"$seen_roots"$'\n' in
    *$'\n'"$root"$'\n'*)
      continue
      ;;
  esac
  seen_roots+=$'\n'"$root"

  candidates=()
  while IFS= read -r -d '' candidate; do
    candidates+=("$candidate")
  done < <(
    find "$root" \
      -mindepth 1 \
      -maxdepth 1 \
      -type d \
      -uid "$uid" \
      \( -name 'nix-develop-[0-9]*-[0-9]*' -o -name 'nix-shell.*' \) \
      -mmin "+$minimum_age_minutes" \
      -print0
  )

  if (( ${#candidates[@]} == 0 )); then
    continue
  fi

  open_paths="$(lsof -n -P +D "$root" -Fn 2>/dev/null || true)"

  live_nix_develop_pid=false
  while IFS= read -r -d '' directory; do
    name="${directory##*/}"
    if [[ "$name" =~ ^nix-develop-([0-9]+)-[0-9]+$ ]] \
      && kill -0 "${BASH_REMATCH[1]}" 2>/dev/null; then
      live_nix_develop_pid=true
      break
    fi
  done < <(
    find "$root" \
      -mindepth 1 \
      -maxdepth 1 \
      -type d \
      -uid "$uid" \
      -name 'nix-develop-[0-9]*-[0-9]*' \
      -print0
  )

  for candidate in "${candidates[@]}"; do
    name="${candidate##*/}"

    if [[ "$name" == nix-develop-* ]]; then
      if [[ ! "$name" =~ ^nix-develop-([0-9]+)-[0-9]+$ ]]; then
        ((skipped += 1))
        continue
      fi

      if kill -0 "${BASH_REMATCH[1]}" 2>/dev/null; then
        ((skipped += 1))
        continue
      fi
    elif [[ ! "$name" =~ ^nix-shell\.[a-zA-Z0-9]{6}$ ]]; then
      ((skipped += 1))
      continue
    fi

    if [[ "$process_scan_ok" != true || -n "${referenced_temp_dirs[$name]:-}" ]]; then
      ((skipped += 1))
      continue
    fi

    if [[ "$name" == nix-shell.* && "$live_nix_develop_pid" == true ]]; then
      # The random nix-shell.* name cannot be paired with its nix-develop PID,
      # so keep them all while any development shell PID is alive.
      ((skipped += 1))
      continue
    fi

    in_use=false
    while IFS= read -r open_path; do
      case "$open_path" in
        "n$candidate"|"n$candidate/"*)
          in_use=true
          break
          ;;
      esac
    done <<< "$open_paths"

    if [[ "$in_use" == true ]]; then
      ((skipped += 1))
      continue
    fi

    rm -rf -- "$candidate"
    ((deleted += 1))
  done
done

printf 'Removed %d stale Nix temporary directories' "$deleted"
if (( skipped > 0 )); then
  printf '; kept %d in-use directories' "$skipped"
fi
printf '.\n'
