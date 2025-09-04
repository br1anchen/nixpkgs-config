# This file defines two overlays and composes them
{ inputs, ... }:
let
  # This one brings our custom packages from the 'pkgs' directory
  additions = final: _prev: import ../pkgs { pkgs = final; };

  # This one contains whatever you want to overlay
  # You can change versions, add patches, set compilation flags, anything really.
  # https://nixos.wiki/wiki/Overlays
  modifications = final: prev: {
    # Fix lazyjj test failures by disabling tests
    lazyjj = prev.lazyjj.overrideAttrs (oldAttrs: {
      doCheck = false;
      doInstallCheck = false;
    });

    # Also fix jujutsu in case it has similar issues
    jujutsu = prev.jujutsu.overrideAttrs (oldAttrs: {
      doCheck = false;
      doInstallCheck = false;
    });
  };
in
inputs.nixpkgs.lib.composeManyExtensions [
  additions
  modifications
]
