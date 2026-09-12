#!/usr/bin/env bats
# bats-core tests for hooks/peer-agent-parse.js parseModeChange.
#
# ADR 0004: 'off' is a real mode value, set the same way as lite/full/max —
# parseModeChange returns the mode to set (or null), never a delete signal.

setup() {
  export KIT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
  unset PEER_AGENT_DEFAULT_MODE
}

parse() {
  node -e "
    const { parseModeChange } = require('$KIT_DIR/hooks/peer-agent-parse');
    const r = parseModeChange(process.argv[1]);
    process.stdout.write(JSON.stringify(r));
  " "$1"
}

@test "/peer-agent off returns off" {
  run parse "/peer-agent off"
  [ "$status" -eq 0 ]
  [ "$output" = '"off"' ]
}

@test "/peer-agent stop returns off" {
  run parse "/peer-agent stop"
  [ "$output" = '"off"' ]
}

@test "/peer-agent disable returns off" {
  run parse "/peer-agent disable"
  [ "$output" = '"off"' ]
}

@test "/peer-agent lite returns lite" {
  run parse "/peer-agent lite"
  [ "$output" = '"lite"' ]
}

@test "/peer-agent full returns full" {
  run parse "/peer-agent full"
  [ "$output" = '"full"' ]
}

@test "/peer-agent max returns max" {
  run parse "/peer-agent max"
  [ "$output" = '"max"' ]
}

@test "natural language: stop the peer-agent returns off" {
  run parse "stop the peer-agent"
  [ "$output" = '"off"' ]
}

@test "natural language: turn off peer-agent returns off" {
  run parse "turn off peer-agent"
  [ "$output" = '"off"' ]
}

@test "natural language: please stop delegating returns off" {
  run parse "please stop delegating"
  [ "$output" = '"off"' ]
}

@test "bare /peer-agent with no arg returns the install default mode" {
  run parse "/peer-agent"
  [ "$output" = '"full"' ]
}

@test "bare /peer-agent with no arg returns off when the install default is off" {
  export PEER_AGENT_DEFAULT_MODE=off
  run parse "/peer-agent"
  [ "$output" = '"off"' ]
}

@test "unknown level leaves the flag untouched" {
  run parse "/peer-agent bogus"
  [ "$output" = 'null' ]
}

@test "unrelated slash command is not mistaken for /peer-agent" {
  run parse "/peer-agent-foo off"
  [ "$output" = 'null' ]
}
