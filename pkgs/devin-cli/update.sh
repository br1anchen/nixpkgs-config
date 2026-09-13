#!/usr/bin/env bash
# Update devin-cli from the release manifest at static.devin.ai.
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
devin_nix="$repo_root/pkgs/devin-cli/default.nix"

if [[ $# -gt 1 ]]; then
  echo "Usage: $0 [version]" >&2
  exit 2
fi

version=${1:-}
manifest_url="https://static.devin.ai/cli/${version:-current}/manifest.json"
manifest=$(curl --fail --location --silent --show-error "$manifest_url")

# The manifest publishes a hex sha256 per target; convert each to SRI and
# rewrite the matching `target`/`hash` block plus the version in one pass.
node - "$devin_nix" "$version" "$manifest" <<'NODE'
const { execFileSync } = require("child_process");
const fs = require("fs");
const [nixFile, pinnedVersion, manifestJson] = process.argv.slice(2);
const manifest = JSON.parse(manifestJson);
const version = pinnedVersion || manifest.version;

const targets = {
  "aarch64-darwin": "aarch64-apple-darwin",
  "x86_64-darwin": "x86_64-apple-darwin",
  "aarch64-linux": "aarch64-unknown-linux",
  "x86_64-linux": "x86_64-unknown-linux",
};

let nix = fs.readFileSync(nixFile, "utf8");
nix = nix.replace(/version = "[^"]+";/, `version = "${version}";`);

for (const [system, target] of Object.entries(targets)) {
  const info = manifest.platforms[target];
  if (!info) throw new Error(`No bundle for ${target} in manifest`);
  const sri = execFileSync(
    "nix",
    ["hash", "convert", "--hash-algo", "sha256", "--to", "sri", info.sha256],
    { encoding: "utf8" },
  ).trim();
  const re = new RegExp(
    `(${system} = \\{\\n\\s*target = "${target}";\\n\\s*hash = ")[^"]+(";)`,
  );
  const updated = nix.replace(re, `$1${sri}$2`);
  if (updated === nix) throw new Error(`Could not update hash for ${system}`);
  nix = updated;
}

fs.writeFileSync(nixFile, nix);
console.log(`Updated devin-cli to ${version}`);
NODE

(cd "$repo_root" && nix build ".#devin-cli" --no-link)
