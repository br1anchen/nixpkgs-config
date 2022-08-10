#!/usr/bin/env bash

set -eu
set -o pipefail

readonly NIX_ROOT="/nix"
readonly PROFILE_TARGET="/etc/zshrc"
readonly PROFILE_NIX_FILE="$NIX_ROOT/var/nix/profiles/default/etc/profile.d/nix-daemon.sh"

shell_source_lines() {
	cat <<EOF
# Nix
if [ -e '$PROFILE_NIX_FILE' ]; then
  . '$PROFILE_NIX_FILE'
fi
# End Nix
EOF
}

configure_shell_profile() {
	if [ -e "$PROFILE_TARGET" ]; then
		shell_source_lines |
			tee -a "$PROFILE_TARGET"
	fi
}

configure_shell_profile
