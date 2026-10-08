{
  lib,
  pkgs,
  isOmarchy,
  ...
}:

let
  # `nix develop --command` leaves its nix-shell.* directory behind in /tmp,
  # which on Omarchy is a RAM-backed tmpfs with a per-user quota: six hundred
  # of them held 6 GB after two days of kitchens. This removes the ones no
  # process still uses once they are two hours old. A directory is in use when
  # a process of this user has it as TMPDIR, as its working directory, or
  # holds a file inside it open.
  clean = pkgs.writeShellScript "clean-nix-shell-tmp" ''
    set -u
    uid="$(${pkgs.coreutils}/bin/id -u)"
    inuse="$(for p in /proc/[0-9]*; do
      [ "$(${pkgs.coreutils}/bin/stat -c %u "$p" 2>/dev/null)" = "$uid" ] || continue
      { ${pkgs.coreutils}/bin/tr '\0' '\n' <"$p/environ"; } 2>/dev/null | ${pkgs.gnused}/bin/sed -n 's/^\(TMPDIR\|TMP\|TEMP\|NIX_BUILD_TOP\)=//p'
      ${pkgs.coreutils}/bin/readlink "$p/cwd" 2>/dev/null
      ${pkgs.coreutils}/bin/ls -l "$p/fd" 2>/dev/null | ${pkgs.gawk}/bin/awk '{print $NF}'
    done | ${pkgs.gnugrep}/bin/grep -o '^/tmp/nix-shell\.[^/]*' | ${pkgs.coreutils}/bin/sort -u)"
    removed=0
    while IFS= read -r d; do
      [ -n "$d" ] || continue
      case "$d" in /tmp/nix-shell.*) ;; *) continue ;; esac
      ${pkgs.gnugrep}/bin/grep -qxF "$d" <<<"$inuse" && continue
      ${pkgs.coreutils}/bin/rm -rf -- "$d" && removed=$((removed + 1))
    done < <(${pkgs.findutils}/bin/find /tmp -maxdepth 1 -name 'nix-shell.*' -user "$uid" -mmin +120 2>/dev/null)
    echo "clean-nix-shell-tmp: removed $removed"
  '';
in
lib.mkIf isOmarchy {
  systemd.user.services.clean-nix-shell-tmp = {
    Unit.Description = "Remove unused nix-shell.* directories from /tmp";
    Service = {
      Type = "oneshot";
      ExecStart = "${clean}";
      Nice = 10;
    };
  };

  systemd.user.timers.clean-nix-shell-tmp = {
    Unit.Description = "Clean unused nix-shell.* directories every 30 minutes";
    Timer = {
      OnBootSec = "10min";
      OnUnitActiveSec = "30min";
      Persistent = true;
    };
    Install.WantedBy = [ "timers.target" ];
  };
}
