{
  buildNpmPackage,
  fetchNpmDeps,
  fetchurl,
  lib,
  nodejs_24,
}:

let
  version = "0.85.1";
  srcHash = "sha512-FGRN+OHbWaefBPGaTggAdLjrIHW+s2PzLyglz/5dfLzb9of7uuXMXYC0fJIeZTw+shS32o2cuQ9jF7YSDuL/oQ==";
  # npm's shrinkwrap omits integrity fields for these workspace packages.
  missingIntegrity = {
    "@earendil-works/chord" = "sha512-VDlkEC3dhCzQ5fcyH1OhG19dq+6jCn+rqc/iXFivwDYGR5anwo2RCiXij9PpHhqNR5GuhhE+Er69Zi1Sn4eY6w==";
    "@earendil-works/pi-agent-core" = "sha512-hIXIP3eAWueAYiAl8aMvWCvvZ8Q5gT3Dip5bE5uJyIGh4+YlWRjtMLI4BaeoXoSs93zndjue61u1B/vhefLnuA==";
    "@earendil-works/pi-ai" = "sha512-+VgVIJDkDO2efYJKEEqvPTH4zmnIaXdAppGbO+vKFA9qy5PdhFiAenuFAkU+oiCSfOC4dMHDyrjdQeL4ZoC5CQ==";
    "@earendil-works/pi-telemetry" = "sha512-Bg/YN6kA7Swja/NQxka8xFdecb4E/auIEGF2G5A25EaQXhRnPj300/7/KpgsDDMYUzHTDAv4RyUxaQPJKW81Rw==";
    "@earendil-works/pi-tui" = "sha512-OIzw9efInmO4WOBnD4TxcTdBjmzvYJpzslkgoUro946nEGoYWg5rwv1p4fDt3/JvMx9QybryUCUwlm7j8Dreig==";
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
      fs.writeFileSync("npm-shrinkwrap.json", lockText);
    '
  '';
  npmDeps = fetchNpmDeps {
    name = "pi-coding-agent-${version}-npm-deps";
    inherit src;
    hash = "sha256-HF3Anl4xnnb6tVQM7u90N7TzWAtiBZ4sU1jxMHWwYr4=";
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
