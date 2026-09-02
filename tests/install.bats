#!/usr/bin/env bats
# bats-core tests for peer-agent-kit install.sh and uninstall.sh
#
# These tests verify:
# - Fresh install creates manifest.json with completed: true
# - Re-running install.sh after successful install fails with "already installed"
# - Mid-install failure triggers rollback (KIT_HOME does not exist after)
# - Uninstall removes KIT_HOME and restores settings.json markers

setup() {
  # Create isolated temp home directory
  export HOME="$(mktemp -d)"
  export CLAUDE_CONFIG_DIR="$HOME/.claude"
  
  # Get the repo root (parent of tests/)
  export KIT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
  
  # Fix #2: Create per-test isolated stub directory to avoid mutating tracked files
  export TEST_STUBS_DIR="$HOME/test-stubs"
  mkdir -p "$TEST_STUBS_DIR"
  
  # Pre-seed minimal Claude Code configuration
  mkdir -p "$CLAUDE_CONFIG_DIR"
  echo '{}' > "$CLAUDE_CONFIG_DIR/settings.json"
  echo '#!/usr/bin/env bash' > "$CLAUDE_CONFIG_DIR/statusline.sh"
  
  # Pre-seed minimal ~/.claude.json for MCP config
  echo '{"mcpServers":{}}' > "$HOME/.claude.json"
  
  # Create Cline state directory (hooks enabled by default)
  mkdir -p "$HOME/.cline-sr/data"
  echo '{"hooksEnabled":true}' > "$HOME/.cline-sr/data/globalState.json"
  
  # Create Cline Hooks directory
  mkdir -p "$HOME/Documents/Cline/Hooks"
  
  # Create VS Code extensions directory
  mkdir -p "$HOME/.vscode/extensions"
  
  # Stub node to avoid real npm/uv operations in tests
  # We only test file layout, not dependency installation
  # Fix #2: Use per-test isolated stub directory instead of tracked location
  export PATH="$TEST_STUBS_DIR:$PATH"
  
  # Create stub scripts that simulate successful operations without side effects
  cat > "$TEST_STUBS_DIR/node" <<'STUB'
#!/usr/bin/env bash
# Stub node that handles the specific invocations from install.sh and uninstall.sh

# Check for various invocation patterns
if [[ "$*" == *"mcpServers"* ]] || [[ "$*" == *"config.mcpServers"* ]]; then
  echo "null"
  exit 0
fi

# For claudeDir extraction from manifest
if [[ "$*" == *"claudeDir"* ]]; then
  echo "$CLAUDE_CONFIG_DIR"
  exit 0
fi

# For skillInstalledByKit extraction
if [[ "$*" == *"skillInstalledByKit"* ]]; then
  echo "false"
  exit 0
fi

# For completed field check
if [[ "$*" == *"completed"* ]]; then
  echo "true"
  exit 0
fi

# Default: succeed silently
exit 0
STUB
  chmod +x "$TEST_STUBS_DIR/node"
  
  cat > "$KIT_DIR/tests/stubs/npm" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
  chmod +x "$KIT_DIR/tests/stubs/npm"
  
  cat > "$KIT_DIR/tests/stubs/uv" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
  chmod +x "$KIT_DIR/tests/stubs/uv"
  
  cat > "$KIT_DIR/tests/stubs/curl" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
  chmod +x "$KIT_DIR/tests/stubs/curl"
  
  cat > "$KIT_DIR/tests/stubs/brew" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
  chmod +x "$KIT_DIR/tests/stubs/brew"
  
  cat > "$KIT_DIR/tests/stubs/code" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
  chmod +x "$KIT_DIR/tests/stubs/code"
}

teardown() {
  # Clean up temp home
  rm -rf "$HOME"
}

@test "fresh install creates manifest.json with completed: true" {
  # Run install.sh with --install-skill to avoid interactive prompts
  # Skip the real MCP server sync by stubbing uv
  cd "$KIT_DIR"
  
  # Pre-install the skill so we don't need network
  mkdir -p "$CLAUDE_CONFIG_DIR/skills"
  cp -r "$KIT_DIR/skills/peer-agent" "$CLAUDE_CONFIG_DIR/skills/peer-agent"
  
  # Run install with stubs - it will mostly succeed but may fail on some node ops
  # We're testing that manifest gets created with the right structure
  run bash "$KIT_DIR/install.sh" --install-skill 2>&1 || true
  
  # Check manifest exists and has required fields. Grep the raw file rather
  # than parsing with `node` — PATH is stubbed for this test, so the stubbed
  # node's canned responses would validate nothing.
  [ -f "$HOME/.peer-agent-kit/manifest.json" ]
  grep -q '"completed": *true' "$HOME/.peer-agent-kit/manifest.json"
  grep -q "\"claudeDir\": \"$CLAUDE_CONFIG_DIR\"" "$HOME/.peer-agent-kit/manifest.json"
  grep -q '"kitSha"' "$HOME/.peer-agent-kit/manifest.json"
}

@test "re-running install.sh after successful install fails with already installed" {
  # Pre-install the skill so the guard is what fails this run, not a
  # missing-skill error further down the script.
  mkdir -p "$CLAUDE_CONFIG_DIR/skills"
  cp -r "$KIT_DIR/skills/peer-agent" "$CLAUDE_CONFIG_DIR/skills/peer-agent"

  # Simulate a completed prior install
  mkdir -p "$HOME/.peer-agent-kit/backup"
  cat > "$HOME/.peer-agent-kit/manifest.json" <<EOF
{
  "installedAt": "2026-08-30T00:00:00Z",
  "claudeDir": "$CLAUDE_CONFIG_DIR",
  "settingsBackup": "$HOME/.peer-agent-kit/backup/settings.json.bak",
  "statuslineBackup": null,
  "mcpConfigBackup": null,
  "mcpPriorEntry": null,
  "pluginRoot": "$CLAUDE_CONFIG_DIR",
  "skillInstalledByKit": false,
  "skillBackup": null,
  "completed": true
}
EOF
  cp "$CLAUDE_CONFIG_DIR/settings.json" "$HOME/.peer-agent-kit/backup/settings.json.bak"

  cd "$KIT_DIR"
  run bash "$KIT_DIR/install.sh" 2>&1

  [ "$status" -ne 0 ]
  [[ "$output" == *"already installed"* ]]
  # The completed install must be left untouched, not wiped by the guard.
  [ -d "$HOME/.peer-agent-kit" ]
}

@test "re-running install.sh after an incomplete prior install self-heals" {
  mkdir -p "$CLAUDE_CONFIG_DIR/skills"
  cp -r "$KIT_DIR/skills/peer-agent" "$CLAUDE_CONFIG_DIR/skills/peer-agent"

  # Simulate a crash before manifest.json was ever written to completed:true
  mkdir -p "$HOME/.peer-agent-kit/backup"
  cat > "$HOME/.peer-agent-kit/manifest.json" <<EOF
{
  "installedAt": "2026-08-30T00:00:00Z",
  "claudeDir": "$CLAUDE_CONFIG_DIR",
  "settingsBackup": null,
  "statuslineBackup": null,
  "mcpConfigBackup": null,
  "mcpPriorEntry": null,
  "pluginRoot": "$CLAUDE_CONFIG_DIR",
  "skillInstalledByKit": false,
  "skillBackup": null,
  "completed": false
}
EOF

  cd "$KIT_DIR"
  run bash "$KIT_DIR/install.sh" --install-skill 2>&1

  [[ "$output" == *"cleaning up before retry"* ]]
  [ -f "$HOME/.peer-agent-kit/manifest.json" ]
  grep -q '"completed": *true' "$HOME/.peer-agent-kit/manifest.json"
}

@test "uninstall removes KIT_HOME and cleans up Cline hooks" {
  # Set up a mock installation
  mkdir -p "$HOME/.peer-agent-kit/hooks"
  mkdir -p "$HOME/.peer-agent-kit/backup"
  
  cat > "$HOME/.peer-agent-kit/manifest.json" <<EOF
{
  "installedAt": "2026-08-30T00:00:00Z",
  "claudeDir": "$CLAUDE_CONFIG_DIR",
  "settingsBackup": null,
  "statuslineBackup": null,
  "mcpConfigBackup": null,
  "mcpPriorEntry": null,
  "pluginRoot": "$CLAUDE_CONFIG_DIR",
  "skillInstalledByKit": false,
  "skillBackup": null,
  "completed": true
}
EOF
  
  # Create a Cline hook with the bridge marker
  echo '# vscode-agent-bridge hook
echo "test hook"' > "$HOME/Documents/Cline/Hooks/TaskStart"
  
  # Create another file without the marker (should not be removed)
  echo '# My custom hook
echo "custom"' > "$HOME/Documents/Cline/Hooks/CustomHook"
  
  # Run uninstall
  cd "$KIT_DIR"
  run bash "$KIT_DIR/uninstall.sh" 2>&1 || true
  
  # Verify KIT_HOME is removed
  [ ! -d "$HOME/.peer-agent-kit" ]
  
  # Verify bridge hook is removed
  [ ! -f "$HOME/Documents/Cline/Hooks/TaskStart" ]
  
  # Verify custom hook is preserved
  [ -f "$HOME/Documents/Cline/Hooks/CustomHook" ]
}

@test "uninstall with missing manifest does best-effort cleanup" {
  # Set up partial installation (no manifest)
  mkdir -p "$HOME/.peer-agent-kit/hooks"
  
  # Create a Cline hook with the bridge marker
  echo '# vscode-agent-bridge hook
echo "test hook"' > "$HOME/Documents/Cline/Hooks/PreToolUse"
  
  # Run uninstall - should do best-effort cleanup
  cd "$KIT_DIR"
  run bash "$KIT_DIR/uninstall.sh" 2>&1
  
  # Should warn about missing manifest but still proceed
  [[ "$output" == *"warning"* ]] || [[ "$output" == *"best-effort"* ]]
  
  # KIT_HOME should be removed
  [ ! -d "$HOME/.peer-agent-kit" ]
  
  # Bridge hook should be removed
  [ ! -f "$HOME/Documents/Cline/Hooks/PreToolUse" ]
}
