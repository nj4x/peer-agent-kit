#!/usr/bin/env bats
# bats-core tests for peer-agent-activate.js hook output.
#
# The hook takes no arguments: it reads the session's cwd from stdin JSON and
# resolves the mode flag from the repo-scoped file, then the global one.

setup() {
  export HOME="$(mktemp -d)"
  export CLAUDE_CONFIG_DIR="$HOME/.claude"
  export KIT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
  export CLAUDE_PLUGIN_ROOT="$KIT_DIR"

  mkdir -p "$CLAUDE_CONFIG_DIR"
}

teardown() {
  rm -rf "$HOME"
}

# Runs the hook with the given cwd on stdin and extracts additionalContext
# from its JSON hookSpecificOutput envelope (or passes non-JSON output, i.e.
# a stderr-only failure path, through unchanged) so existing assertions can
# keep matching on plain ruleset text.
#
# Known gap: if the hook ever regresses to plain-text stdout, this passthrough
# masks it for the tests below that use run_hook — their asserted substrings
# need no JSON escaping and appear verbatim either way. Only the raw-envelope
# tests further down (asserting on `hookEventName`/`additionalContext` keys
# directly, bypassing run_hook) actually guard the JSON envelope shape.
run_hook() {
  local payload
  if [ "$#" -eq 0 ]; then
    payload='{}'
  else
    payload="$(printf '{"cwd":"%s"}' "$1")"
  fi
  printf '%s' "$payload" | node "$KIT_DIR/hooks/peer-agent-activate.js" 2>&1 | node -e '
    let raw = "";
    process.stdin.on("data", c => { raw += c; });
    process.stdin.on("end", () => {
      if (!raw) { process.stdout.write(""); return; }
      try {
        const parsed = JSON.parse(raw);
        process.stdout.write((parsed.hookSpecificOutput && parsed.hookSpecificOutput.additionalContext) || "");
      } catch (e) {
        process.stdout.write(raw);
      }
    });
  '
}

# Creates a git repo with a .claude/ dir holding the given mode, echoes its path.
make_repo() {
  local root="$HOME/repo"
  mkdir -p "$root/.claude"
  git -C "$root" init -q
  echo "$1" > "$root/.claude/.peer-agent-mode"
  echo "$root"
}

@test "falls back to the global flag when no repo-scoped file exists" {
  echo "full" > "$CLAUDE_CONFIG_DIR/.peer-agent-active"

  output="$(run_hook)"

  [[ "$output" == *"PEER_AGENT MODE ACTIVE — level: full"* ]]
  [[ "$output" == *"| **full** |"* ]]
}

@test "prefers the repo-scoped flag over the global one" {
  echo "full" > "$CLAUDE_CONFIG_DIR/.peer-agent-active"
  repo="$(make_repo max)"

  output="$(run_hook "$repo")"

  [[ "$output" == *"PEER_AGENT MODE ACTIVE — level: max"* ]]
  [[ "$output" == *"| **max** |"* ]]
}

@test "emits only the active mode's table row" {
  echo "lite" > "$CLAUDE_CONFIG_DIR/.peer-agent-active"

  output="$(run_hook)"

  [[ "$output" == *"| **lite** |"* ]]
  [[ "$output" != *"| **full** |"* ]]
  [[ "$output" != *"| **max** |"* ]]
}

@test "emits cumulative examples up to the active mode, without mode prefixes" {
  echo "full" > "$CLAUDE_CONFIG_DIR/.peer-agent-active"

  output="$(run_hook)"

  [[ "$output" == *'"find every call site'* ]]
  [[ "$output" == *'"implement the three steps'* ]]
  [[ "$output" != *'"fix the failing tests'* ]]
  [[ "$output" != *"- lite:"* ]]
  [[ "$output" != *"- full:"* ]]
  [[ "$output" != *"- max:"* ]]
}

@test "lite mode emits only lite examples" {
  echo "lite" > "$CLAUDE_CONFIG_DIR/.peer-agent-active"

  output="$(run_hook)"

  [[ "$output" == *'"find every call site'* ]]
  [[ "$output" != *'"implement the three steps'* ]]
  [[ "$output" != *'"fix the failing tests'* ]]
  [[ "$output" != *"- lite:"* ]]
}

@test "max mode emits examples from all tiers" {
  echo "max" > "$CLAUDE_CONFIG_DIR/.peer-agent-active"

  output="$(run_hook)"

  [[ "$output" == *'"find every call site'* ]]
  [[ "$output" == *'"implement the three steps'* ]]
  [[ "$output" == *'"fix the failing tests'* ]]
  [[ "$output" != *"- max:"* ]]
}

@test "off mode emits nothing and clears the flag" {
  echo "off" > "$CLAUDE_CONFIG_DIR/.peer-agent-active"

  output="$(run_hook)"

  [ -z "$output" ]
  [ ! -f "$CLAUDE_CONFIG_DIR/.peer-agent-active" ]
}

@test "every mode is resolvable from the global flag" {
  for mode in lite full max; do
    echo "$mode" > "$CLAUDE_CONFIG_DIR/.peer-agent-active"

    output="$(run_hook)"

    [[ "$output" == *"PEER_AGENT MODE ACTIVE — level: $mode"* ]]
  done
}

@test "reports the skill path on stderr when SKILL.md is unreadable" {
  echo "full" > "$CLAUDE_CONFIG_DIR/.peer-agent-active"
  export CLAUDE_PLUGIN_ROOT="$HOME/absent"

  output="$(run_hook)"

  [[ "$output" == *"could not read"* ]]
  [[ "$output" == *"SKILL.md"* ]]
}

@test "defaults hookEventName to SessionStart when the input omits it" {
  echo "full" > "$CLAUDE_CONFIG_DIR/.peer-agent-active"

  raw="$(printf '{}' | node "$KIT_DIR/hooks/peer-agent-activate.js")"

  [[ "$raw" == *'"hookEventName":"SessionStart"'* ]]
  [[ "$raw" == *'"additionalContext"'* ]]
}

@test "echoes hook_event_name back so SubagentStart deliveries are accepted" {
  echo "full" > "$CLAUDE_CONFIG_DIR/.peer-agent-active"

  raw="$(printf '{"hook_event_name":"SubagentStart"}' | node "$KIT_DIR/hooks/peer-agent-activate.js")"

  [[ "$raw" == *'"hookEventName":"SubagentStart"'* ]]
  [[ "$raw" == *'"additionalContext"'* ]]
  [[ "$raw" == *"PEER_AGENT MODE ACTIVE"* ]]
}

@test "honors the repo-scoped mode flag via cwd under SubagentStart" {
  echo "full" > "$CLAUDE_CONFIG_DIR/.peer-agent-active"
  repo="$(make_repo max)"

  raw="$(printf '{"cwd":"%s","hook_event_name":"SubagentStart"}' "$repo" | node "$KIT_DIR/hooks/peer-agent-activate.js")"

  [[ "$raw" == *'"hookEventName":"SubagentStart"'* ]]
  [[ "$raw" == *"PEER_AGENT MODE ACTIVE — level: max"* ]]
}
