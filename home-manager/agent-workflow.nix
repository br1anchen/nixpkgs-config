{
  agentWorkflow,
  config,
  inputs,
  lib,
  pkgs,
  ...
}:

let
  herdr = inputs.herdr.packages.${pkgs.system}.herdr;
  navigation = pkgs.vim-herdr-navigation;
  navigationRoot = "${navigation}/share/vim-herdr-navigation";
  plannotatorExtension = "${pkgs.plannotator-pi-extension}/lib/node_modules/@plannotator/pi-extension";
  herdrConfig = (pkgs.formats.toml { }).generate "herdr-config.toml" {
    onboarding = false;

    theme.name = "catppuccin";

    terminal = {
      default_shell = "${pkgs.zsh}/bin/zsh";
      shell_mode = "login";
      new_cwd = "follow";
    };

    keys = {
      prefix = "ctrl+a";
      command = [
        {
          key = "ctrl+h";
          type = "plugin_action";
          command = "vim-herdr-navigation.left";
          description = "navigate left (vim/herdr)";
        }
        {
          key = "ctrl+j";
          type = "plugin_action";
          command = "vim-herdr-navigation.down";
          description = "navigate down (vim/herdr)";
        }
        {
          key = "ctrl+k";
          type = "plugin_action";
          command = "vim-herdr-navigation.up";
          description = "navigate up (vim/herdr)";
        }
        {
          key = "ctrl+l";
          type = "plugin_action";
          command = "vim-herdr-navigation.right";
          description = "navigate right (vim/herdr)";
        }
      ];
    };

    ui.copy_on_select = true;

    session.resume_agents_on_restore = true;
    worktrees.directory = "~/.herdr/worktrees";
    experimental.allow_nested = false;
  };
  ghosttyShell = pkgs.writeShellScriptBin "ghostty-shell" ''
    exec ghostty --command="${pkgs.zsh}/bin/zsh -l" "$@"
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
  home.packages = [
    herdr
    pkgs.pi-coding-agent
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

  xdg.configFile = {
    "herdr/config.toml".source = herdrConfig;
    "ghostty/config".text = lib.mkAfter ''

      # Agent workflow control plane
      command = ${herdr}/bin/herdr
    '';
    "nvim/after/plugin/herdr_nav.lua".source = "${navigationRoot}/editor/nvim.lua";
    "opencode/plugins/herdr-agent-state.js".source =
      "${inputs.herdr}/src/integration/assets/opencode/herdr-agent-state.js";
  };

  programs.zsh.shellAliases = {
    hdr = "herdr";
    herdr-reload = "herdr server reload-config";
    gsh = "ghostty-shell";
  };

  home.activation = {
    registerVimHerdrNavigation = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      marker="$HOME/.config/herdr/.vim-herdr-navigation-source"
      expected_source=${lib.escapeShellArg navigationRoot}

      if [[ ! -r "$marker" ]] || [[ "$(< "$marker")" != "$expected_source" ]]; then
        ${herdr}/bin/herdr plugin unlink vim-herdr-navigation >/dev/null 2>&1 || true
        ${herdr}/bin/herdr plugin link "$expected_source"
        printf '%s\n' "$expected_source" > "$marker"
      fi
      ${herdr}/bin/herdr plugin enable vim-herdr-navigation
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
