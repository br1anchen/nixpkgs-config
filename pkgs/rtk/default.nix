{
  lib,
  stdenv,
  fetchurl,
  autoPatchelfHook,
}:

let
  sources = {
    aarch64-darwin = {
      target = "aarch64-apple-darwin";
      hash = "sha256-1Hgjr7JZGeTmCDjFYi6I/6ZTa8CzajSj+Si9zKxA9hQ=";
    };
    x86_64-darwin = {
      target = "x86_64-apple-darwin";
      hash = "sha256-fHLQXPxxt+LyB1WzdUtyis7MfAsfu7CHV4KPnnvt2Bo=";
    };
    x86_64-linux = {
      target = "x86_64-unknown-linux-musl";
      hash = "sha256-XfdkpjNwnLhdJIJY0IXSTslfqovKDmg1qTzVfK3E654=";
    };
    aarch64-linux = {
      target = "aarch64-unknown-linux-gnu";
      hash = "sha256-K3+gnQb42/M0xVSC+tLnzkofhWS8ntH2XZ9ZktuOVSc=";
    };
  };

  source =
    sources.${stdenv.hostPlatform.system}
      or (throw "rtk: unsupported system ${stdenv.hostPlatform.system}");
in
stdenv.mkDerivation rec {
  pname = "rtk";
  version = "0.42.3";

  src = fetchurl {
    url = "https://github.com/rtk-ai/rtk/releases/download/v${version}/rtk-${source.target}.tar.gz";
    inherit (source) hash;
  };

  sourceRoot = ".";

  nativeBuildInputs = lib.optionals stdenv.hostPlatform.isLinux [ autoPatchelfHook ];

  buildInputs = lib.optionals stdenv.hostPlatform.isLinux [ stdenv.cc.cc.lib ];

  installPhase = ''
    runHook preInstall

    install -Dm755 rtk $out/bin/rtk

    runHook postInstall
  '';

  meta = {
    description = "CLI proxy that reduces LLM token consumption on common dev commands";
    homepage = "https://github.com/rtk-ai/rtk";
    license = lib.licenses.asl20;
    mainProgram = "rtk";
    maintainers = [ ];
    platforms = builtins.attrNames sources;
    sourceProvenance = with lib.sourceTypes; [ binaryNativeCode ];
  };
}
