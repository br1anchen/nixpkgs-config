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

bootstrap_launchd_services() {
	local plist label
	for label in org.nixos.darwin-store org.nixos.nix-daemon; do
		plist="/Library/LaunchDaemons/$label.plist"
		if [ -e "$plist" ] && ! launchctl print "system/$label" >/dev/null 2>&1; then
			echo "Bootstrapping $label..."
			launchctl bootstrap system "$plist"
		fi
	done
}

configure_shell_profile
bootstrap_launchd_services

echo
echo "Done. Apply to current shell with:"
echo "  . '$PROFILE_NIX_FILE'"
echo "or start a fresh shell: exec \$SHELL -l"
