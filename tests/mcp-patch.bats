#!/usr/bin/env bats
# bats-core tests for lib/mcp-patch.js

setup() {
  export HOME="$(mktemp -d)"
  export KIT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
  export CONFIG="$HOME/.claude.json"
  echo '{"mcpServers":{}}' > "$CONFIG"
}

teardown() {
  rm -rf "$HOME"
}

entry() {
  node -e "const c=require('$CONFIG');console.log(JSON.stringify(c.mcpServers['vscode-agent-bridge'].$1 ?? null))"
}

@test "without code-bin arg writes no env block" {
  run node "$KIT_DIR/lib/mcp-patch.js" "$CONFIG" "$KIT_DIR"
  [ "$status" -eq 0 ]
  [ "$(entry env)" = "null" ]
}

@test "with empty code-bin arg writes no env block" {
  run node "$KIT_DIR/lib/mcp-patch.js" "$CONFIG" "$KIT_DIR" ""
  [ "$status" -eq 0 ]
  [ "$(entry env)" = "null" ]
}

@test "with code-bin arg writes env.BRIDGE_CODE_BIN" {
  run node "$KIT_DIR/lib/mcp-patch.js" "$CONFIG" "$KIT_DIR" "/x/code"
  [ "$status" -eq 0 ]
  [ "$(entry env.BRIDGE_CODE_BIN)" = '"/x/code"' ]
}

@test "re-run with a code-bin arg repoints an entry that lacked env" {
  node "$KIT_DIR/lib/mcp-patch.js" "$CONFIG" "$KIT_DIR"
  run node "$KIT_DIR/lib/mcp-patch.js" "$CONFIG" "$KIT_DIR" "/x/code"
  [ "$status" -eq 0 ]
  [[ "$output" == *"repointing"* ]]
  [ "$(entry env.BRIDGE_CODE_BIN)" = '"/x/code"' ]
}
