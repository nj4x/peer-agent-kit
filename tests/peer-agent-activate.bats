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

# Runs the hook with the given cwd on stdin. No cwd argument means no stdin
# payload, which exercises the global-flag fallback path.
run_hook() {
  if [ "$#" -eq 0 ]; then
    printf '{}' | node "$KIT_DIR/hooks/peer-agent-activate.js" 2>&1
  else
    printf '{"cwd":"%s"}' "$1" | node "$KIT_DIR/hooks/peer-agent-activate.js" 2>&1
  fi
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
