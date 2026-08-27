# When you add custom packages, list them here
# These are similar to nixpkgs packages
{
  inputs,
  pkgs,
}:
{
  # example = pkgs.callPackage ./example { };
  jj-spr = pkgs.callPackage ./jj-spr { };
  pi-coding-agent = pkgs.callPackage ./pi-coding-agent { };
  prime-agent = pkgs.callPackage ./prime-agent { };
  plannotator = pkgs.callPackage ./plannotator { };
  plannotator-pi-extension = pkgs.callPackage ./plannotator-pi-extension { };
  rtk = pkgs.callPackage ./rtk { };
  "safe-chain" = pkgs.callPackage ./safe-chain { };
  vim-herdr-navigation = pkgs.callPackage ./vim-herdr-navigation {
    src = inputs.vim-herdr-navigation-src;
  };
  weave = pkgs.callPackage ./weave { };
}
