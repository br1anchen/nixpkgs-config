{
  lib,
  stdenv,
  fetchurl,
}:

let
  version = "3000.10.21";

  # Hashes come from https://static.devin.ai/cli/current/manifest.json
  # (or cli/<version>/manifest.json for a pinned release); update.sh refreshes
  # them together with `version`.
  sources = {
    aarch64-darwin = {
      target = "aarch64-apple-darwin";
      hash = "sha256-wLl/gZe/POiV/xSqGSV8URFUtJoKGVu6SWKsteR1xo4=";
    };
    x86_64-darwin = {
      target = "x86_64-apple-darwin";
      hash = "sha256-RyXWsNu/b3HYM7VIlGnci1xKT5KZJvlNUAlSpMt7utg=";
    };
    aarch64-linux = {
      target = "aarch64-unknown-linux";
      hash = "sha256-pjEk7S+EBqXUShYvousFucDyGKaxMeLKEzXUozXHCmw=";
    };
    x86_64-linux = {
      target = "x86_64-unknown-linux";
      hash = "sha256-fKxvVzm6Oj5VQvO3+gftkC1t+5bKIuTGOuhMA7t9tHw=";
    };
  };

  source =
    sources.${stdenv.hostPlatform.system}
      or (throw "devin-cli: unsupported system ${stdenv.hostPlatform.system}");
in
stdenv.mkDerivation {
  pname = "devin-cli";
  inherit version;

  src = fetchurl {
    url = "https://static.devin.ai/cli/${version}/devin-${version}-${source.target}.tar.gz";
    inherit (source) hash;
  };

  # The bundle unpacks to bare bin/ + share/ with no top-level directory.
  sourceRoot = ".";

  # Linux builds are static-pie and we never patch the shipped binaries, so no
  # autoPatchelfHook or re-signing is needed on either platform.
  installPhase = ''
    runHook preInstall

    install -Dm755 bin/devin $out/bin/devin
    cp -r share $out/share

    # Distribution marker the updater reads to pick its manifest URL. "nix" is
    # not a recognized channel, so `devin update`/auto-update report "not
    # available for this installation" and version bumps stay owned here.
    echo nix > $out/distribution

    runHook postInstall
  '';

  meta = {
    description = "Local command-line coding agent with Devin Cloud integration";
    homepage = "https://docs.devin.ai/cli";
    changelog = "https://docs.devin.ai/cli/changelog/stable";
    license = lib.licenses.unfree;
    mainProgram = "devin";
    maintainers = [ ];
    platforms = builtins.attrNames sources;
    sourceProvenance = with lib.sourceTypes; [ binaryNativeCode ];
  };
}
