{
  buildNpmPackage,
  lib,
  nodejs_24,
}:

buildNpmPackage {
  pname = "plannotator-pi-extension";
  version = "0.25.1";

  src = ./.;
  npmDepsHash = "sha256-OTgv2Nh64llxcUx0rJnVKfsixj5Vh2sRbjOTH1EO85g=";
  makeCacheWritable = true;
  npmRebuildFlags = [ "--ignore-scripts" ];
  dontNpmBuild = true;
  dontNpmInstall = true;
  nodejs = nodejs_24;

  installPhase = ''
    runHook preInstall
    mkdir -p "$out/lib"
    cp -R node_modules "$out/lib/node_modules"

    # Default review engine in plannotator's review UI currently starts at Claude.
    # Keep this in sync with plannotator runtime defaults by forcing codex here.
    local extension_dir="$out/lib/node_modules/@plannotator/pi-extension"
    local review_ui="$extension_dir/review-editor.html"
    if [ -f "$review_ui" ]; then
      substituteInPlace "$review_ui" --replace \
        'reviewEngine:"claude",reviewProfileByEngine' \
        'reviewEngine:"codex",reviewProfileByEngine'
    fi

    runHook postInstall
  '';

  meta = {
    description = "Plannotator plan and code review extension for Pi";
    homepage = "https://plannotator.ai";
    license = with lib.licenses; [
      asl20
      mit
    ];
  };
}
