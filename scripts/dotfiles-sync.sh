#!/usr/bin/env bash
# dotfiles-sync — reconcile this repo with live ~/.config on Omarchy.
#
# Why this exists: Omarchy's write paths do not respect symlinks. `cp -f` (used
# by `omarchy refresh config` and several migrations) writes THROUGH a symlink
# into the repo; `sed -i` REPLACES the symlink with a regular file; and a
# read-only /nix/store symlink is silently unlinked and replaced. So on Omarchy
# the live file is authoritative and home-manager writes nothing under
# ~/.config. This script moves content between the two, explicitly.
#
#   status                  show which tracked paths differ, and which side moved
#   pull                    live -> repo, whole file, reviewing each change
#   pull --report           live -> repo, report only (used by the post-update hook)
#   push                    repo -> live, whole file, copying with a .bak.<epoch> first
#   merge [--base-rev REV]  three-way merge of repo and live against the last
#                           synced content; overlapping hunks land as conflict
#                           markers in the REPO file, live is left untouched
#
# Every command takes trailing path filters (substrings of the repo or live path).
#
# Omarchy's migrations SILENTLY SKIP files you have edited (the careful ones
# checksum first and bail; the sloppy ones sed an exact stock line and no-op).
# You are never told. `pull --report` from a post-update hook is how that drift
# becomes visible.
#
# Merge base. Every successful push, adopt or merge records the resulting
# content under $XDG_STATE_HOME/dotfiles-sync/base/<live path>. With that base,
# `merge` can tell an Omarchy migration (live moved) from a repo edit (repo
# moved) from both, and only hunks that genuinely overlap need a human. `push`
# refuses a file whose live copy moved since the base, so an Omarchy change is
# never clobbered by accident: merge first, then push.
#
# Without a base (first run, or a file never synced), `merge` seeds one from the
# repo's git history: the revision of the repo file closest to the live copy,
# which is almost always what was last pushed. It prints the revision it chose;
# override with --base-rev when it guesses wrong.
#
# Conflict flow: `merge` writes the marker file to the repo (so `git diff` shows
# it) and records the live content as the new base, because every live hunk is
# now inside that marker file. Resolve the markers, then `push`.

set -euo pipefail

# Resolve the repo checkout: explicit override, else alongside this script (when
# run from the working tree), else the conventional location. Never a /nix/store
# path -- `pull` has to write into a real git checkout.
if [ -n "${DOTFILES_REPO:-}" ]; then
  REPO="$DOTFILES_REPO"
elif [ -f "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)/dotfiles/manifest.tsv" ]; then
  REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
else
  REPO="$HOME/nixpkgs-config"
fi
MANIFEST="$REPO/dotfiles/manifest.tsv"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/dotfiles-sync/base"

case "$(uname -s)" in
  Darwin) PLATFORM="darwin" ;;
  *)      PLATFORM="omarchy" ;;
esac

[ -f "$MANIFEST" ] || { echo "manifest not found: $MANIFEST" >&2; exit 1; }

c_red=$'\033[31m'; c_grn=$'\033[32m'; c_yel=$'\033[33m'; c_dim=$'\033[2m'; c_off=$'\033[0m'

TMPDIR_SYNC="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_SYNC"' EXIT

applies() { [ "$1" = "both" ] || [ "$1" = "$PLATFORM" ]; }

# selected <repo> <live> -> 0 if no filters were given or one matches either path
selected() {
  [ "${#FILTERS[@]}" -eq 0 ] && return 0
  local f
  for f in "${FILTERS[@]}"; do
    case "$1" in *"$f"*) return 0 ;; esac
    case "$2" in *"$f"*) return 0 ;; esac
  done
  return 1
}

# hm_managed <path> -> 0 if the path is home-manager's rather than ours: a
# /nix/store symlink, or a directory containing nothing but such symlinks.
# Directory entries are overlaid, not replaced, so ~/.config/nvim legitimately
# holds home-manager's after/plugin/herdr_nav.lua alongside the repo's files.
# Without this, that one drop-in would make ~/.config/nvim report drift forever
# and the post-update report would be noise.
hm_managed() {
  local p="$1" target f
  if [ -L "$p" ]; then
    target="$(readlink "$p")"
    case "$target" in /nix/store/*) return 0 ;; *) return 1 ;; esac
  fi
  [ -d "$p" ] || return 1
  # any regular (non-symlink) file means this is not purely home-manager's
  if find "$p" -type f -print -quit 2>/dev/null | grep -q .; then return 1; fi
  local any=1
  while IFS= read -r f; do
    any=0
    target="$(readlink "$f" 2>/dev/null)"
    case "$target" in /nix/store/*) ;; *) return 1 ;; esac
  done < <(find "$p" -type l 2>/dev/null)
  return $any
}

# dir_diff <repo> <live> -> diff lines, minus anything home-manager owns
dir_diff() {
  local r="$1" l="$2" line d n
  diff -rq "$r" "$l" 2>/dev/null | while IFS= read -r line; do
    case "$line" in
      "Only in $l"*|"Only in $l/"*)
        d="${line#Only in }"; d="${d%%: *}"; n="${line##*: }"
        hm_managed "$d/$n" && continue
        ;;
    esac
    printf '%s\n' "$line"
  done
}

# differs <a> <b> <kind> -> 0 if different (or b absent)
differs() {
  local a="$1" b="$2" kind="$3"
  [ -e "$b" ] || return 0
  if [ "$kind" = "dir" ]; then
    [ -n "$(dir_diff "$a" "$b")" ]
  else
    ! cmp -s "$a" "$b"
  fi
}

show_diff() {
  local r="$1" l="$2" kind="$3"
  if [ "$kind" = "dir" ]; then
    dir_diff "$r" "$l" | head -200 || true
  else
    diff -u "$r" "$l" 2>/dev/null | head -200 || true
  fi
}

backup() {
  local target="$1"
  [ -e "$target" ] || return 0
  local bak="${target}.bak.$(date +%s)"
  cp -a "$target" "$bak"
  echo "    ${c_dim}backed up -> $bak${c_off}"
}

# copy_tree <src> <dst> — replace dst with src, preserving nothing stale
copy_tree() {
  local src="$1" dst="$2"
  mkdir -p "$(dirname "$dst")"
  if [ -d "$src" ]; then
    # Overlay rather than replace: ~/.config/nvim also holds home-manager's
    # herdr_nav.lua drop-in under after/plugin/, which `rm -rf` would delete.
    # Stale files removed from the repo must therefore be pruned by hand.
    mkdir -p "$dst"
    cp -a "$src/." "$dst/"
  else
    cp -a "$src" "$dst"
  fi
}

# --- merge base -------------------------------------------------------------

base_path() { printf '%s/%s' "$STATE_DIR" "$1"; }

# record_base <src> <live_rel> — remember src as the last synced content
record_base() {
  local src="$1" b; b="$(base_path "$2")"
  rm -rf "$b"
  mkdir -p "$(dirname "$b")"
  cp -a "$src" "$b"
}

has_conflict_markers() {
  [ -f "$1" ] && grep -qE '^(<{7}( |$)|={7}$|>{7}( |$))' "$1"
}

# seed_base <repo_rel> <live_abs> <out> — write the repo's git revision closest
# to live into <out>, print the revision. 1 if the file has no history.
seed_base() {
  local repo_rel="$1" live="$2" out="$3" rev n best="" best_n=-1
  if [ -n "$BASE_REV" ]; then
    git -C "$REPO" show "$BASE_REV:$repo_rel" > "$out" 2>/dev/null || return 1
    echo "$BASE_REV"
    return 0
  fi
  while IFS= read -r rev; do
    git -C "$REPO" show "$rev:$repo_rel" > "$out.cand" 2>/dev/null || continue
    n="$(diff "$out.cand" "$live" | grep -c '^[<>]' || true)"
    # strict '<' keeps the newest revision on a tie (log is newest-first)
    if [ "$best_n" -lt 0 ] || [ "$n" -lt "$best_n" ]; then
      best_n=$n; best=$rev; mv "$out.cand" "$out"
    fi
  done < <(git -C "$REPO" log -n 50 --format=%H -- "$repo_rel")
  rm -f "$out.cand"
  [ -n "$best" ] || return 1
  echo "${best:0:7}"
}

# classify <repo> <live> <kind> <live_rel> -> same | absent-live | conflict |
#   no-base | repo-changed | live-changed | both-changed
classify() {
  local r="$1" l="$2" kind="$3" b; b="$(base_path "$4")"
  [ -e "$l" ] || { echo absent-live; return; }
  if [ "$kind" = "file" ] && has_conflict_markers "$r"; then echo conflict; return; fi
  differs "$r" "$l" "$kind" || { echo same; return; }
  [ -e "$b" ] || { echo no-base; return; }
  local rm=0 lm=0
  differs "$r" "$b" "$kind" && rm=1
  differs "$l" "$b" "$kind" && lm=1
  if [ $rm -eq 1 ] && [ $lm -eq 1 ]; then echo both-changed
  elif [ $rm -eq 1 ]; then echo repo-changed
  elif [ $lm -eq 1 ]; then echo live-changed
  else echo both-changed   # base is stale in a way neither side explains; merge decides
  fi
}

# --- commands ----------------------------------------------------------------

read_manifest() {
  grep -vE '^\s*#|^\s*$' "$MANIFEST"
}

cmd_status() {
  local n=0 state
  while IFS=$'\t' read -r repo live kind plat; do
    applies "$plat" || continue
    selected "$repo" "$live" || continue
    state="$(classify "$REPO/$repo" "$HOME/$live" "$kind" "$live")"
    case "$state" in
      same)         printf '%s           %-40s\n' "${c_grn}same${c_off}" "$live" ;;
      absent-live)  printf '%s    %-40s %s\n' "${c_yel}absent-live${c_off}" "$live" "${c_dim}(push to create)${c_off}"; n=$((n+1)) ;;
      conflict)     printf '%s       %-40s %s\n' "${c_red}conflict${c_off}" "$live" "${c_dim}(resolve markers in $repo, then push)${c_off}"; n=$((n+1)) ;;
      no-base)      printf '%s        %-40s %s\n' "${c_red}differs${c_off}" "$live" "${c_dim}(no base yet: merge seeds one from git)${c_off}"; n=$((n+1)) ;;
      repo-changed) printf '%s   %-40s %s\n' "${c_yel}repo-moved${c_off}" "$live" "${c_dim}(push)${c_off}"; n=$((n+1)) ;;
      live-changed) printf '%s   %-40s %s\n' "${c_yel}live-moved${c_off}" "$live" "${c_dim}(pull, or merge)${c_off}"; n=$((n+1)) ;;
      both-changed) printf '%s   %-40s %s\n' "${c_red}both-moved${c_off}" "$live" "${c_dim}(merge)${c_off}"; n=$((n+1)) ;;
    esac
  done < <(read_manifest)
  [ "$n" -eq 0 ] && echo "${c_grn}in sync${c_off}"
  return 0
}

cmd_pull() {
  local drift=0
  while IFS=$'\t' read -r repo live kind plat; do
    applies "$plat" || continue
    selected "$repo" "$live" || continue
    local r="$REPO/$repo" l="$HOME/$live"
    [ -e "$l" ] || continue
    differs "$r" "$l" "$kind" || continue
    drift=$((drift+1))
    echo
    echo "${c_yel}drift:${c_off} $live ${c_dim}-> $repo${c_off}"
    show_diff "$r" "$l" "$kind"
    if [ "$REPORT" = "--report" ]; then
      continue
    fi
    read -r -p "  adopt live version into repo? [y/N] " ans </dev/tty || ans=n
    case "$ans" in
      y|Y) copy_tree "$l" "$r"; record_base "$r" "$live"; echo "  ${c_grn}adopted${c_off} -> $repo" ;;
      *)   echo "  ${c_dim}skipped${c_off}" ;;
    esac
  done < <(read_manifest)
  if [ "$drift" -eq 0 ]; then
    echo "${c_grn}no drift${c_off}"
  elif [ "$REPORT" = "--report" ]; then
    echo
    echo "${c_yel}$drift tracked file(s) drifted from the repo.${c_off}"
    echo "Review with: dotfiles-sync pull   (whole file)   or   dotfiles-sync merge   (three-way)"
  fi
  return 0
}

cmd_push() {
  if [ "$PLATFORM" = "darwin" ]; then
    echo "refusing to push on macOS: home-manager owns these paths as symlinks there." >&2
    exit 1
  fi
  local state
  while IFS=$'\t' read -r repo live kind plat; do
    applies "$plat" || continue
    selected "$repo" "$live" || continue
    local r="$REPO/$repo" l="$HOME/$live"
    [ -e "$r" ] || { echo "skip (absent in repo): $repo" >&2; continue; }
    state="$(classify "$r" "$l" "$kind" "$live")"
    case "$state" in
      same) continue ;;
      conflict)
        echo "${c_red}refuse${c_off} $repo ${c_dim}still has conflict markers; resolve them first${c_off}"; continue ;;
      live-changed|both-changed)
        echo "${c_red}refuse${c_off} $repo ${c_dim}~/$live moved since the last sync; run: dotfiles-sync merge $live${c_off}"; continue ;;
    esac
    echo "${c_grn}push${c_off} $repo -> ~/$live"
    backup "$l"
    copy_tree "$r" "$l"
    record_base "$r" "$live"
  done < <(read_manifest)
  return 0
}

# merge_file <repo_rel> <live_rel> — three-way merge of one regular file
merge_file() {
  local repo_rel="$1" live_rel="$2"
  local r="$REPO/$repo_rel" l="$HOME/$live_rel" b; b="$(base_path "$live_rel")"
  local tag="$live_rel"

  if has_conflict_markers "$r"; then
    echo "${c_red}conflict${c_off}   $tag ${c_dim}unresolved markers in $repo_rel; resolve, then push${c_off}"
    return 0
  fi
  if [ ! -e "$l" ]; then
    echo "${c_grn}push${c_off}       $tag ${c_dim}(absent live)${c_off}"
    copy_tree "$r" "$l"; record_base "$r" "$live_rel"
    return 0
  fi
  if cmp -s "$r" "$l"; then
    [ -e "$b" ] || record_base "$r" "$live_rel"
    return 0
  fi

  local seeded=""
  if [ ! -e "$b" ]; then
    local tmp="$TMPDIR_SYNC/base.$$.$RANDOM"
    if seeded="$(seed_base "$repo_rel" "$l" "$tmp")"; then
      b="$tmp"
    else
      echo "${c_red}no-base${c_off}    $tag ${c_dim}no git history to seed from; use pull or push${c_off}"
      return 0
    fi
  fi

  local repo_moved=0 live_moved=0
  cmp -s "$r" "$b" || repo_moved=1
  cmp -s "$l" "$b" || live_moved=1
  [ -n "$seeded" ] && echo "${c_dim}base:${c_off}       $tag ${c_dim}seeded from repo @ $seeded${c_off}"

  if [ $live_moved -eq 0 ]; then
    echo "${c_grn}push${c_off}       $tag ${c_dim}(only the repo moved)${c_off}"
    backup "$l"
    copy_tree "$r" "$l"; record_base "$r" "$live_rel"
    return 0
  fi
  if [ $repo_moved -eq 0 ]; then
    echo "${c_yel}live-moved${c_off} $tag ${c_dim}(only live moved; Omarchy drift?)${c_off}"
    diff -u "$r" "$l" | head -200 || true
    read -r -p "  adopt live version into repo? [y/N] " ans </dev/tty || ans=n
    case "$ans" in
      y|Y) copy_tree "$l" "$r"; record_base "$r" "$live_rel"; echo "  ${c_grn}adopted${c_off} -> $repo_rel" ;;
      *)   echo "  ${c_dim}kept repo; push $live_rel to overwrite live${c_off}" ;;
    esac
    return 0
  fi

  local merged="$TMPDIR_SYNC/merged.$$.$RANDOM" rc=0
  git merge-file -p -L "repo: $repo_rel" -L "base" -L "live: ~/$live_rel" "$r" "$b" "$l" > "$merged" || rc=$?
  if [ $rc -eq 0 ]; then
    echo "${c_grn}merged${c_off}     $tag ${c_dim}(both moved, no overlap)${c_off}"
    backup "$l"
    cat "$merged" > "$r"
    cat "$merged" > "$l"
    record_base "$r" "$live_rel"
  elif [ $rc -lt 128 ]; then
    echo "${c_red}conflict${c_off}   $tag ${c_dim}$rc overlapping hunk(s) -> markers written to $repo_rel; live untouched${c_off}"
    cat "$merged" > "$r"
    # every live hunk is now inside the repo file, so live counts as consumed:
    # after the markers are resolved, push must not refuse it as "live moved".
    record_base "$l" "$live_rel"
  else
    echo "${c_red}error${c_off}      $tag ${c_dim}git merge-file failed (binary?); use pull or push${c_off}"
  fi
  return 0
}

# merge_dir <repo_rel> <live_rel> — per-file merge over the union of both trees
merge_dir() {
  local repo_rel="$1" live_rel="$2"
  local r="$REPO/$repo_rel" l="$HOME/$live_rel" b; b="$(base_path "$live_rel")"
  local f
  while IFS= read -r f; do
    if [ -e "$r/$f" ] && [ -e "$l/$f" ]; then
      merge_file "$repo_rel/$f" "$live_rel/$f"
    elif [ -e "$r/$f" ]; then
      if [ -e "$b/$f" ]; then
        echo "${c_yel}live-removed${c_off} $live_rel/$f ${c_dim}(in repo and base, gone live; delete from repo or push to restore)${c_off}"
      else
        echo "${c_grn}push${c_off}       $live_rel/$f ${c_dim}(new in repo)${c_off}"
        copy_tree "$r/$f" "$l/$f"; record_base "$r/$f" "$live_rel/$f"
      fi
    else
      hm_managed "$l/$f" && continue
      if [ -e "$b/$f" ]; then
        echo "${c_yel}repo-removed${c_off} $live_rel/$f ${c_dim}(removed in repo, still live; delete by hand)${c_off}"
      else
        echo "${c_yel}live-new${c_off}   $live_rel/$f"
        read -r -p "  adopt new live file into repo? [y/N] " ans </dev/tty || ans=n
        case "$ans" in
          y|Y) copy_tree "$l/$f" "$r/$f"; record_base "$r/$f" "$live_rel/$f"; echo "  ${c_grn}adopted${c_off}" ;;
          *)   echo "  ${c_dim}skipped${c_off}" ;;
        esac
      fi
    fi
  done < <(
    { (cd "$r" && find . -type f); [ -d "$l" ] && (cd "$l" && find . -type f -o -type l); } 2>/dev/null \
      | sed 's|^\./||' | sort -u
  )
}

cmd_merge() {
  if [ "$PLATFORM" = "darwin" ]; then
    echo "refusing to merge on macOS: home-manager owns these paths as symlinks there." >&2
    exit 1
  fi
  command -v git >/dev/null || { echo "merge needs git" >&2; exit 1; }
  while IFS=$'\t' read -r repo live kind plat; do
    applies "$plat" || continue
    selected "$repo" "$live" || continue
    [ -e "$REPO/$repo" ] || { echo "skip (absent in repo): $repo" >&2; continue; }
    if [ "$kind" = "dir" ]; then merge_dir "$repo" "$live"; else merge_file "$repo" "$live"; fi
  done < <(read_manifest)
  return 0
}

# --- args --------------------------------------------------------------------

usage() { echo "usage: dotfiles-sync {status|pull [--report]|push|merge [--base-rev REV]} [path-filter...]" >&2; exit 2; }

CMD="${1:-status}"; [ $# -gt 0 ] && shift
REPORT=""; BASE_REV=""; FILTERS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --report)     REPORT="--report" ;;
    --base-rev)   [ $# -ge 2 ] || usage; BASE_REV="$2"; shift ;;
    --base-rev=*) BASE_REV="${1#--base-rev=}" ;;
    -*)           usage ;;
    *)            FILTERS+=("$1") ;;
  esac
  shift
done

case "$CMD" in
  status) cmd_status ;;
  pull)   cmd_pull ;;
  push)   cmd_push ;;
  merge)  cmd_merge ;;
  *) usage ;;
esac
