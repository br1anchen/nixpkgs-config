#!/usr/bin/env bash
# Update Pi and its bundled Plannotator extension dependency from npm.
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
pi_nix="$repo_root/pkgs/pi-coding-agent/default.nix"
plannotator_dir="$repo_root/pkgs/plannotator-pi-extension"
plannotator_nix="$plannotator_dir/default.nix"
package='@earendil-works/pi-coding-agent'
version=${1:-$(npm view "$package" version)}

if [[ $# -gt 1 ]]; then
  echo "Usage: $0 [version]" >&2
  exit 2
fi

published_version=$(npm view "$package@$version" version)
src_hash=$(npm view "$package@$version" dist.integrity)
if [[ $published_version != "$version" || -z $src_hash ]]; then
  echo "Unable to find $package@$version" >&2
  exit 1
fi

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT
curl --fail --location --silent --show-error \
  "https://registry.npmjs.org/@earendil-works/pi-coding-agent/-/pi-coding-agent-$version.tgz" \
  --output "$tmpdir/pi.tgz"
tar -xzf "$tmpdir/pi.tgz" -C "$tmpdir"

# Pi's shrinkwrap omits integrity fields for its workspace packages. Look up every
# omitted package rather than maintaining this list by hand.
integrities=$(node - "$tmpdir/package/npm-shrinkwrap.json" <<'NODE'
const { execFileSync } = require("child_process");
const fs = require("fs");
const lock = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
const result = {};
for (const [path, dependency] of Object.entries(lock.packages)) {
  if (!dependency.resolved || dependency.integrity) continue;
  const name = path.slice(path.lastIndexOf("node_modules/") + "node_modules/".length);
  result[name] = execFileSync("npm", ["view", `${name}@${dependency.version}`, "dist.integrity"], {
    encoding: "utf8",
  }).trim();
}
console.log(JSON.stringify(result));
NODE
)

node - "$pi_nix" "$plannotator_dir/package.json" "$version" "$src_hash" "$integrities" <<'NODE'
const fs = require("fs");
const [nixFile, extensionPackage, version, srcHash, integrityJson] = process.argv.slice(2);
const integrities = JSON.parse(integrityJson);
const integrityLines = Object.entries(integrities)
  .sort(([a], [b]) => a.localeCompare(b))
  .map(([name, hash]) => `    "${name}" = "${hash}";`)
  .join("\n");
let nix = fs.readFileSync(nixFile, "utf8");
nix = nix.replace(/version = "[^"]+";/, `version = "${version}";`);
nix = nix.replace(/srcHash = "[^"]+";/, `srcHash = "${srcHash}";`);
nix = nix.replace(/missingIntegrity = \{\n.*?\n  \};/s, `missingIntegrity = {\n${integrityLines}\n  };`);
fs.writeFileSync(nixFile, nix);

const extension = JSON.parse(fs.readFileSync(extensionPackage, "utf8"));
extension.dependencies["@earendil-works/pi-coding-agent"] = version;
fs.writeFileSync(extensionPackage, `${JSON.stringify(extension, null, 2)}\n`);
NODE

(
  cd "$plannotator_dir"
  npm install --package-lock-only --ignore-scripts
)

# npm carries Pi's incomplete shrinkwrap into this lock file, so fill the same
# workspace-package integrity fields before Nix creates its offline cache.
node - "$plannotator_dir/package-lock.json" "$integrities" <<'NODE'
const fs = require("fs");
const [lockFile, integrityJson] = process.argv.slice(2);
const integrities = JSON.parse(integrityJson);
const lock = JSON.parse(fs.readFileSync(lockFile, "utf8"));
for (const [path, dependency] of Object.entries(lock.packages)) {
  if (!dependency.resolved || dependency.integrity) continue;
  const name = path.slice(path.lastIndexOf("node_modules/") + "node_modules/".length);
  if (!integrities[name]) throw new Error(`Missing integrity for ${name}`);
  dependency.integrity = integrities[name];
}
fs.writeFileSync(lockFile, `${JSON.stringify(lock, null, 2)}\n`);
NODE

set_hash() {
  node - "$1" "$2" "$3" <<'NODE'
const fs = require("fs");
const [file, key, hash] = process.argv.slice(2);
const contents = fs.readFileSync(file, "utf8");
const updated = contents.replace(
  new RegExp(`(${key} = \")[^\"]+(\";)`),
  `$1${hash}$2`,
);
if (updated === contents && !contents.includes(`${key} = "${hash}";`)) {
  throw new Error(`Could not update ${key} in ${file}`);
}
fs.writeFileSync(file, updated);
NODE
}

update_hash() {
  local attribute=$1 file=$2 key=$3 output hash
  # Force a fresh fixed-output derivation; otherwise Nix can report only that
  # its cached dependency lock differs from the newly updated source lock.
  set_hash "$file" "$key" "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
  if output=$(cd "$repo_root" && nix build ".#$attribute" --no-link 2>&1); then
    echo "Expected a hash mismatch while updating $attribute" >&2
    exit 1
  fi
  printf '%s\n' "$output" >&2
  hash=$(printf '%s\n' "$output" | sed -n 's/^[[:space:]]*got:[[:space:]]*\(sha256-[^[:space:]]*\).*/\1/p' | tail -n1)
  if [[ -z $hash ]]; then
    echo "Could not determine updated hash for $attribute" >&2
    exit 1
  fi
  set_hash "$file" "$key" "$hash"
  (cd "$repo_root" && nix build ".#$attribute" --no-link)
}

update_hash pi-coding-agent "$pi_nix" hash
update_hash plannotator-pi-extension "$plannotator_nix" npmDepsHash

echo "Updated Pi to $version"
