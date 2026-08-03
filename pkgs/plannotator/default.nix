{
  fetchurl,
  lib,
  stdenvNoCC,
}:

let
  version = "0.25.1";
  platform = stdenvNoCC.hostPlatform.system;
  releases = {
    aarch64-darwin = {
      asset = "plannotator-darwin-arm64";
      hash = "sha256-MtKPrN80xRGYLTjyK121O3FSdTbS0PwI/sHPjxinYlc=";
    };
    x86_64-darwin = {
      asset = "plannotator-darwin-x64";
      hash = "sha256-zkXdLniWHDUSX719ml4hEoy8DBdL9G+PfTzdB71ffb4=";
    };
    aarch64-linux = {
      asset = "plannotator-linux-arm64";
      hash = "sha256-nv2iCVq+nqFlviVHjEnfTwhg16aqDWa6MZtP1Gd5iFQ=";
    };
    x86_64-linux = {
      asset = "plannotator-linux-x64";
      hash = "sha256-UWJWL7uX91SpyDwNdJ/GLSC6zeUJzV0v7MAEkL2d/m8=";
    };
  };
  release = releases.${platform};
in
stdenvNoCC.mkDerivation {
  pname = "plannotator";
  inherit version;

  src = fetchurl {
    url = "https://github.com/backnotprop/plannotator/releases/download/v${version}/${release.asset}";
    inherit (release) hash;
  };

  dontUnpack = true;

  installPhase = ''
    runHook preInstall
    install -Dm755 "$src" "$out/bin/plannotator"
    runHook postInstall
  '';

  meta = {
    description = "Visual plan and code review tool for coding agents";
    homepage = "https://plannotator.ai";
    license = with lib.licenses; [
      asl20
      mit
    ];
    mainProgram = "plannotator";
    platforms = builtins.attrNames releases;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
  };
}
