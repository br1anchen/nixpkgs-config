{
  lib,
  buildNpmPackage,
  fetchFromGitHub,
  runCommand,
  makeWrapper,
  nodejs,
}:

let
  rev = "0c8de1e60686711defaf09f3dcd42b96d118fe68";

  safeChainSrc = fetchFromGitHub {
    owner = "AikidoSec";
    repo = "safe-chain";
    inherit rev;
    hash = "sha256-4u94eA8o5XxBnhxjxxcyEJlLpiIrUaISxkOzCzyxD0Q=";
  };
in
buildNpmPackage {
  pname = "safe-chain";
  version = builtins.substring 0 7 rev;

  # buildNpmPackage's fetchNpmDeps expects package-lock.json; this repo ships
  # an npm-shrinkwrap.json (same format), so expose a copy under the expected
  # name. Content is identical, so npmDepsHash is unchanged.
  src = runCommand "safe-chain-src" { } ''
    cp -r ${safeChainSrc} $out
    chmod -R +w $out
    cp $out/npm-shrinkwrap.json $out/package-lock.json
  '';

  npmDepsHash = "sha256-OIPdWib4FaIFVEq3+wPeTbwzzRyRBtycwjLXAbBDuoM=";

  # Skip the pkg-based single-binary target; use the JS bins directly.
  dontNpmBuild = true;
  dontNpmInstall = true;

  # Skip lifecycle scripts: the bundler devDep (@yao-pkg/pkg -> node-pty)
  # fails to compile native bindings and is not needed for the JS bins.
  npmFlags = [ "--ignore-scripts" ];

  nativeBuildInputs = [ makeWrapper ];

  # Drop in the whole monorepo (workspace symlinks need both packages/ and
  # node_modules/), then expose aikido-* + safe-chain as $out/bin wrappers
  # that exec node against the JS entrypoint.
  installPhase = ''
    runHook preInstall

    mkdir -p $out/lib/safe-chain
    cp -r . $out/lib/safe-chain/

    for name in aikido-npm aikido-npx aikido-yarn \
                aikido-pnpm aikido-pnpx \
                aikido-rush aikido-rushx \
                aikido-bun aikido-bunx \
                aikido-uv aikido-uvx \
                aikido-pip aikido-pip3 \
                aikido-python aikido-python3 \
                aikido-poetry aikido-pipx \
                safe-chain; do
      makeWrapper ${nodejs}/bin/node $out/bin/$name \
        --add-flags "$out/lib/safe-chain/packages/safe-chain/bin/$name.js"
    done

    runHook postInstall
  '';

  meta = {
    description = "Malware-blocking wrapper for npm, pnpm, bun, pip, uv, poetry";
    homepage = "https://github.com/AikidoSec/safe-chain";
    license = lib.licenses.agpl3Plus;
    platforms = lib.platforms.unix;
  };
}
