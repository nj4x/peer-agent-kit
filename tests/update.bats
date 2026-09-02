#!/usr/bin/env bats
# bats-core tests for peer-agent-kit update.sh
#
# These tests verify:
# - Missing manifest → nonzero exit, output mentions install
# - kitSha == remote SHA → exit 0, "up to date", settings.json unchanged
# - Missing kitSha → update proceeds, manifest contains fake SHA, settings.json repatched
# - Different kitSha → full cycle, manifest updated
# - Git pull failure → nonzero exit, manifest unchanged

setup() {
  # Create isolated temp home directory
  export HOME="$(mktemp -d)"
  export CLAUDE_CONFIG_DIR="$HOME/.claude"
  export KIT_HOME="$HOME/.peer-agent-kit"
  
  # Get the repo root (parent of tests/)
  export KIT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
  
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
  
  # Create KIT_HOME with hooks directory
  mkdir -p "$KIT_HOME/hooks"
  
  # Fix #2: Create per-test isolated stub directory to avoid mutating tracked files
  export TEST_STUBS_DIR="$HOME/test-stubs"
  mkdir -p "$TEST_STUBS_DIR"
  
  # Stub PATH - git stub must precede real git to intercept all calls
  # Fix #2: Use per-test isolated stub directory instead of tracked location
  export PATH="$TEST_STUBS_DIR:$KIT_DIR/tests/stubs:$PATH"
  
  # Create stub node wrapper - handles manifest ops, passes lib scripts to real node
  # Per brief: "use REAL node (do not stub it — the lib patch scripts must actually run)"
  # Copy pre-written stub file to isolated location (avoids mutating tracked file)
  cp "$KIT_DIR/tests/update-stub-node-template" "$TEST_STUBS_DIR/node"
  chmod +x "$TEST_STUBS_DIR/node"
  
  # Create git stub that handles all git calls from update.sh
  cat > "$KIT_DIR/tests/stubs/git" <<'STUB'
#!/usr/bin/env bash
# Stub git for update.sh tests
# Handles: fetch, symbolic-ref, rev-parse, pull, -C <dir> forms

# Parse arguments - handle -C <dir> prefix
args=("$@")
shift_idx=0
while [[ "${args[$shift_idx]}" == "-C" ]]; do
  shift_idx=$((shift_idx + 2))
done
cmd="${args[$shift_idx]}"

case "$cmd" in
  fetch)
    # git fetch origin - always succeeds
    exit 0
    ;;
  symbolic-ref)
    # git symbolic-ref refs/remotes/origin/HEAD
    if [[ "$*" == "refs/remotes/origin/HEAD" ]]; then
      echo "refs/remotes/origin/main"
      exit 0
    fi
    exit 1
    ;;
  rev-parse)
    # git rev-parse origin/main or git rev-parse HEAD
    if [[ "$*" == *"origin/main"* ]]; then
      echo "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
      exit 0
    elif [[ "$*" == *"HEAD"* ]]; then
      echo "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
      exit 0
    fi
    exit 1
    ;;
  pull)
    # git pull origin main --ff-only
    # Check for FAIL_PULL env var to simulate failure
    if [[ "${FAIL_PULL:-}" == "1" ]]; then
      echo "error: cannot pull with --ff-only" >&2
      exit 1
    fi
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
STUB
  chmod +x "$KIT_DIR/tests/stubs/git"
  
  # Create stub npm (in TEST_STUBS_DIR so it's found first in PATH)
  cat > "$TEST_STUBS_DIR/npm" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
  chmod +x "$TEST_STUBS_DIR/npm"
  
  # Create stub uv (in TEST_STUBS_DIR so it's found first in PATH)
  cat > "$TEST_STUBS_DIR/uv" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
  chmod +x "$TEST_STUBS_DIR/uv"
}

teardown() {
  # Clean up temp home
  rm -rf "$HOME"
}

@test "missing manifest → nonzero exit, output mentions install" {
  # Ensure no manifest exists
  rm -rf "$HOME/.peer-agent-kit"
  
  cd "$KIT_DIR"
  run bash "$KIT_DIR/update.sh" 2>&1
  
  [ "$status" -ne 0 ]
  [[ "$output" == *"install.sh"* ]] || [[ "$output" == *"First install"* ]]
}

@test "manifest kitSha == remote SHA → exit 0, output contains up to date, settings.json unchanged" {
  # Pre-seed manifest with kitSha matching remote
  mkdir -p "$HOME/.peer-agent-kit"
  cat > "$HOME/.peer-agent-kit/manifest.json" <<EOF
{
  "installedAt": "2026-09-02T00:00:00Z",
  "claudeDir": "$CLAUDE_CONFIG_DIR",
  "settingsBackup": null,
  "statuslineBackup": null,
  "mcpConfigBackup": null,
  "mcpPriorEntry": null,
  "pluginRoot": "$CLAUDE_CONFIG_DIR",
  "skillInstalledByKit": false,
  "skillBackup": null,
  "kitSha": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
  "completed": true
}
EOF
  
  # Pre-seed settings.json with some content to verify unchanged
  echo '{"existing":"value"}' > "$CLAUDE_CONFIG_DIR/settings.json"
  
  cd "$KIT_DIR"
  run bash "$KIT_DIR/update.sh" 2>&1
  
  [ "$status" -eq 0 ]
  [[ "$output" == *"Kit is already up to date"* ]]
  
  # Settings.json should be unchanged (no unpatch ran)
  grep -q '"existing":"value"' "$CLAUDE_CONFIG_DIR/settings.json"
}

@test "manifest without kitSha → update proceeds, manifest contains fake SHA, settings.json repatched" {
  # Pre-seed manifest WITHOUT kitSha (old install)
  mkdir -p "$HOME/.peer-agent-kit"
  cat > "$HOME/.peer-agent-kit/manifest.json" <<EOF
{
  "installedAt": "2026-09-02T00:00:00Z",
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
  
  # Pre-seed settings.json with hooks to verify unpatch/repatch cycle
  cat > "$CLAUDE_CONFIG_DIR/settings.json" <<EOF
{
  "hooks": {
    "SessionStart": [{"hooks": [{"type": "command", "command": "CLAUDE_PLUGIN_ROOT='$CLAUDE_CONFIG_DIR' node '$HOME/.peer-agent-kit/hooks/peer-agent-activate.js'"}]}]
  }
}
EOF
  
  cd "$KIT_DIR"
  run bash "$KIT_DIR/update.sh" 2>&1
  
  [ "$status" -eq 0 ]
  
  # Manifest should now contain the fake SHA
  grep -q '"kitSha":' "$HOME/.peer-agent-kit/manifest.json"
  grep -q 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' "$HOME/.peer-agent-kit/manifest.json"
}

@test "manifest with different kitSha → full cycle, manifest kitSha updated to fake SHA" {
  # Pre-seed manifest with different kitSha
  mkdir -p "$HOME/.peer-agent-kit"
  cat > "$HOME/.peer-agent-kit/manifest.json" <<EOF
{
  "installedAt": "2026-09-02T00:00:00Z",
  "claudeDir": "$CLAUDE_CONFIG_DIR",
  "settingsBackup": null,
  "statuslineBackup": null,
  "mcpConfigBackup": null,
  "mcpPriorEntry": null,
  "pluginRoot": "$CLAUDE_CONFIG_DIR",
  "skillInstalledByKit": false,
  "skillBackup": null,
  "kitSha": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
  "completed": true
}
EOF
  
  cd "$KIT_DIR"
  run bash "$KIT_DIR/update.sh" 2>&1
  
  [ "$status" -eq 0 ]
  
  # Manifest should be updated to the new fake SHA
  grep -q '"kitSha":' "$HOME/.peer-agent-kit/manifest.json"
  grep -q 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' "$HOME/.peer-agent-kit/manifest.json"
}

@test "git pull failure → nonzero exit, manifest kitSha unchanged" {
  # Pre-seed manifest with different kitSha
  mkdir -p "$HOME/.peer-agent-kit"
  cat > "$HOME/.peer-agent-kit/manifest.json" <<EOF
{
  "installedAt": "2026-09-02T00:00:00Z",
  "claudeDir": "$CLAUDE_CONFIG_DIR",
  "settingsBackup": null,
  "statuslineBackup": null,
  "mcpConfigBackup": null,
  "mcpPriorEntry": null,
  "pluginRoot": "$CLAUDE_CONFIG_DIR",
  "skillInstalledByKit": false,
  "skillBackup": null,
  "kitSha": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
  "completed": true
}
EOF
  
  # Set env var to make git pull fail
  export FAIL_PULL=1
  
  cd "$KIT_DIR"
  run bash "$KIT_DIR/update.sh" 2>&1
  
  [ "$status" -ne 0 ]
  [[ "$output" == *"git pull failed"* ]]

  # Manifest kitSha should remain unchanged
  grep -q '"kitSha": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"' "$HOME/.peer-agent-kit/manifest.json"
}
