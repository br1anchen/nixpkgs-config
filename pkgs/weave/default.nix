{
  lib,
  stdenv,
  fetchurl,
  openssl,
  zlib,
  autoPatchelfHook,
  darwin ? null,
}:

let
  version = "0.3.6";

  sources = {
    aarch64-darwin = {
      target = "aarch64-apple-darwin";
      hashes = {
        "weave-cli" = "sha256-HKSXj9RQkCLPdOi9euTPFAKMbfGyEw4ch2E4BImW9Tc=";
        "weave-driver" = "sha256-fc/OJY16pWLAAoc4facLw+IshqzC5SFDF+xre6uS2FY=";
        "weave-mcp" = "sha256-QnYqggwFuFUVJODtA6jmlnsRsu00roOezu/1F8DcnVs=";
      };
    };
    x86_64-darwin = {
      target = "x86_64-apple-darwin";
      hashes = {
        "weave-cli" = "sha256-3ZniXl5f0HLj7JdtwWRWZCz02zFiuzZeTbXLUBuVCgo=";
        "weave-driver" = "sha256-Y0lFdP8XZKCM2gCM0KMihL35OpBKoBcb8umGD1Xx58I=";
        "weave-mcp" = "sha256-PZNtKnlQQwvqlNlCKWCamVeL9yK0v5/4tyijnZle2D0=";
      };
    };
    aarch64-linux = {
      target = "aarch64-unknown-linux-gnu";
      hashes = {
        "weave-cli" = "sha256-bNBdoaXiNx6i9m8Ud4kf+17oGNTNh4jJ/eRVRx68I0U=";
        "weave-driver" = "sha256-IaPL2LeLBZWo0UG3yADUxfA0pilReoni7vyCNSUju5I=";
        "weave-mcp" = "sha256-SnQzwP77NkOP2EL7DZrIZaqdLK24pVty3tj/IOBCPf8=";
      };
    };
    x86_64-linux = {
      target = "x86_64-unknown-linux-gnu";
      hashes = {
        "weave-cli" = "sha256-Ny194xZtPOJ+UTGMEvVzQzoMhjCThywv8qz0L4okf4I=";
        "weave-driver" = "sha256-tjbDjUOic3bd85xOSNqkJ74fhVvMva/ERJY+dUAgZ3M=";
        "weave-mcp" = "sha256-UBPG0w2DpuEJnTKSjx52KjQSjnZS1K3VJf4mwesL934=";
      };
    };
  };

  source =
    sources.${stdenv.hostPlatform.system}
      or (throw "weave: unsupported system ${stdenv.hostPlatform.system}");

  archives = [
    "weave-cli"
    "weave-driver"
    "weave-mcp"
  ];

  fetchArchive =
    name:
    fetchurl {
      url = "https://github.com/Ataraxy-Labs/weave/releases/download/v${version}/${name}-${source.target}.tar.gz";
      hash = source.hashes.${name};
    };
in
stdenv.mkDerivation {
  pname = "weave";
  inherit version;

  srcs = map fetchArchive archives;

  nativeBuildInputs =
    lib.optionals stdenv.hostPlatform.isLinux [ autoPatchelfHook ]
    ++ lib.optionals stdenv.hostPlatform.isDarwin [ darwin.sigtool ];

  buildInputs = [
    openssl
  ]
  ++ lib.optionals stdenv.hostPlatform.isLinux [
    stdenv.cc.cc.lib
    zlib
  ];

  unpackPhase = ''
    runHook preUnpack

    for src in $srcs; do
      tar -xzf "$src"
    done

    runHook postUnpack
  '';

  installPhase = ''
    runHook preInstall

    install -Dm755 weave $out/bin/weave
    install -Dm755 weave-driver $out/bin/weave-driver
    install -Dm755 weave-mcp $out/bin/weave-mcp

    runHook postInstall
  '';

  postFixup = lib.optionalString stdenv.hostPlatform.isDarwin ''
    for binary in weave weave-driver weave-mcp; do
      install_name_tool \
        -change /opt/homebrew/opt/openssl@3/lib/libssl.3.dylib ${lib.getLib openssl}/lib/libssl.3.dylib \
        -change /opt/homebrew/opt/openssl@3/lib/libcrypto.3.dylib ${lib.getLib openssl}/lib/libcrypto.3.dylib \
        "$out/bin/$binary"

      codesign --force --sign - "$out/bin/$binary"
    done
  '';

  meta = {
    description = "Entity-level semantic merge driver for Git";
    homepage = "https://github.com/Ataraxy-Labs/weave";
    changelog = "https://github.com/Ataraxy-Labs/weave/releases/tag/v${version}";
    license = with lib.licenses; [
      asl20
      mit
    ];
    mainProgram = "weave";
    maintainers = [ ];
    platforms = builtins.attrNames sources;
    sourceProvenance = with lib.sourceTypes; [ binaryNativeCode ];
  };
}
