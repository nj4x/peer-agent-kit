#!/usr/bin/env bash
# peer-agent-kit uninstaller.
#
# Restores settings.json and statusline.sh from the exact backups install.sh
# made, then removes ~/.peer-agent-kit. Byte-exact restore, not a surgical diff —
# simpler and safer than trying to reverse-parse what was injected.
set -euo pipefail

KIT_HOME="$HOME/.peer-agent-kit"
MANIFEST="$KIT_HOME/manifest.json"

if [ ! -d "$KIT_HOME" ]; then
  echo "error: peer-agent-kit is not installed ($KIT_HOME not found)" >&2
  exit 1
fi

if ! command -v node >/dev/null 2>&1; then
  echo "error: node not found on PATH" >&2
  exit 1
fi

if [ ! -f "$MANIFEST" ]; then
  echo "error: $MANIFEST missing — cannot determine what to restore." >&2
  echo "Remove $KIT_HOME manually and revert settings.json/statusline.sh by hand." >&2
  exit 1
fi

CLAUDE_DIR="$(node -e "console.log(JSON.parse(require('fs').readFileSync('$MANIFEST','utf8')).claudeDir)")"
SETTINGS_BACKUP="$(node -e "console.log(JSON.parse(require('fs').readFileSync('$MANIFEST','utf8')).settingsBackup)")"
STATUSLINE_BACKUP="$(node -e "const m=JSON.parse(require('fs').readFileSync('$MANIFEST','utf8')); console.log(m.statuslineBackup || '')")"
MCP_CONFIG_BACKUP="$(node -e "const m=JSON.parse(require('fs').readFileSync('$MANIFEST','utf8')); console.log(m.mcpConfigBackup || '')")"
SKILL_INSTALLED_BY_KIT="$(node -e "const m=JSON.parse(require('fs').readFileSync('$MANIFEST','utf8')); console.log(m.skillInstalledByKit === true ? 'true' : 'false')")"
SKILL_BACKUP="$(node -e "const m=JSON.parse(require('fs').readFileSync('$MANIFEST','utf8')); console.log(m.skillBackup || '')")"

SETTINGS="$CLAUDE_DIR/settings.json"
STATUSLINE="$CLAUDE_DIR/statusline.sh"
MCP_CONFIG="${HOME}/.claude.json"

if [ ! -f "$SETTINGS_BACKUP" ]; then
  echo "error: settings backup not found at $SETTINGS_BACKUP" >&2
  exit 1
fi
cp "$SETTINGS_BACKUP" "$SETTINGS"
echo "restored: $SETTINGS"

if [ -n "$STATUSLINE_BACKUP" ]; then
  if [ -f "$STATUSLINE_BACKUP" ]; then
    cp "$STATUSLINE_BACKUP" "$STATUSLINE"
    echo "restored: $STATUSLINE"
  else
    echo "warning: statusline backup recorded but missing at $STATUSLINE_BACKUP — left $STATUSLINE untouched" >&2
  fi
fi

# Restore MCP config from backup if it exists
if [ -n "$MCP_CONFIG_BACKUP" ]; then
  if [ -f "$MCP_CONFIG_BACKUP" ]; then
    cp "$MCP_CONFIG_BACKUP" "$MCP_CONFIG"
    echo "restored: $MCP_CONFIG"
  else
    echo "warning: MCP config backup recorded but missing at $MCP_CONFIG_BACKUP — left $MCP_CONFIG untouched" >&2
  fi
elif [ -f "$MCP_CONFIG" ]; then
  # No backup means the file didn't exist before; remove the entire file if created by us
  rm "$MCP_CONFIG"
  echo "removed: $MCP_CONFIG (created during install)"
fi

# Remove VS Code extension symlink if installed
VSCODE_EXT_DIR="$HOME/.vscode/extensions"
if [ -d "$VSCODE_EXT_DIR" ]; then
  PUBLISHER="nj4x"
  NAME="vscode-agent-bridge"
  VERSION="0.1.0"
  LINK="$VSCODE_EXT_DIR/$PUBLISHER.$NAME-$VERSION"
  if [ -L "$LINK" ]; then
    rm "$LINK"
    echo "removed: $LINK (extension symlink)"
  fi
fi

# Skill cleanup (ADR 0002/0003): remove entirely if the kit installed it;
# otherwise leave it (copied installation is permanent).
SKILL_DIR="$CLAUDE_DIR/skills/peer-agent"
if [ "$SKILL_INSTALLED_BY_KIT" = "true" ]; then
  rm -rf "$SKILL_DIR"
  echo "removed: $SKILL_DIR (installed by peer-agent-kit)"
fi

rm -rf "$KIT_HOME"
echo "removed: $KIT_HOME"
echo
echo "peer-agent-kit uninstalled. Restart Claude Code."
