#!/usr/bin/env bash
# peer-agent-kit uninstaller.
#
# Surgically removes peer-agent-kit entries from settings.json and statusline.sh
# using marker-based detection (not byte-exact restore from backups):
# - settings.json: removes hook entries containing 'peer-agent-activate.js' (SessionStart, SubagentStart) and
#   'peer-agent-mode-tracker.js' (UserPromptSubmit) via lib/settings-unpatch.js
# - statusline.sh: removes the block between '# PEER_AGENT-KIT BEGIN' and
#   '# PEER_AGENT-KIT END' via lib/statusline-unpatch.js
# ~/.claude.json is the mutable state store, so it is restored surgically:
# only the mcpServers.vscode-agent-bridge entry is reverted (lib/mcp-unpatch.js),
# the rest of the live file is kept.
# Then removes ~/.peer-agent-kit and the curl-install source directory.
set -euo pipefail

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KIT_HOME="$HOME/.peer-agent-kit"
MANIFEST="$KIT_HOME/manifest.json"
INSTALL_DIR="${PEER_AGENT_KIT_INSTALL_DIR:-$HOME/.local/share/peer-agent-kit}"

if [ ! -d "$KIT_HOME" ]; then
  echo "error: peer-agent-kit is not installed ($KIT_HOME not found)" >&2
  exit 1
fi

if ! command -v node >/dev/null 2>&1; then
  echo "error: node not found on PATH" >&2
  exit 1
fi

# If manifest is missing, we cannot safely uninstall (need mcpPriorEntry, skillInstalledByKit, etc.)
# However, we can still clean up $KIT_HOME and the Cline hooks — just warn about the rest.
if [ ! -f "$MANIFEST" ]; then
  echo "warning: $MANIFEST missing — cannot determine prior MCP config or skill state." >&2
  echo "Proceeding with best-effort cleanup (settings/statusline markers, Cline hooks, $KIT_HOME)." >&2
  
  # Still try to clean up what we can without manifest
  CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
  SETTINGS="$CLAUDE_DIR/settings.json"
  STATUSLINE="$CLAUDE_DIR/statusline.sh"
  MCP_CONFIG="${HOME}/.claude.json"
  
  if [ -f "$SETTINGS" ]; then
    node "$KIT_DIR/lib/settings-unpatch.js" "$SETTINGS" || true
    echo "restored: $SETTINGS (best-effort, marker-based)"
  fi
  
  if [ -f "$STATUSLINE" ] && [ ! -L "$STATUSLINE" ]; then
    node "$KIT_DIR/lib/statusline-unpatch.js" "$STATUSLINE" || true
  fi
  
  # Clean up Cline hooks (marker-based)
  CLINE_HOOKS_DIR="$HOME/Documents/Cline/Hooks"
  if [ -d "$CLINE_HOOKS_DIR" ]; then
    for f in "$CLINE_HOOKS_DIR"/*; do
      [ -f "$f" ] && grep -q "vscode-agent-bridge hook" "$f" 2>/dev/null && rm -f "$f" && echo "removed: $f (vscode-agent-bridge hook)"
    done
  fi
  
  rm -rf "$KIT_HOME"
  echo "removed: $KIT_HOME"
  
  # Remove source directory if this uninstall.sh is being run from the curl-install location
  if [ "$KIT_DIR" = "$INSTALL_DIR" ] || [ -f "$INSTALL_DIR/uninstall.sh" ]; then
    rm -rf "$INSTALL_DIR" && echo "removed: $INSTALL_DIR (curl-install source)"
  fi
  
  echo
  echo "peer-agent-kit uninstalled (best-effort, manifest was missing)."
  echo "Manual cleanup may be needed for MCP config and skill entries."
  exit 0
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

# Remove Cline hooks installed by the bridge (marker-based cleanup)
CLINE_HOOKS_DIR="$HOME/Documents/Cline/Hooks"
if [ -d "$CLINE_HOOKS_DIR" ]; then
  for f in "$CLINE_HOOKS_DIR"/*; do
    [ -f "$f" ] && grep -q "vscode-agent-bridge hook" "$f" 2>/dev/null && rm -f "$f" && echo "removed: $f (vscode-agent-bridge hook)"
  done
fi

rm -rf "$KIT_HOME"
echo "removed: $KIT_HOME"

# Remove the curl-install source directory if this uninstall.sh is being run from there
# (safe because the script is already loaded into memory)
if [ "$KIT_DIR" = "$INSTALL_DIR" ]; then
  rm -rf "$INSTALL_DIR" && echo "removed: $INSTALL_DIR (curl-install source)"
fi

echo
echo "peer-agent-kit uninstalled. Restart Claude Code."
