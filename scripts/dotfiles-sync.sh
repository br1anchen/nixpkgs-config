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
#   status            show which tracked paths differ
#   pull              live -> repo, reviewing each change
#   pull --report     live -> repo, report only (used by the post-update hook)
#   push              repo -> live, copying with a .bak.<epoch> first
#
# Omarchy's migrations SILENTLY SKIP files you have edited (the careful ones
# checksum first and bail; the sloppy ones sed an exact stock line and no-op).
# You are never told. `pull --report` from a post-update hook is how that drift
# becomes visible.

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

case "$(uname -s)" in
  Darwin) PLATFORM="darwin" ;;
  *)      PLATFORM="omarchy" ;;
esac

[ -f "$MANIFEST" ] || { echo "manifest not found: $MANIFEST" >&2; exit 1; }

c_red=$'\033[31m'; c_grn=$'\033[32m'; c_yel=$'\033[33m'; c_dim=$'\033[2m'; c_off=$'\033[0m'

applies() { [ "$1" = "both" ] || [ "$1" = "$PLATFORM" ]; }

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

# differs <repo_abs> <live_abs> <kind> -> 0 if different
differs() {
  local r="$1" l="$2" kind="$3"
  [ -e "$l" ] || return 0
  if [ "$kind" = "dir" ]; then
    [ -n "$(dir_diff "$r" "$l")" ]
  else
    ! cmp -s "$r" "$l"
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

read_manifest() {
  grep -vE '^\s*#|^\s*$' "$MANIFEST"
}

cmd_status() {
  local n=0
  while IFS=$'\t' read -r repo live kind plat; do
    applies "$plat" || continue
    local r="$REPO/$repo" l="$HOME/$live"
    if [ ! -e "$l" ]; then
      printf '%s  %-40s %s\n' "${c_yel}absent-live${c_off}" "$live" "${c_dim}(push to create)${c_off}"; n=$((n+1))
    elif differs "$r" "$l" "$kind"; then
      printf '%s        %-40s\n' "${c_red}differs${c_off}" "$live"; n=$((n+1))
    else
      printf '%s           %-40s\n' "${c_grn}same${c_off}" "$live"
    fi
  done < <(read_manifest)
  [ "$n" -eq 0 ] && echo "${c_grn}in sync${c_off}"
  return 0
}

cmd_pull() {
  local report_only="${1:-}"
  local drift=0
  while IFS=$'\t' read -r repo live kind plat; do
    applies "$plat" || continue
    local r="$REPO/$repo" l="$HOME/$live"
    [ -e "$l" ] || continue
    differs "$r" "$l" "$kind" || continue
    drift=$((drift+1))
    echo
    echo "${c_yel}drift:${c_off} $live ${c_dim}-> $repo${c_off}"
    show_diff "$r" "$l" "$kind"
    if [ "$report_only" = "--report" ]; then
      continue
    fi
    read -r -p "  adopt live version into repo? [y/N] " ans </dev/tty || ans=n
    case "$ans" in
      y|Y) copy_tree "$l" "$r"; echo "  ${c_grn}adopted${c_off} -> $repo" ;;
      *)   echo "  ${c_dim}skipped${c_off}" ;;
    esac
  done < <(read_manifest)
  if [ "$drift" -eq 0 ]; then
    echo "${c_grn}no drift${c_off}"
  elif [ "$report_only" = "--report" ]; then
    echo
    echo "${c_yel}$drift tracked file(s) drifted from the repo.${c_off}"
    echo "Review with: dotfiles-sync pull"
  fi
  return 0
}

cmd_push() {
  if [ "$PLATFORM" = "darwin" ]; then
    echo "refusing to push on macOS: home-manager owns these paths as symlinks there." >&2
    exit 1
  fi
  while IFS=$'\t' read -r repo live kind plat; do
    applies "$plat" || continue
    local r="$REPO/$repo" l="$HOME/$live"
    [ -e "$r" ] || { echo "skip (absent in repo): $repo" >&2; continue; }
    differs "$r" "$l" "$kind" || continue
    echo "${c_grn}push${c_off} $repo -> ~/$live"
    backup "$l"
    copy_tree "$r" "$l"
  done < <(read_manifest)
  return 0
}

case "${1:-status}" in
  status) cmd_status ;;
  pull)   cmd_pull "${2:-}" ;;
  push)   cmd_push ;;
  *) echo "usage: dotfiles-sync {status|pull [--report]|push}" >&2; exit 2 ;;
esac
