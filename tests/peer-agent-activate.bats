#!/usr/bin/env bats
# bats-core tests for peer-agent-activate.js hook output

setup() {
  export HOME="$(mktemp -d)"
  export CLAUDE_CONFIG_DIR="$HOME/.claude"
  export KIT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"

  mkdir -p "$CLAUDE_CONFIG_DIR"
  mkdir -p "$HOME/.claude/projects"

  # Node stub for testing
  export PATH="$KIT_DIR/tests/stubs:$PATH"
}

teardown() {
  rm -rf "$HOME"
}

# Test 1: mode file not found, should fall back to global default
@test "peer-agent-activate.js falls back to global default when repo mode file missing" {
  # Create global default flag file pointing to 'full' mode
  mkdir -p "$HOME/.claude"
  echo "full" > "$HOME/.claude/.peer-agent-active"

  # Run hook with repo-scoped flag file path (doesn't exist)
  output=$(node "$KIT_DIR/hooks/peer-agent-activate.js" 2>&1)

  # Should emit PEER_AGENT MODE ACTIVE banner
  [[ "$output" == *"PEER_AGENT MODE ACTIVE"* ]]

  # Should include 'full' mode rules (from SKILL.md)
  [[ "$output" == *"Delegate"* ]] # full mode includes execution language
}

# Test 2: repo-scoped mode file takes precedence
@test "peer-agent-activate.js prefers repo-scoped mode file over global" {
  mkdir -p "$HOME/.claude/projects/test-repo/.claude"
  echo "max" > "$HOME/.claude/projects/test-repo/.claude/.peer-agent-mode"
  echo "full" > "$HOME/.claude/.peer-agent-active"

  output=$(node "$KIT_DIR/hooks/peer-agent-activate.js" \
    "$HOME/.claude/projects/test-repo/.claude/.peer-agent-mode" 2>&1)

  # Should emit max mode banner
  [[ "$output" == *"PEER_AGENT MODE ACTIVE"* ]]
  [[ "$output" == *"level: max"* ]]
}

# Test 3: 'off' mode produces minimal output
@test "peer-agent-activate.js respects 'off' mode" {
  echo "off" > "$HOME/.claude/.peer-agent-active"

  output=$(node "$KIT_DIR/hooks/peer-agent-activate.js" 2>&1)

  # Should still emit mode banner
  [[ "$output" == *"PEER_AGENT MODE ACTIVE"* ]]
  [[ "$output" == *"level: off"* ]]

  # Should NOT include delegation rules
  [[ ! "$output" =~ Delegate\ by\ (default|policy) ]]
}

# Test 4: all modes present in output when cycling through them
@test "peer-agent-activate.js loads all modes from SKILL.md" {
  for mode in off lite full max; do
    echo "$mode" > "$HOME/.claude/.peer-agent-active"
    output=$(node "$KIT_DIR/hooks/peer-agent-activate.js" 2>&1)

    # Verify banner is always present
    [[ "$output" == *"PEER_AGENT MODE ACTIVE"* ]]
    [[ "$output" == *"level: $mode"* ]]
  done
}

# Test 5: missing SKILL.md fails gracefully
@test "peer-agent-activate.js fails with clear error if SKILL.md missing" {
  echo "full" > "$HOME/.claude/.peer-agent-active"

  # Temporarily hide SKILL.md
  mv "$KIT_DIR/skills/peer-agent/SKILL.md" "$KIT_DIR/skills/peer-agent/SKILL.md.bak"

  output=$(node "$KIT_DIR/hooks/peer-agent-activate.js" 2>&1)

  # Should emit error, not partial/broken output
  [[ "$output" == *"error"* ]] || [[ "$output" == *"Error"* ]] || [[ "$output" == *"not found"* ]]

  # Restore
  mv "$KIT_DIR/skills/peer-agent/SKILL.md.bak" "$KIT_DIR/skills/peer-agent/SKILL.md"
}
