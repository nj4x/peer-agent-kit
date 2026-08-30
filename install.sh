#!/usr/bin/env bash
# peer-agent-kit installer.
#
# Preserves the existing Claude Code configuration: injects two hook entries
# (SessionStart, UserPromptSubmit) into settings.json and a small badge block
# into statusline.sh. Everything touched is backed up under
# ~/.peer-agent-kit/backup/ so uninstall.sh can restore it exactly.
#
# The peer-agent skill ships with this kit (skills/peer-agent/); if it is not
# yet present at $CLAUDE_CONFIG_DIR/skills/peer-agent, the installer symlinks
# it in — with an interactive prompt, or non-interactively when
# PEER_AGENT_KIT_INSTALL_SKILL=1 or --install-skill is passed.
set -euo pipefail

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
KIT_HOME="$HOME/.peer-agent-kit"
BACKUP_DIR="$KIT_HOME/backup"
SETTINGS="$CLAUDE_DIR/settings.json"
STATUSLINE="$CLAUDE_DIR/statusline.sh"
SKILL_PATH="$CLAUDE_DIR/skills/peer-agent/SKILL.md"
SKILL_SOURCE="$KIT_DIR/skills/peer-agent"

INSTALL_SKILL=0
[ "${1:-}" = "--install-skill" ] && INSTALL_SKILL=1
[ "${PEER_AGENT_KIT_INSTALL_SKILL:-}" = "1" ] && INSTALL_SKILL=1

skill_missing_abort() {
  echo "error: peer-agent skill not found at $SKILL_PATH" >&2
  echo "peer-agent-kit only wires up hooks for it — install the skill first:" >&2
  echo "  ln -s $SKILL_SOURCE $CLAUDE_DIR/skills/peer-agent" >&2
  echo "or re-run with --install-skill (or PEER_AGENT_KIT_INSTALL_SKILL=1) to let this installer do it." >&2
  exit 1
}

if [ -d "$KIT_HOME" ]; then
  echo "error: peer-agent-kit already installed at $KIT_HOME. Run uninstall.sh first." >&2
  exit 1
fi

if ! command -v node >/dev/null 2>&1; then
  echo "error: node not found on PATH" >&2
  exit 1
fi

if [ ! -f "$SETTINGS" ]; then
  echo "error: $SETTINGS not found" >&2
  exit 1
fi

SKILL_INSTALLED_BY_KIT=false
if [ ! -f "$SKILL_PATH" ]; then
  if [ "$INSTALL_SKILL" != "1" ]; then
    if [ -t 0 ]; then
      printf 'peer-agent skill not found. Install %s now? (y/N) ' "$SKILL_SOURCE"
      if read -r answer; then
        case "$answer" in
          y|Y|yes|YES) INSTALL_SKILL=1 ;;
        esac
      fi
    fi
  fi
  [ "$INSTALL_SKILL" = "1" ] || skill_missing_abort

  echo "installing peer-agent skill (symlink to $SKILL_SOURCE)..."
  mkdir -p "$CLAUDE_DIR/skills"
  if ! ln -s "$SKILL_SOURCE" "$CLAUDE_DIR/skills/peer-agent"; then
    echo "warning: automated skill install failed" >&2
    skill_missing_abort
  fi
  if [ ! -f "$SKILL_PATH" ]; then
    echo "warning: skill install ran but $SKILL_PATH still missing" >&2
    skill_missing_abort
  fi
  SKILL_INSTALLED_BY_KIT=true
fi

# Resolve through the skill's symlink chain (if any) so the SessionStart hook
# can find SKILL.md via CLAUDE_PLUGIN_ROOT regardless of how it's linked in.
PLUGIN_ROOT="$(cd -P "$(dirname "$SKILL_PATH")/../.." && pwd)"

mkdir -p "$KIT_HOME/hooks" "$BACKUP_DIR"
cp "$KIT_DIR"/hooks/*.js "$KIT_HOME/hooks/"

cp "$SETTINGS" "$BACKUP_DIR/settings.json.bak"
node "$KIT_DIR/lib/settings-patch.js" "$SETTINGS" "$KIT_HOME/hooks" "$PLUGIN_ROOT"

STATUSLINE_BACKUP_JSON="null"
if [ -f "$STATUSLINE" ] && [ ! -L "$STATUSLINE" ]; then
  cp "$STATUSLINE" "$BACKUP_DIR/statusline.sh.bak"
  node "$KIT_DIR/lib/statusline-patch.js" "$STATUSLINE"
  STATUSLINE_BACKUP_JSON="\"$BACKUP_DIR/statusline.sh.bak\""
else
  echo "warning: $STATUSLINE not found (or is a symlink) — skipping statusline badge" >&2
fi

# Skill frontmatter patch (ADR 0002). Backup first; manifest is written with
# the skill fields BEFORE the patch attempt (decision 6) so uninstall.sh can
# always clean up correctly even if the patch fails. Patch failure is
# non-fatal by design.
SKILL_BACKUP_JSON="null"
SKILL_NEEDS_PATCH=1
if grep -q '^disable-model-invocation:' "$SKILL_PATH" 2>/dev/null; then
  SKILL_NEEDS_PATCH=0
fi
if [ "$SKILL_NEEDS_PATCH" = "1" ]; then
  if cp "$SKILL_PATH" "$BACKUP_DIR/SKILL.md.bak"; then
    SKILL_BACKUP_JSON="\"$BACKUP_DIR/SKILL.md.bak\""
  else
    echo "warning: could not back up SKILL.md — skipping frontmatter patch" >&2
    SKILL_NEEDS_PATCH=0
  fi
fi

cat > "$KIT_HOME/manifest.json" <<JSON
{
  "installedAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "claudeDir": "$CLAUDE_DIR",
  "settingsBackup": "$BACKUP_DIR/settings.json.bak",
  "statuslineBackup": $STATUSLINE_BACKUP_JSON,
  "pluginRoot": "$PLUGIN_ROOT",
  "skillInstalledByKit": $SKILL_INSTALLED_BY_KIT,
  "skillBackup": $SKILL_BACKUP_JSON
}
JSON

if [ "$SKILL_NEEDS_PATCH" = "1" ]; then
  if ! node "$KIT_DIR/lib/skill-patch.js" "$SKILL_PATH"; then
    echo "warning: failed to patch SKILL.md frontmatter — skill installed without disable-model-invocation" >&2
  fi
fi

echo
echo "peer-agent-kit installed to $KIT_HOME"
echo "Restart Claude Code for the hooks to take effect."
