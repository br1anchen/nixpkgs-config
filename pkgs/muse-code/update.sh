#!/usr/bin/env bash
# Pins pkgs/muse-code to the current release of Muse Code's stable channel:
# reads the channel, then the release manifest's per-platform sha256, and
# rewrites the version and hashes in default.nix. Pass a version to pin that
# one instead.
set -euo pipefail
cd "$(dirname "$0")"
version="${1:-$(curl -fsS https://api.meta.ai/muse-code/channels/muse-stable | jq -r .version)}"
manifest="$(curl -fsS "https://lookaside.facebook.com/lookaside/muse/download/?channel=muse&version=$version&file=manifest.json")"
[ "$(jq -r .version <<<"$manifest")" = "$version" ] || { echo "manifest is not for $version" >&2; exit 1; }
sri() { nix hash convert --hash-algo sha256 --to sri "$(jq -r ".artifacts.$1.checksum" <<<"$manifest")"; }
sed -i -E "s/^  version = \".*\";/  version = \"$version\";/" default.nix
for pair in x86_linux:muse-x86-linux aarch64_linux:muse-aarch64-linux x86_macos:muse-x86-macos aarch64_macos:muse-aarch64-macos; do
	key="${pair%%:*}" file="${pair#*:}"
	FILE="$file" HASH="$(sri "$key")" perl -0pi -e 's/(file = "\Q$ENV{FILE}\E";\n\s*hash = ")[^"]*/$1$ENV{HASH}/' default.nix
done
echo "muse-code pinned to $version"
