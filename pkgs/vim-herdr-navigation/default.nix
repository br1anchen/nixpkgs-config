{
  lib,
  src,
  stdenvNoCC,
}:

stdenvNoCC.mkDerivation {
  pname = "vim-herdr-navigation";
  version = "0-unstable-2026-08-02";
  inherit src;

  installPhase = ''
    runHook preInstall
    mkdir -p "$out/share/vim-herdr-navigation"
    cp -R . "$out/share/vim-herdr-navigation"
    runHook postInstall
  '';

  meta = {
    description = "Seamless navigation across Herdr panes and Vim splits";
    homepage = "https://github.com/paulbkim-dev/vim-herdr-navigation";
    license = lib.licenses.mit;
    platforms = lib.platforms.unix;
  };
}
