# When you add custom packages, list them here
# These are similar to nixpkgs packages
{ pkgs }:
{
  # example = pkgs.callPackage ./example { };
  rtk = pkgs.callPackage ./rtk { };
  "safe-chain" = pkgs.callPackage ./safe-chain { };
}
