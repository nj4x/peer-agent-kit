#!/usr/bin/env bats
# bats-core tests for hooks/peer-agent-mode-tracker.js (UserPromptSubmit hook).
#
# ADR 0004: 'off' is a real, persisted mode value — it must survive to the
# next turn even when another scope's flag holds a stale non-off value.

setup() {
  export HOME="$(mktemp -d)"
  export CLAUDE_CONFIG_DIR="$HOME/.claude"
  export KIT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
  mkdir -p "$CLAUDE_CONFIG_DIR"
}

teardown() {
  rm -rf "$HOME"
}

# Builds the envelope Claude Code actually delivers (command tags embedded in
# a much larger prompt) around an arbitrary body, and feeds it to the hook.
# Args passed via argv, not string-interpolated into the JS source, so a body
# containing quotes/backslashes can't break the harness.
run_hook_body() {
  local command_name="$1" args="$2" body="$3" cwd="$4"
  node -e "
    const [commandName, args, body, cwd] = process.argv.slice(1);
    const prompt = '<command-message>peer-agent</command-message>\n' +
      '<command-name>' + commandName + '</command-name>\n' +
      '<command-args>' + args + '</command-args>\n\n' + body;
    process.stdout.write(JSON.stringify({ prompt, cwd }));
  " "$command_name" "$args" "$body" "$cwd" | node "$KIT_DIR/hooks/peer-agent-mode-tracker.js"
}

# Realistic delivery: real SKILL.md body, our own /peer-agent envelope.
run_hook() {
  local mode="$1" cwd="$2"
  local skill; skill="$(cat "$KIT_DIR/skills/peer-agent/SKILL.md")"
  run_hook_body "/peer-agent" "$mode" "$skill\n\nARGUMENTS: $mode" "$cwd"
}

@test "off persists as an explicit value, not a deleted file" {
  run_hook off "$HOME"
  [ -f "$CLAUDE_CONFIG_DIR/.peer-agent-active" ]
  [ "$(cat "$CLAUDE_CONFIG_DIR/.peer-agent-active")" = "off" ]
}

@test "off emits no reminder on the turn it's set" {
  output="$(run_hook off "$HOME")"
  [[ "$output" != *"PEER_AGENT MODE ACTIVE"* ]]
}

@test "off survives a later turn even when the global flag holds a stale non-off value (regression)" {
  # Simulates the reported bug: a stale global flag from an earlier session.
  echo "max" > "$CLAUDE_CONFIG_DIR/.peer-agent-active"

  run_hook off "$HOME"
  [ "$(cat "$CLAUDE_CONFIG_DIR/.peer-agent-active")" = "off" ]

  # A later, unrelated turn (no mode command in the prompt) must not revert.
  output="$(printf '{"prompt":"what does this function do","cwd":"%s"}' "$HOME" | node "$KIT_DIR/hooks/peer-agent-mode-tracker.js")"
  [[ "$output" != *"PEER_AGENT MODE ACTIVE"* ]]
  [ "$(cat "$CLAUDE_CONFIG_DIR/.peer-agent-active")" = "off" ]
}

@test "max sets an explicit value and emits the reminder" {
  output="$(run_hook max "$HOME")"
  [ "$(cat "$CLAUDE_CONFIG_DIR/.peer-agent-active")" = "max" ]
  [[ "$output" == *"PEER_AGENT MODE ACTIVE (max)"* ]]
}

@test "repo-scoped off wins over a global non-off default" {
  repo="$HOME/repo"
  mkdir -p "$repo/.claude"
  git -C "$repo" init -q
  echo "max" > "$CLAUDE_CONFIG_DIR/.peer-agent-active"

  run_hook off "$repo"

  [ "$(cat "$repo/.claude/.peer-agent-mode")" = "off" ]
  # Global flag untouched — the repo scope shadows it, per decision 6.
  [ "$(cat "$CLAUDE_CONFIG_DIR/.peer-agent-active")" = "max" ]
}

# The tests above use the real SKILL.md body, which happens to contain the
# literal string "peer-agent off" in its own prose (documenting the command).
# That means a broken envelope-extraction regex could silently fall through
# to the natural-language matcher and still produce the right answer for
# off — masking the exact class of bug this hook exists to prevent. These
# tests use a neutral body with no trigger phrases, so only correct envelope
# extraction can pass them.
NEUTRAL_BODY="This is unrelated filler text with no mode-change phrases in it."

@test "envelope extraction alone sets lite, independent of a neutral body" {
  run_hook_body "/peer-agent" "lite" "$NEUTRAL_BODY" "$HOME"
  [ "$(cat "$CLAUDE_CONFIG_DIR/.peer-agent-active")" = "lite" ]
}

@test "a foreign command's envelope is never parsed for a mode change, even if its body mentions peer-agent off" {
  run_hook_body "/other-command" "off" "some body text: peer-agent off is mentioned here" "$HOME"
  [ ! -f "$CLAUDE_CONFIG_DIR/.peer-agent-active" ]
}

@test "an envelope naming /peer-agent with an unknown arg leaves the flag untouched" {
  run_hook_body "/peer-agent" "bogus" "$NEUTRAL_BODY" "$HOME"
  [ ! -f "$CLAUDE_CONFIG_DIR/.peer-agent-active" ]
}
