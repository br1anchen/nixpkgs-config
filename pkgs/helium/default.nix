{
  lib,
  stdenv,
  fetchurl,
  autoPatchelfHook,
  makeWrapper,
  addDriverRunpath,
  alsa-lib,
  at-spi2-atk,
  at-spi2-core,
  atk,
  cairo,
  cups,
  dbus,
  expat,
  glib,
  libdrm,
  libgbm,
  libglvnd,
  libva,
  libx11,
  libxcb,
  libxcomposite,
  libxdamage,
  libxext,
  libxfixes,
  libxkbcommon,
  libxrandr,
  mesa,
  nspr,
  nss,
  pango,
  pciutils,
  pipewire,
  systemd,
  vulkan-loader,
  xdg-utils,
}:

let
  # Upstream builds Chromium once per arch and ships the result in
  # imputnet/helium-linux; the browser source lives in imputnet/helium.
  # Building Chromium from source here is not practical, so we consume the
  # release tarball and patch it into the Nix store.
  sources = {
    x86_64-linux = {
      arch = "x86_64";
      hash = "sha256-9hWnc1ZjWENkCGor6T8OeboSOKhWvm3bta73PnyUqXA=";
    };
    aarch64-linux = {
      arch = "arm64";
      hash = "sha256-1rZkEa02ZusLIXckRH3Rcoh6HUKw6URkbE/F/FzfnBw=";
    };
  };

  source =
    sources.${stdenv.hostPlatform.system}
      or (throw "helium: unsupported system ${stdenv.hostPlatform.system}");

  # On NixOS the host graphics stack is exposed through /run/opengl-driver; on
  # Omarchy (Arch) it is not, and Chromium's ANGLE then finds no usable EGL and
  # falls all the way back to software rendering. Point it at the Nix mesa in
  # that case, the way nixGL does, without disturbing a NixOS host.
  glFallback = ''
    if [ ! -e /run/opengl-driver/lib ]; then
      export LIBGL_DRIVERS_PATH="''${LIBGL_DRIVERS_PATH-${mesa}/lib/dri}"
      export LIBVA_DRIVERS_PATH="''${LIBVA_DRIVERS_PATH-${mesa}/lib/dri}"
      export __EGL_VENDOR_LIBRARY_FILENAMES="''${__EGL_VENDOR_LIBRARY_FILENAMES-${mesa}/share/glvnd/egl_vendor.d/50_mesa.json}"
      # ANGLE defaults to its Vulkan backend; with no ICD it drops to the
      # bundled SwiftShader, which has no Wayland WSI and then fails outright.
      export VK_DRIVER_FILES="''${VK_DRIVER_FILES-${mesa}/share/vulkan/icd.d}"
    fi
  '';

  # dlopen'ed at runtime, so autoPatchelfHook cannot see them.
  runtimeLibs = [
    addDriverRunpath.driverLink
    libglvnd
    libva
    libgbm
    pipewire
    vulkan-loader
  ];
in
stdenv.mkDerivation (finalAttrs: {
  pname = "helium";
  version = "0.16.5.1";

  src = fetchurl {
    url = "https://github.com/imputnet/helium-linux/releases/download/${finalAttrs.version}/helium-${finalAttrs.version}-${source.arch}_linux.tar.xz";
    inherit (source) hash;
  };

  nativeBuildInputs = [
    autoPatchelfHook
    makeWrapper
  ];

  buildInputs = [
    alsa-lib
    at-spi2-atk
    at-spi2-core
    atk
    cairo
    cups
    dbus
    expat
    glib
    libdrm
    libgbm
    libx11
    libxcb
    libxcomposite
    libxdamage
    libxext
    libxfixes
    libxkbcommon
    libxrandr
    nspr
    nss
    pango
    stdenv.cc.cc.lib
    systemd # libudev
  ];

  # The Qt platform-theme shims are optional: Chromium dlopen's one only when
  # asked for the Qt toolkit, and falls back to GTK when the load fails. Do not
  # drag Qt into the closure just to satisfy them.
  autoPatchelfIgnoreMissingDeps = [
    "libQt5Core.so.5"
    "libQt5Gui.so.5"
    "libQt5Widgets.so.5"
    "libQt6Core.so.6"
    "libQt6Gui.so.6"
    "libQt6Widgets.so.6"
  ];

  dontConfigure = true;
  dontBuild = true;

  installPhase = ''
    runHook preInstall

    mkdir -p $out/opt/helium
    cp -r . $out/opt/helium

    # Upstream's helium-wrapper only exists to set LD_LIBRARY_PATH relative to
    # the install dir; makeWrapper does that job with the store paths baked in.
    rm $out/opt/helium/helium-wrapper

    makeWrapper $out/opt/helium/helium $out/bin/helium \
      --prefix LD_LIBRARY_PATH : "$out/opt/helium:${lib.makeLibraryPath runtimeLibs}" \
      --suffix PATH : "${
        lib.makeBinPath [
          pciutils
          xdg-utils
        ]
      }" \
      --set-default CHROME_VERSION_EXTRA "nix" \
      --set CHROME_WRAPPER "$out/bin/helium" \
      --add-flags "--ozone-platform-hint=auto" \
      --run '${glFallback}'

    # Upstream ships the desktop entry with a bare `Exec=helium`, which only
    # resolves once the wrapper is on PATH. Point it at the store path instead.
    install -Dm644 $out/opt/helium/helium.desktop \
      $out/share/applications/helium.desktop
    rm $out/opt/helium/helium.desktop
    sed -i "s|^Exec=helium|Exec=$out/bin/helium|" \
      $out/share/applications/helium.desktop

    install -Dm644 $out/opt/helium/product_logo_256.png \
      $out/share/icons/hicolor/256x256/apps/helium.png

    runHook postInstall
  '';

  meta = {
    description = "Private, fast, and honest web browser built on Chromium";
    homepage = "https://helium.computer";
    downloadPage = "https://github.com/imputnet/helium-linux/releases";
    changelog = "https://github.com/imputnet/helium/releases";
    license = lib.licenses.gpl3Only;
    mainProgram = "helium";
    maintainers = [ ];
    platforms = builtins.attrNames sources;
    sourceProvenance = with lib.sourceTypes; [ binaryNativeCode ];
  };
})
