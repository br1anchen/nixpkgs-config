{
  buildNpmPackage,
  fetchNpmDeps,
  fetchurl,
  lib,
  nodejs_24,
}:

let
  version = "0.84.1";
  srcHash = "sha512-ncAqFrG+iybuPGOhMiZoEHkEzTpJgz3guYD32pD+M7ucc0WeHmauP6wa7qwP8V/KWvsZDVNa5XGsdZ7fkC7w7A==";
  # npm's shrinkwrap omits integrity fields for these workspace packages.
  missingIntegrity = {
    "@earendil-works/pi-agent-core" =
      "sha512-evyzXYWCLQGmcaBYHlmSku02r8qoN4SGI60GZABo6iV+H+nqX+P9ud8fEZ4GmRq9mUSREvvfX+w9dA9ThF9C6w==";
    "@earendil-works/pi-ai" =
      "sha512-wMsAdJMxuNri08vLqTyYVI201DQQezGhPSTkzYsHdw5dYX3rCNwEmSvpaAwhi7ELKI/2tE/CEgSWg/6iRxSgdQ==";
    "@earendil-works/pi-client" =
      "sha512-/V5hGHE4Zq+jG0GtwIB9PyBUOGd6gBLZ7lkQYFKchKnxYHeH3rmWC5xw4kpnZKKBuBuFTdLVbU9vEjlAGMMb2A==";
    "@earendil-works/pi-protocol" =
      "sha512-Ox1pciyeSPGEEUcxvR0/dJcrY7C6hrEGA8y71rOsvSIUlXN1Cbp/be/eoL71OGDBk5O97TeQPfWN6Ju/2Ehjww==";
    "@earendil-works/pi-telemetry" =
      "sha512-180/xGJtsq7IoR3p9EKWjRd0e9M4DkxInhlo9xyD7prDC7Qrhqq+nhvwrW0lFjPfXcEI2FSHmGCSyvSJE9GsaQ==";
    "@earendil-works/pi-tui" =
      "sha512-udeXFbgEhJ6JiB0uguwNVNkDy2FENfmtQwPcY+/iJ8GWeq18wkal1tKqa5YyeH0IqtX1vG0cGh8zfSYzyzVuLA==";
  };
  src = fetchurl {
    url = "https://registry.npmjs.org/@earendil-works/pi-coding-agent/-/pi-coding-agent-${version}.tgz";
    hash = srcHash;
  };
  patchPackage = ''
    node -e '
      const fs = require("fs");
      const pkg = JSON.parse(fs.readFileSync("package.json", "utf8"));
      delete pkg.devDependencies;
      fs.writeFileSync("package.json", JSON.stringify(pkg, null, 2));

      const integrities = ${builtins.toJSON missingIntegrity};
      let lockText = fs.readFileSync("npm-shrinkwrap.json", "utf8");
      const lock = JSON.parse(lockText);
      for (const [path, dependency] of Object.entries(lock.packages)) {
        if (!dependency.resolved || dependency.integrity) continue;
        const name = path.slice(path.lastIndexOf("node_modules/") + "node_modules/".length);
        if (!integrities[name]) throw new Error("Missing integrity for " + name);
        const resolved = "\"resolved\": \"" + dependency.resolved + "\",";
        lockText = lockText.replace(resolved, resolved + " \"integrity\": \"" + integrities[name] + "\",");
      }
      fs.writeFileSync("package-lock.json", lockText);
    '
  '';
  npmDeps = fetchNpmDeps {
    name = "pi-coding-agent-${version}-npm-deps";
    inherit src;
    hash = "sha256-Iz4+IUuKP+wsMiO316ws6RxEo2magnQUXX8MvDOpkAM=";
    nativeBuildInputs = [ nodejs_24 ];
    postPatch = patchPackage;
  };
in
buildNpmPackage {
  pname = "pi-coding-agent";
  inherit
    npmDeps
    src
    version
    ;

  postPatch = patchPackage;
  makeCacheWritable = true;
  npmInstallFlags = [ "--omit=dev" ];
  npmRebuildFlags = [ "--ignore-scripts" ];
  npmPruneFlags = [ "--ignore-scripts" ];
  dontNpmBuild = true;
  nodejs = nodejs_24;

  meta = {
    description = "Minimal terminal coding harness";
    homepage = "https://github.com/earendil-works/pi";
    license = lib.licenses.mit;
    mainProgram = "pi";
  };
}
