#!/usr/bin/env bash
# peer-agent-kit bootstrap script for curl | bash installation.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/nj4x/peer-agent-kit/main/bootstrap.sh | bash
#
# Environment overrides:
#   PEER_AGENT_KIT_GIT_REPO   — Git repo URL (default: https://github.com/nj4x/peer-agent-kit.git)
#   PEER_AGENT_KIT_INSTALL_DIR — Installation directory (default: $HOME/.local/share/peer-agent-kit)
#
# All arguments are forwarded to install.sh (e.g., --vscode, --install-skill).
set -euo pipefail

REPO_URL="${PEER_AGENT_KIT_GIT_REPO:-https://github.com/nj4x/peer-agent-kit.git}"
INSTALL_DIR="${PEER_AGENT_KIT_INSTALL_DIR:-$HOME/.local/share/peer-agent-kit}"

# --- Prerequisites check ----------------------------------------------------
if ! command -v git >/dev/null 2>&1; then
  echo "error: git not found on PATH — install Git first" >&2
  exit 1
fi

if ! command -v curl >/dev/null 2>&1; then
  echo "error: curl not found on PATH — install curl first" >&2
  exit 1
fi

# --- Clone or update --------------------------------------------------------
if [ -d "$INSTALL_DIR/.git" ]; then
  echo "[peer-agent-kit] Updating existing installation at $INSTALL_DIR..."
  git -C "$INSTALL_DIR" pull --ff-only
else
  echo "[peer-agent-kit] Cloning peer-agent-kit to $INSTALL_DIR..."
  git clone "$REPO_URL" "$INSTALL_DIR"
fi

# --- Hand off to install.sh -------------------------------------------------
echo "[peer-agent-kit] Running install.sh..."
exec "$INSTALL_DIR/install.sh" "$@"
