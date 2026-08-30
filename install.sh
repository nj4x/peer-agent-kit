#!/usr/bin/env bash
# peer-agent-kit installer.
#
# Registers the vscode-agent-bridge MCP server, installs the VS Code extension,
# injects hook entries (SessionStart, UserPromptSubmit) into settings.json,
# and patches statusline.sh with a peer-agent badge. Everything touched is
# backed up under ~/.peer-agent-kit/backup/ so uninstall.sh can restore it
# exactly (byte-for-byte for settings/statusline, by removing for MCP/extension).
#
# The peer-agent skill ships with this kit (skills/peer-agent/); if not yet
# present at $CLAUDE_CONFIG_DIR/skills/peer-agent, the installer copies
# it in — with an interactive prompt, or non-interactively when
# PEER_AGENT_KIT_INSTALL_SKILL=1 or --install-skill is passed.
set -euo pipefail

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
KIT_HOME="$HOME/.peer-agent-kit"
BACKUP_DIR="$KIT_HOME/backup"
SETTINGS="$CLAUDE_DIR/settings.json"
STATUSLINE="$CLAUDE_DIR/statusline.sh"
MCP_CONFIG="${HOME}/.claude.json"
SKILL_PATH="$CLAUDE_DIR/skills/peer-agent/SKILL.md"
SKILL_SOURCE="$KIT_DIR/skills/peer-agent"
EXTENSION_DIR="$KIT_DIR/extension"

if [ "${1:-}" = "--vscode" ]; then
  if ! command -v node >/dev/null 2>&1 || ! command -v npm >/dev/null 2>&1; then
    if command -v brew >/dev/null 2>&1; then
      echo "node/npm not found — installing via Homebrew..."
      brew install node || { echo "error: brew install node failed" >&2; exit 1; }
    else
      echo "error: node/npm not found and Homebrew unavailable — install Node.js first: https://nodejs.org" >&2
      exit 1
    fi
  fi

  if ! command -v code >/dev/null 2>&1; then
    VSCODE_APP_BIN="/Applications/Visual Studio Code.app/Contents/Resources/app/bin"
    if [ -d "$VSCODE_APP_BIN" ]; then
      echo "error: 'code' CLI not in PATH. Add it to your shell profile:" >&2
      echo "  export PATH=\"$VSCODE_APP_BIN:\$PATH\"" >&2
    else
      echo "error: VS Code not found — install it first: https://code.visualstudio.com" >&2
    fi
    exit 1
  fi

  echo "building VS Code extension..."
  cd "$EXTENSION_DIR"
  if npm ci --prefer-offline 2>/dev/null; then
    npm run compile 2>/dev/null || true
    VSCODE_EXT_DIR="$HOME/.vscode/extensions"
    if [ -d "$VSCODE_EXT_DIR" ]; then
      if npm run install-dev 2>/dev/null; then
        echo "extension installed: $VSCODE_EXT_DIR"
      else
        echo "warning: extension install-dev failed" >&2
      fi
    else
      echo "warning: $VSCODE_EXT_DIR not found — skipping extension install" >&2
    fi
  else
    echo "warning: npm ci failed — skipping extension build" >&2
  fi
  cd "$KIT_DIR"

  code --user-data-dir "$HOME/.vscode-agent-bridge/data" --disable-extension nj4x.vscode-agent-bridge >/dev/null 2>&1 &
  disown 2>/dev/null || true
  echo "opened VS Code for template profile setup — configure it, then close the window"
  exit 0
fi

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

# --- Prerequisites: auto-install what we can, warn about the rest -----------

# node/npm — required for hooks and extension build. Try Homebrew if absent.
if ! command -v node >/dev/null 2>&1 || ! command -v npm >/dev/null 2>&1; then
  if command -v brew >/dev/null 2>&1; then
    echo "node/npm not found — installing via Homebrew..."
    brew install node || { echo "error: brew install node failed" >&2; exit 1; }
  else
    echo "error: node/npm not found and Homebrew unavailable — install Node.js first: https://nodejs.org" >&2
    exit 1
  fi
fi

# uv — required to run the MCP server. Official installer puts it in ~/.local/bin.
if ! command -v uv >/dev/null 2>&1; then
  echo "uv not found — installing via https://astral.sh/uv ..."
  if curl -LsSf https://astral.sh/uv/install.sh | sh; then
    export PATH="$HOME/.local/bin:$PATH"
  fi
  if ! command -v uv >/dev/null 2>&1; then
    echo "error: uv install failed — install manually: https://docs.astral.sh/uv/getting-started/" >&2
    exit 1
  fi
fi

# Python >= 3.10 — uv can provision its own interpreter; pre-fetch so the
# first MCP launch isn't slow.
uv python install >/dev/null 2>&1 || true

# VS Code CLI — needed at runtime for the bridge to spawn its window.
# Can't install the app; on macOS point at the bundled CLI if the app exists.
if ! command -v code >/dev/null 2>&1; then
  VSCODE_APP_BIN="/Applications/Visual Studio Code.app/Contents/Resources/app/bin"
  if [ -d "$VSCODE_APP_BIN" ]; then
    echo "warning: 'code' CLI not in PATH. Add it to your shell profile:" >&2
    echo "  export PATH=\"$VSCODE_APP_BIN:\$PATH\"" >&2
  else
    echo "warning: VS Code not found — the bridge cannot spawn its window until VS Code + 'code' CLI are installed" >&2
  fi
fi

# cline-sr — the peer agent itself; no public marketplace id, so check-only.
if ! ls "$HOME/.vscode/extensions" 2>/dev/null | grep -qi 'cline-sr'; then
  echo "warning: cline-sr extension not detected in ~/.vscode/extensions — install it in VS Code before delegating" >&2
fi
CLINE_STATE="$HOME/.cline-sr/data/globalState.json"
if [ -f "$CLINE_STATE" ] && command -v node >/dev/null 2>&1; then
  HOOKS_ENABLED="$(node -e "try{const s=JSON.parse(require('fs').readFileSync('$CLINE_STATE','utf8'));console.log(s.hooksEnabled===false?'false':'true')}catch(e){console.log('true')}")"
  if [ "$HOOKS_ENABLED" = "false" ]; then
    echo "warning: cline-sr Hooks are disabled — enable Hooks in cline-sr settings or the bridge cannot track tasks" >&2
  fi
fi

if [ ! -f "$SETTINGS" ]; then
  echo "error: $SETTINGS not found" >&2
  exit 1
fi

SKILL_INSTALLED_BY_KIT=false
SKILL_DIR="$CLAUDE_DIR/skills/peer-agent"
if [ ! -f "$SKILL_PATH" ]; then
  if [ "$INSTALL_SKILL" != "1" ]; then
    if [ -t 0 ]; then
      printf 'peer-agent skill not found. Install %s now? (Y/n) ' "$SKILL_SOURCE"
      if read -r answer; then
        case "$answer" in
          n|N|no|NO) ;;
          *) INSTALL_SKILL=1 ;;
        esac
      fi
    fi
  fi
  [ "$INSTALL_SKILL" = "1" ] || skill_missing_abort

  echo "installing peer-agent skill (copy from $SKILL_SOURCE)..."
  mkdir -p "$CLAUDE_DIR/skills"
  if ! cp -r "$SKILL_SOURCE" "$SKILL_DIR"; then
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

# Build and install extension (skip gracefully if ~/.vscode/extensions/ missing)
echo "building VS Code extension..."
cd "$EXTENSION_DIR"
if npm ci --prefer-offline 2>/dev/null; then
  npm run compile 2>/dev/null || true
  VSCODE_EXT_DIR="$HOME/.vscode/extensions"
  if [ -d "$VSCODE_EXT_DIR" ]; then
    if npm run install-dev 2>/dev/null; then
      echo "extension installed: $VSCODE_EXT_DIR"
    else
      echo "warning: extension install-dev failed" >&2
    fi
  else
    echo "warning: $VSCODE_EXT_DIR not found — skipping extension install" >&2
  fi
else
  echo "warning: npm ci failed — skipping extension build" >&2
fi
cd "$KIT_DIR"

# Pre-warm the MCP server environment so the first launch isn't a cold
# dependency install; uv run (used by the registration) reuses this env.
echo "setting up MCP server environment..."
if uv sync --directory "$KIT_DIR/mcp/vscode-agent-bridge" >/dev/null 2>&1; then
  # Smoke check: the server module must import cleanly.
  if uv run --directory "$KIT_DIR/mcp/vscode-agent-bridge" python -c "import server" >/dev/null 2>&1; then
    echo "MCP server environment ready"
  else
    echo "warning: MCP server env created but 'import server' failed — check 'uv run --directory $KIT_DIR/mcp/vscode-agent-bridge python -c \"import server\"'" >&2
  fi
else
  echo "warning: uv sync failed — the MCP server will install dependencies on first launch" >&2
fi

# Register MCP server in ~/.claude.json, backing up the original entry if present
echo "registering vscode-agent-bridge MCP server..."
mkdir -p "$KIT_HOME/hooks" "$BACKUP_DIR"

MCP_BACKUP_JSON="null"
if [ -f "$MCP_CONFIG" ]; then
  cp "$MCP_CONFIG" "$BACKUP_DIR/claude.json.bak"
  MCP_BACKUP_JSON="\"$BACKUP_DIR/claude.json.bak\""
fi

# Capture prior mcpServers["vscode-agent-bridge"] value before patching
MCP_PRIOR_ENTRY=$(node -e "
  try {
    const fs = require('fs');
    const config = JSON.parse(fs.readFileSync('$MCP_CONFIG', 'utf8'));
    const entry = config.mcpServers?.['vscode-agent-bridge'];
    console.log(entry ? JSON.stringify(entry) : 'null');
  } catch (e) {
    console.log('null');
  }
")
node "$KIT_DIR/lib/mcp-patch.js" "$MCP_CONFIG" "$KIT_DIR"

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
  "mcpConfigBackup": $MCP_BACKUP_JSON,
  "mcpPriorEntry": $MCP_PRIOR_ENTRY,
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

# --- Template profile bootstrap (ADR-0076, SRS-PAK-007) ---------------------
# `User/settings.json` under the canonical data dir is the configured-marker
# (not the parent dir, which ADR-0072's symlink bootstrap already creates as
# a side effect). One-time window: theme/keybindings/pane layout set here
# propagate into every future delegated session (bridge/instance.py copy).
TEMPLATE_USER_SETTINGS="$HOME/.vscode-agent-bridge/data/User/settings.json"
if [ ! -f "$TEMPLATE_USER_SETTINGS" ]; then
  if [ -t 0 ]; then
    echo
    echo "Template profile not configured yet."
    echo "This opens a one-time VS Code window where you can set your theme, keybindings,"
    echo "and pane layout — every future delegated session inherits it (no project folder"
    echo "will be opened; this window is for profile setup only)."
    printf 'Open it now? (y/N) '
    if read -r answer; then
      case "$answer" in
        y|Y|yes|YES)
          if command -v code >/dev/null 2>&1; then
            code --user-data-dir "$HOME/.vscode-agent-bridge/data" --disable-extension nj4x.vscode-agent-bridge >/dev/null 2>&1 &
            disown 2>/dev/null || true
            echo "opened VS Code for one-time profile setup — configure it, then close the window"
          else
            echo "warning: 'code' CLI not found — skipping template profile setup" >&2
          fi
          ;;
        *)
          echo "skipping template profile setup — run later: ./install.sh --vscode"
          ;;
      esac
    fi
  fi
  # non-TTY (CI/scripted install): skip silently
fi

echo
echo "peer-agent-kit installed to $KIT_HOME"
echo "Restart Claude Code for the hooks to take effect."
