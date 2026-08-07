{
  buildNpmPackage,
  fetchurl,
  lib,
  nodejs_24,
  pkg-config,
  python3,
  zeromq,
}:

buildNpmPackage rec {
  pname = "prime-agent";
  version = "0.7.1";

  src = fetchurl {
    url = "https://github.com/PrimeIntellect-ai/prime-agent/releases/download/v${version}/prime-agent-${version}.tgz";
    hash = "sha256-1oYSyDI5yq+rcsx2xVrFcr/QegWeqPvSo92+HytV3Ns=";
  };

  sourceRoot = "package";
  postPatch = ''
    cp ${./package-lock.json} package-lock.json
  '';
  npmDepsHash = "sha256-fcKq3jQ7MDLuuRcT0zHoZpxU0bGo4f8xX16vFX0iNZQ=";
  nodejs = nodejs_24;

  makeCacheWritable = true;

  nativeBuildInputs = [
    pkg-config
    python3
  ];
  buildInputs = [ zeromq ];

  dontNpmBuild = true;

  meta = {
    description = "Self-improving RLM agent for coding workflows and long-running autonomous tasks";
    homepage = "https://github.com/PrimeIntellect-ai/prime-agent";
    license = lib.licenses.mit;
    mainProgram = "prime-agent";
  };
}
