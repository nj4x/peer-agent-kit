#!/usr/bin/env bash
# peer-agent-kit uninstaller.
#
# Surgically removes peer-agent-kit entries from settings.json and statusline.sh
# using marker-based detection (not byte-exact restore from backups):
# - settings.json: removes hook entries containing 'peer-agent-activate.js' and
#   'peer-agent-mode-tracker.js' via lib/settings-unpatch.js
# - statusline.sh: removes the block between '# PEER_AGENT-KIT BEGIN' and
#   '# PEER_AGENT-KIT END' via lib/statusline-unpatch.js
# ~/.claude.json is the mutable state store, so it is restored surgically:
# only the mcpServers.vscode-agent-bridge entry is reverted (lib/mcp-unpatch.js),
# the rest of the live file is kept.
# Then removes ~/.peer-agent-kit.
set -euo pipefail

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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
SKILL_INSTALLED_BY_KIT="$(node -e "const m=JSON.parse(require('fs').readFileSync('$MANIFEST','utf8')); console.log(m.skillInstalledByKit === true ? 'true' : 'false')")"

SETTINGS="$CLAUDE_DIR/settings.json"
STATUSLINE="$CLAUDE_DIR/statusline.sh"
MCP_CONFIG="${HOME}/.claude.json"

# Surgically remove peer-agent hooks from settings.json using marker-based detection
if [ -f "$SETTINGS" ]; then
  node "$KIT_DIR/lib/settings-unpatch.js" "$SETTINGS"
  echo "restored: $SETTINGS (surgical removal)"
else
  echo "warning: $SETTINGS not found — skipping settings unpatch" >&2
fi

# Surgically remove peer-agent badge block from statusline.sh using sentinel markers
if [ -f "$STATUSLINE" ] && [ ! -L "$STATUSLINE" ]; then
  node "$KIT_DIR/lib/statusline-unpatch.js" "$STATUSLINE"
else
  echo "warning: $STATUSLINE not found (or is a symlink) — skipping statusline unpatch" >&2
fi

# Restore MCP config surgically using mcp-unpatch.js
node "$KIT_DIR/lib/mcp-unpatch.js" "$MCP_CONFIG" "$MANIFEST"

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
