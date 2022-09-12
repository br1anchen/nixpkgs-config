#!/usr/bin/env bash

set -eu
set -o pipefail

readonly MAC_LAUNCHDAEMONS="/Library/LaunchDaemons/"
readonly PATCH_FILE_NAME="limit.maxfiles.plist"
readonly PATCH_FILE_DST="$MAC_LAUNCHDAEMONS$PATCH_FILE_NAME"

patch() {
	if [ -e "$(pwd)/$PATCH_FILE_NAME" ]; then
		ln -s "$(pwd)/$PATCH_FILE_NAME" "$PATCH_FILE_DST"
		chown root:wheel "$PATCH_FILE_DST"
		launchctl load -w "$PATCH_FILE_DST"
	fi
}

patch
