{
  lib,
  stdenvNoCC,
  fetchurl,
}:

# Muse Code, Meta's terminal coding agent, pinned to one release of its
# stable channel. Meta's own installer is a launcher script that resolves the
# channel on every run and replaces itself; this installs the release binary
# directly (a static executable) at the version below. Bump with ./update.sh.
let
  version = "1.4.6-R6000.1";
  sources = {
    x86_64-linux = {
      file = "muse-x86-linux";
      hash = "sha256-gqSVVCllpbYlb3rNuBaTRRwoZApBnVUorYNA6pPzb28=";
    };
    aarch64-linux = {
      file = "muse-aarch64-linux";
      hash = "sha256-/bt/GoXV+gcnJTcmeFqUDoa9u184hbsO0YJld4H1qpM=";
    };
    x86_64-darwin = {
      file = "muse-x86-macos";
      hash = "sha256-Kk7N4DxDvYHAHX29l4yJTblAxfbiNePj2lAzdr0PtF8=";
    };
    aarch64-darwin = {
      file = "muse-aarch64-macos";
      hash = "sha256-xxMWWih9ZK+4gW+DUaJAtFeiNST0reBryg5B395BBGA=";
    };
  };
  source =
    sources.${stdenvNoCC.hostPlatform.system}
      or (throw "muse-code: unsupported system ${stdenvNoCC.hostPlatform.system}");
in
stdenvNoCC.mkDerivation {
  pname = "muse-code";
  inherit version;

  src = fetchurl {
    name = "${source.file}-${version}";
    url = "https://lookaside.facebook.com/lookaside/muse/download/?channel=muse&version=${version}&file=${source.file}";
    inherit (source) hash;
  };

  dontUnpack = true;
  dontStrip = true;

  installPhase = ''
    runHook preInstall
    install -Dm755 $src $out/bin/muse
    runHook postInstall
  '';

  doInstallCheck = true;
  installCheckPhase = ''
    $out/bin/muse --version | grep -F ${version}
  '';

  meta = {
    description = "Muse Code, Meta's terminal coding agent";
    homepage = "https://about.fb.com/news/2026/10/introducing-muse-wonder-models/";
    license = lib.licenses.unfree;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    mainProgram = "muse";
    platforms = builtins.attrNames sources;
  };
}
