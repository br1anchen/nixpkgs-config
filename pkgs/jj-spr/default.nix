{
  lib,
  rustPlatform,
  fetchFromGitHub,
  pkg-config,
  openssl,
  zlib,
  makeWrapper,
  git,
  jujutsu,
}:

rustPlatform.buildRustPackage rec {
  pname = "jj-spr";
  version = "0.1.0-unstable-2026-07-28";

  src = fetchFromGitHub {
    owner = "jennings";
    repo = "jj-spr";
    rev = "998ee83de8d7dee301a0109cc3feed421c86cae0";
    hash = "sha256-djt781zEGhvhsI9CnFxCkopICFHg/hLpo2RK2HO0mfY=";
  };

  cargoHash = "sha256-4fRM2fMlEFM9d/W4QyBrBebtsQpPuq4hELKQBU74FLE=";

  nativeBuildInputs = [
    pkg-config
    makeWrapper
  ];

  buildInputs = [
    openssl
    zlib
  ];

  # Tests drive real git/jj repositories.
  nativeCheckInputs = [
    git
    jujutsu
  ];

  # `jj config set` writes under $HOME, which is read-only in the sandbox.
  preCheck = ''
    export HOME=$(mktemp -d)
  '';

  postInstall = ''
    wrapProgram $out/bin/jj-spr --prefix PATH : ${
      lib.makeBinPath [
        git
        jujutsu
      ]
    }
  '';

  meta = {
    description = "Jujutsu subcommand for submitting amendable, rebaseable pull requests to GitHub";
    homepage = "https://github.com/jennings/jj-spr";
    changelog = "https://github.com/jennings/jj-spr/blob/${src.rev}/CHANGELOG.md";
    license = lib.licenses.mit;
    mainProgram = "jj-spr";
    maintainers = [ ];
    platforms = lib.platforms.unix;
  };
}
