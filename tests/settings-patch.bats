#!/usr/bin/env bats
# bats-core tests for lib/settings-patch.js

setup() {
  export HOME="$(mktemp -d)"
  export KIT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
  export SETTINGS="$HOME/settings.json"
  export HOOKS_DIR="$HOME/.peer-agent-kit/hooks"
  export PLUGIN_ROOT="$HOME/.claude"
  echo '{}' > "$SETTINGS"
}

teardown() {
  rm -rf "$HOME"
}

patch() {
  node "$KIT_DIR/lib/settings-patch.js" "$SETTINGS" "$HOOKS_DIR" "$PLUGIN_ROOT"
}

count_entries() {
  node -e "const s=require('$SETTINGS');console.log((s.hooks['$1']||[]).length)"
}

@test "fresh inject adds one entry per event" {
  run patch
  [ "$status" -eq 0 ]
  [ "$(count_entries SessionStart)" -eq 1 ]
  [ "$(count_entries SubagentStart)" -eq 1 ]
  [ "$(count_entries UserPromptSubmit)" -eq 1 ]
  grep -q "$HOOKS_DIR/peer-agent-activate.js" "$SETTINGS"
  grep -q "$HOOKS_DIR/peer-agent-mode-tracker.js" "$SETTINGS"
}

@test "re-run with same hooksDir is a no-op" {
  patch
  before="$(cat "$SETTINGS")"
  run patch
  [ "$status" -eq 0 ]
  [[ "$output" != *"repointing"* ]]
  [[ "$output" == *"SessionStart hook: already present"* ]]
  [ "$(cat "$SETTINGS")" = "$before" ]
}

@test "stale marker entries are repointed to the new hooksDir" {
  cat > "$SETTINGS" <<EOF
{
  "hooks": {
    "SessionStart": [{"hooks": [{"type": "command", "command": "CLAUDE_PLUGIN_ROOT='$PLUGIN_ROOT' node '/old/hooks/peer-agent-activate.js'"}]}],
    "SubagentStart": [{"hooks": [{"type": "command", "command": "CLAUDE_PLUGIN_ROOT='$PLUGIN_ROOT' node '/old/hooks/peer-agent-activate.js'"}]}],
    "UserPromptSubmit": [{"hooks": [{"type": "command", "command": "CLAUDE_PLUGIN_ROOT='$PLUGIN_ROOT' node '/old/hooks/peer-agent-mode-tracker.js'"}]}]
  }
}
EOF
  run patch
  [ "$status" -eq 0 ]
  [[ "$output" == *"SessionStart hook entry already exists, repointing to $HOOKS_DIR"* ]]
  [[ "$output" == *"SubagentStart hook entry already exists, repointing to $HOOKS_DIR"* ]]
  [[ "$output" == *"UserPromptSubmit hook entry already exists, repointing to $HOOKS_DIR"* ]]
  ! grep -q "/old/hooks" "$SETTINGS"
  [ "$(count_entries SessionStart)" -eq 1 ]
  [ "$(count_entries SubagentStart)" -eq 1 ]
  [ "$(count_entries UserPromptSubmit)" -eq 1 ]
  grep -q "$HOOKS_DIR/peer-agent-activate.js" "$SETTINGS"
  grep -q "$HOOKS_DIR/peer-agent-mode-tracker.js" "$SETTINGS"
}

@test "foreign hook entries in the same event survive a repoint" {
  cat > "$SETTINGS" <<EOF
{
  "hooks": {
    "SessionStart": [
      {"hooks": [{"type": "command", "command": "echo user-hook"}]},
      {"hooks": [{"type": "command", "command": "node '/old/hooks/peer-agent-activate.js'"}]}
    ]
  }
}
EOF
  run patch
  [ "$status" -eq 0 ]
  [ "$(count_entries SessionStart)" -eq 2 ]
  grep -q "echo user-hook" "$SETTINGS"
  ! grep -q "/old/hooks" "$SETTINGS"
  grep -q "$HOOKS_DIR/peer-agent-activate.js" "$SETTINGS"
}

@test "foreign hook sharing one entry with a stale marker hook survives a repoint" {
  cat > "$SETTINGS" <<EOF
{
  "hooks": {
    "SessionStart": [
      {"matcher": "x", "hooks": [
        {"type": "command", "command": "echo user-hook"},
        {"type": "command", "command": "node '/old/hooks/peer-agent-activate.js'"}
      ]}
    ]
  }
}
EOF
  run patch
  [ "$status" -eq 0 ]
  [[ "$output" == *"repointing"* ]]
  grep -q "echo user-hook" "$SETTINGS"
  ! grep -q "/old/hooks" "$SETTINGS"
  grep -q "$HOOKS_DIR/peer-agent-activate.js" "$SETTINGS"
}
