{
  lib,
  inputs,
  isOmarchy,
  ...
}:

{
  imports = [ inputs.rex.homeManagerModules.default ];

  # Rex personal server on Omarchy, reachable from the Mac app as its own
  # tailnet device (built-in Tailscale, https://blade-rex.<tailnet>.ts.net).
  # First start prints a sign-in link in `rex server status`. The user service
  # stops on logout unless `loginctl enable-linger` was run once.
  config = lib.mkIf isOmarchy {
    services.rex = {
      enable = true;
      tailscale = {
        enable = true;
        hostname = "blade-rex";
      };
    };

    # The guard needs programs.ssh, which would make ~/.ssh/config a
    # home-manager symlink. Run `rex terminfo setup` once instead.
    programs.rex.sshGuard = false;
  };
}
