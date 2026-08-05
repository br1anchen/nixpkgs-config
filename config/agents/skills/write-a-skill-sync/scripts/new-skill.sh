#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  new-skill.sh --scope <project|system> --name <skill-name>

Creates the skill scaffold under:
  project: ./.agent/skills/<skill-name>/
  system:  ~/nixpkgs-config/config/agents/skills/<skill-name>/

After system scope, verifies/ensures ~/.agent/skills symlink to ~/.agents/skills.
EOF
}

scope=""
name=""

while (($#)); do
  case "$1" in
    --scope)
      [[ $# -ge 2 ]] || { usage >&2; exit 2; }
      scope="$2"
      shift 2
      ;;
    --name)
      [[ $# -ge 2 ]] || { usage >&2; exit 2; }
      name="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      printf 'Unknown argument: %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
 done

if [[ -z "$scope" ]]; then
  read -r -p "Scope [project/system]: " scope
fi
if [[ "$scope" != "project" && "$scope" != "system" ]]; then
  printf 'Scope must be "project" or "system".\n' >&2
  exit 2
fi

if [[ -z "$name" ]]; then
  read -r -p "Skill name (slug): " name
fi

if [[ -z "$name" || ! "$name" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
  printf 'Skill name must match pattern: [a-z0-9][a-z0-9-]*\n' >&2
  exit 2
fi

if [[ "$scope" == "project" ]]; then
  target_root="$PWD/.agent/skills"
elif [[ "$scope" == "system" ]]; then
  target_root="$HOME/nixpkgs-config/config/agents/skills"
fi

skill_dir="$target_root/$name"
if [[ -e "$skill_dir" ]]; then
  printf 'Target already exists: %s\n' "$skill_dir" >&2
  exit 1
fi

mkdir -p "$skill_dir"

if [[ ! -f "$skill_dir/SKILL.md" ]]; then
  display_name="${name//-/ }"
  cat > "$skill_dir/SKILL.md" <<EOF
---
name: $name
description: "[replace with one-line capability]. Use when ..."
---

# $display_name

## Quick start

1. Replace this template content with complete skill instructions.
2. Keep the \`description\` in \`SKILL.md\` under 1024 chars and include "Use when ...".
3. Add optional \`REFERENCE.md\`, \`EXAMPLES.md\`, and \`scripts/\` as needed.
4. Ask for review of edge cases before publishing.
EOF
fi

echo "Scaffolded skill at: $skill_dir"

if [[ "$scope" == "system" ]]; then
  hm_file="$HOME/nixpkgs-config/home-manager/agents.nix"
  if [[ ! -f "$hm_file" ]]; then
    echo "warning: missing $hm_file" >&2
  else
    if ! grep -q 'customSkillsDir = ../config/agents/skills;' "$hm_file"; then
      printf 'warning: agents.nix does not show auto-import for config/agents/skills.\nAppend the sync block from write-a-skill-sync before publishing this skill.\n' >&2
    fi
    if ! grep -q 'ln -sfn "$HOME/.agents/skills" "$HOME/.agent/skills"' "$hm_file"; then
      echo "warning: agents.nix does not contain ~/.agent/skills symlink activation step." >&2
    fi
  fi

  mkdir -p "$HOME/.agent"
  ln -sfn "$HOME/.agents/skills" "$HOME/.agent/skills"
  echo "Ensured ~/.agent/skills -> ~/.agents/skills"
  echo "Run: home-manager switch --flake ~/nixpkgs-config#darwin (or host profile)"
fi

if [[ "$scope" == "project" ]]; then
  echo "If you want immediate runtime visibility, create/update ~/.pi/agent/skills/<name> symlink as needed."
fi
