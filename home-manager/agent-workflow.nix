{
  agentWorkflow,
  config,
  inputs,
  lib,
  pkgs,
  ...
}:

let
  herdr = inputs.herdr.packages.${pkgs.stdenv.hostPlatform.system}.herdr;
  navigation = pkgs.vim-herdr-navigation;
  navigationRoot = "${navigation}/share/vim-herdr-navigation";
  plannotatorExtension = "${pkgs.plannotator-pi-extension}/lib/node_modules/@plannotator/pi-extension";
  # Use the user's login shell rather than a pinned nix zsh: that is bash on
  # Omarchy and zsh on macOS.
  ghosttyShell = pkgs.writeShellScriptBin "ghostty-shell" ''
    exec ghostty --command="''${SHELL:-/bin/sh} -l" "$@"
  '';
  codexHooks = (pkgs.formats.json { }).generate "codex-hooks.json" {
    description = "Herdr session reporting and Plannotator plan review.";
    hooks = {
      SessionStart = [
        {
          hooks = [
            {
              type = "command";
              command = "${config.home.homeDirectory}/.codex/herdr-agent-state.sh session";
              timeout = 10;
            }
          ];
        }
      ];
      Stop = [
        {
          hooks = [
            {
              type = "command";
              command = "${pkgs.plannotator}/bin/plannotator";
              timeout = 345600;
            }
          ];
        }
      ];
    };
  };
in
lib.mkIf agentWorkflow {
  # pi is deliberately absent: it is mise-managed (see config/mise/config.toml).
  # mise's install dirs precede ~/.nix-profile/bin on PATH, so a nix pi could
  # never win. The plannotator pi extension below is installed into
  # ~/.pi/agent/extensions and works against whichever pi is on PATH.
  home.packages = [
    herdr
    pkgs.plannotator
    ghosttyShell
  ];

  home.file = {
    ".pi/agent/extensions/herdr-agent-state.ts".source =
      "${inputs.herdr}/src/integration/assets/pi/herdr-agent-state.ts";
    ".pi/agent/extensions/plannotator" = {
      source = plannotatorExtension;
      recursive = true;
    };

    ".codex/herdr-agent-state.sh" = {
      source = "${inputs.herdr}/src/integration/assets/codex/herdr-agent-state.sh";
      executable = true;
      force = true;
    };
    ".codex/hooks.json" = {
      source = codexHooks;
      force = true;
    };

    ".claude/hooks/herdr-agent-state.sh" = {
      source = "${inputs.herdr}/src/integration/assets/claude/herdr-agent-state.sh";
      executable = true;
      force = true;
    };
  };

  # Deliberate exceptions to "home-manager writes nothing under ~/.config on
  # Omarchy": both paths are plugin drop-ins that Omarchy provably never touches,
  # and their content is derived from flake inputs rather than hand-edited, so
  # routing them through dotfiles-sync would be meaningless. The nvim drop-in
  # survives `dotfiles-sync push` because directory pushes overlay rather than
  # replace.
  #
  # herdr/config.toml is NOT here: it is a shared repo file now.
  # ghostty's `command = herdr` is NOT here either: on Omarchy, herdr is launched
  # by Omarchy's own SUPER+CTRL+RETURN binding (omarchy-launch-terminal-herdr),
  # and forcing every ghostty window to run herdr would break the plain terminal.
  # macOS keeps that behaviour via config/ghostty/platform.darwin.
  xdg.configFile = {
    "nvim/after/plugin/herdr_nav.lua".source = "${navigationRoot}/editor/nvim.lua";
    "opencode/plugins/herdr-agent-state.js".source =
      "${inputs.herdr}/src/integration/assets/opencode/herdr-agent-state.js";
  };

  home.activation = {
    registerVimHerdrNavigation = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      expected_source=${lib.escapeShellArg navigationRoot}
      offline_socket="''${TMPDIR:-/tmp}/home-manager-herdr-offline-$$.sock"

      if [[ -n "''${DRY_RUN_CMD:-}" ]]; then
        $DRY_RUN_CMD ${herdr}/bin/herdr plugin link "$expected_source"
      elif ! ${herdr}/bin/herdr plugin link "$expected_source" >/dev/null 2>&1; then
        # A running server can lag behind the Home Manager client after an
        # upgrade. Persist the plugin for its next start without stopping it.
        HERDR_SOCKET_PATH="$offline_socket" \
          ${herdr}/bin/herdr plugin link "$expected_source" >/dev/null
      fi
      $DRY_RUN_CMD rm -f "$HOME/.config/herdr/.vim-herdr-navigation-source"
    '';

    configureClaudeAgentWorkflow = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      settings="$HOME/.claude/settings.json"
      hook_command="$HOME/.claude/hooks/herdr-agent-state.sh session"
      mkdir -p "$HOME/.claude"
      [[ -e "$settings" ]] || printf '{}\n' > "$settings"

      if ! ${pkgs.jq}/bin/jq -e '
        type == "object"
        and ((.hooks // {}) | type == "object")
        and ((.hooks.SessionStart // []) | type == "array")
      ' "$settings" >/dev/null; then
        echo "warning: leaving malformed Claude settings untouched: $settings" >&2
      else
        updated="$(${pkgs.coreutils}/bin/mktemp "$settings.agent-workflow.XXXXXX")"
        if ${pkgs.jq}/bin/jq --arg command "$hook_command" '
          .hooks //= {}
          | .hooks.SessionStart //= []
          | if any(
              .hooks.SessionStart[]?;
              any(.hooks[]?; .type == "command" and .command == $command)
            )
            then .
            else .hooks.SessionStart += [{
              "matcher": "*",
              "hooks": [{
                "type": "command",
                "command": $command,
                "timeout": 10
              }]
            }]
            end
        ' "$settings" > "$updated"; then
          if ! ${pkgs.diffutils}/bin/cmp -s "$settings" "$updated"; then
            ${pkgs.coreutils}/bin/cp -p "$settings" "$settings.agent-workflow.bak"
            ${pkgs.coreutils}/bin/chmod 600 "$updated"
            ${pkgs.coreutils}/bin/mv "$updated" "$settings"
          else
            ${pkgs.coreutils}/bin/rm -f "$updated"
          fi
        else
          ${pkgs.coreutils}/bin/rm -f "$updated"
          echo "warning: failed to merge the Herdr hook into $settings" >&2
        fi

        if command -v claude >/dev/null 2>&1; then
          plugin_dir="$HOME/.claude/plugins"
          marker="$HOME/.claude/.agent-workflow-plannotator-source"
          expected_source=${lib.escapeShellArg (toString inputs.plannotator-src)}
          installed="$(
            claude plugin list --json 2>/dev/null \
              | ${pkgs.jq}/bin/jq -r \
                  'any(.[]?; .id == "plannotator@plannotator")' 2>/dev/null
          )"

          backup_plugin_registries() {
            mkdir -p "$plugin_dir"
            for registry in known_marketplaces.json installed_plugins.json; do
              if [[ -r "$plugin_dir/$registry" ]]; then
                ${pkgs.coreutils}/bin/cp -p \
                  "$plugin_dir/$registry" \
                  "$plugin_dir/$registry.agent-workflow.bak"
              fi
            done
          }

          if [[ ! -r "$marker" ]] || [[ "$(< "$marker")" != "$expected_source" ]]; then
            backup_plugin_registries

            claude plugin uninstall plannotator@plannotator >/dev/null 2>&1 || true
            claude plugin marketplace remove plannotator >/dev/null 2>&1 || true
            claude plugin marketplace add "$expected_source"
            claude plugin install --scope user plannotator@plannotator
            printf '%s\n' "$expected_source" > "$marker"
          elif [[ "$installed" != "true" ]]; then
            backup_plugin_registries
            claude plugin install --scope user plannotator@plannotator
          fi
        else
          echo "warning: claude is not on PATH; skipped Plannotator plugin registration" >&2
        fi
      fi
    '';
  };
}
