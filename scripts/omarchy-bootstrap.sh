#!/usr/bin/env bash
# omarchy-bootstrap — one-time, idempotent wiring between this repo and Omarchy.
#
# Deliberately NOT done by home-manager:
#   1. ~/.bashrc      - Omarchy owns it (and the manual guarantees updates never
#                       overwrite it). We append exactly one source line.
#   2. ~/.config/uwsm/env
#                     - the Hyprland session's environment comes from
#                       /usr/share/uwsm/env.d/10-omarchy, which knows nothing
#                       about ~/.nix-profile/bin. Without this, any nix binary
#                       launched from a keybinding (herdr on SUPER+CTRL+RETURN,
#                       for one) fails with "not found".
#   3. post-update hook
#                     - Omarchy's migrations SILENTLY SKIP files you have edited.
#                       This surfaces the resulting drift right when it happens.
#   4. chromium search policy
#                     - lives in /etc, not $HOME, so home-manager cannot own it.
#                       Needs sudo.
#
# Safe to re-run.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MARKER="# >>> nixpkgs-config shared shell layer >>>"

if [ "$(uname -s)" = "Darwin" ]; then
  echo "this bootstrap is for Omarchy hosts only" >&2
  exit 1
fi

# --- 1. shared shell layer -------------------------------------------------
BASHRC="$HOME/.bashrc"
if grep -qF "$MARKER" "$BASHRC" 2>/dev/null; then
  echo "[=] ~/.bashrc already sources the shared shell layer"
else
  cat >> "$BASHRC" <<'EOF'

# >>> nixpkgs-config shared shell layer >>>
# Installed by scripts/omarchy-bootstrap.sh. The target is a stable profile path
# rather than a /nix/store path so it survives home-manager rebuilds.
if [ -r "$HOME/.nix-profile/etc/profile.d/shared-shell.sh" ]; then
  . "$HOME/.nix-profile/etc/profile.d/shared-shell.sh"
fi
# <<< nixpkgs-config shared shell layer <<<
EOF
  echo "[+] appended shared shell layer source line to ~/.bashrc"
fi

# --- 2. uwsm session PATH --------------------------------------------------
UWSM_ENV="$HOME/.config/uwsm/env"
mkdir -p "$(dirname "$UWSM_ENV")"
if grep -q 'nix-profile' "$UWSM_ENV" 2>/dev/null; then
  echo "[=] ~/.config/uwsm/env already exposes the nix profile"
else
  cat >> "$UWSM_ENV" <<'EOF'
# Expose the home-manager profile to the Hyprland/uwsm session.
#
# PREPEND, never replace: Omarchy's env.d entry puts the mise shim dir and
# /usr/share/omarchy/bin on PATH, and dropping those breaks omarchy-* scripts
# and every mise-managed tool launched from a keybinding.
# bob's nvim-bin is included for the same reason: with pacman's neovim removed,
# omarchy-launch-editor (SUPER+N and the menu) resolves `nvim` from the session
# PATH, which never sources ~/.bashrc.
export PATH="$HOME/.nix-profile/bin:$HOME/.local/share/bob/nvim-bin:$PATH"
EOF
  echo "[+] added ~/.nix-profile/bin and bob's nvim-bin to ~/.config/uwsm/env"
fi

# --- 3. drift-reporting post-update hook ------------------------------------
HOOK_DIR="$HOME/.config/omarchy/hooks/post-update.d"
HOOK="$HOOK_DIR/10-dotfiles-drift"
mkdir -p "$HOOK_DIR"
cat > "$HOOK" <<EOF
#!/usr/bin/env bash
# Report tracked dotfiles that Omarchy's update changed out from under the repo.
#
# This matters because migrations that hit a file you have edited SKIP SILENTLY:
# the careful ones checksum first and bail, the sloppy ones sed an exact stock
# line and no-op. Nothing tells you either happened.
exec "\$HOME/.nix-profile/bin/dotfiles-sync" pull --report
EOF
chmod 755 "$HOOK"
echo "[+] installed $HOOK"

# --- 4. chromium default search provider ------------------------------------
# Chromium on Linux reads enterprise policy only from /etc/chromium/policies;
# there is no per-user policy directory, so this cannot be a home-manager path.
# The DefaultSearchProvider* policies are mandatory-only (Chromium does not
# honour them under policies/recommended), which is why the engine shows up as
# "managed by your organization" and is not switchable from chrome://settings.
POLICY_SRC="$REPO/config/chromium/policies/search-provider.json"
POLICY_DST="/etc/chromium/policies/managed/search-provider.json"
if cmp -s "$POLICY_SRC" "$POLICY_DST" 2>/dev/null; then
  echo "[=] $POLICY_DST already matches the repo"
else
  sudo install -Dm644 "$POLICY_SRC" "$POLICY_DST"
  echo "[+] installed $POLICY_DST (restart chromium to pick it up)"
fi

echo
echo "done. Repo: $REPO"
