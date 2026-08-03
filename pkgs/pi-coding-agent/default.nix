{
  buildNpmPackage,
  fetchNpmDeps,
  fetchurl,
  lib,
  nodejs_24,
}:

let
  version = "0.83.0";
  src = fetchurl {
    url = "https://registry.npmjs.org/@earendil-works/pi-coding-agent/-/pi-coding-agent-${version}.tgz";
    hash = "sha512-uYhF+FsZxogoSX/AxBcUdiY+ZklubwaXyAoEGA2eQwsHcyEAhUYIKh/WLXe/a8+k8eTCmxb+ZN2Zo9mzQtzbWw==";
  };
  patchPackage = ''
    node -e '
      const fs = require("fs");
      const pkg = JSON.parse(fs.readFileSync("package.json", "utf8"));
      delete pkg.devDependencies;
      fs.writeFileSync("package.json", JSON.stringify(pkg, null, 2));
    '
    cp npm-shrinkwrap.json package-lock.json
    substituteInPlace package-lock.json \
      --replace-fail \
        '"resolved": "https://registry.npmjs.org/@earendil-works/pi-agent-core/-/pi-agent-core-0.83.0.tgz",' \
        '"resolved": "https://registry.npmjs.org/@earendil-works/pi-agent-core/-/pi-agent-core-0.83.0.tgz", "integrity": "sha512-RorGp9OH5l3ElpuC5a5ZQ2eWcchZGXflXRzVGkV99y3y6tT+LLNyxoYIdVKvTKWEObwhExeQbTH0fI2tE4iX4g==",' \
      --replace-fail \
        '"resolved": "https://registry.npmjs.org/@earendil-works/pi-ai/-/pi-ai-0.83.0.tgz",' \
        '"resolved": "https://registry.npmjs.org/@earendil-works/pi-ai/-/pi-ai-0.83.0.tgz", "integrity": "sha512-m3IZD4g3er0V8TC9+Vpgw/sjTKqcJlkcIBy/JvsgRubuuik3tAVzyugUg4rVrShIkkOT69mEd34NEqKUIsl6JQ==",' \
      --replace-fail \
        '"resolved": "https://registry.npmjs.org/@earendil-works/pi-tui/-/pi-tui-0.83.0.tgz",' \
        '"resolved": "https://registry.npmjs.org/@earendil-works/pi-tui/-/pi-tui-0.83.0.tgz", "integrity": "sha512-IoYrb0rORjELmEpNtoCA/U8je3KopMkRAVJRdSzvXRvgb+Huo1gNh8Q5CSZvNOiYtDxJdj2tYZZHZ4B3+IN3hA==",'
  '';
  npmDeps = fetchNpmDeps {
    name = "pi-coding-agent-${version}-npm-deps";
    inherit src;
    hash = "sha256-wTCScQKzP5OBc9v/Q+JRhuu1HvN+UO4LhjW6c7dIty0=";
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
