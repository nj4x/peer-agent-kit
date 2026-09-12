#!/usr/bin/env bats
# bats-core tests for lib/code-bin.sh resolve_code_bin

setup() {
  export HOME="$(mktemp -d)"
  export KIT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
  export STUB_DIR="$HOME/stubs"
  mkdir -p "$STUB_DIR"
  # Strip any real `code` from PATH so fallback probing is deterministic.
  export PATH="$STUB_DIR:/usr/bin:/bin"
  export CODE_BIN_FALLBACKS="$HOME/nowhere/code"
}

teardown() {
  rm -rf "$HOME"
}

resolve() {
  bash -euo pipefail -c ". '$KIT_DIR/lib/code-bin.sh'; resolve_code_bin"
}

@test "finds code on PATH" {
  printf '#!/usr/bin/env bash\nexit 0\n' > "$STUB_DIR/code"
  chmod +x "$STUB_DIR/code"
  run resolve
  [ "$status" -eq 0 ]
  [ "$output" = "$STUB_DIR/code" ]
}

@test "falls back to CODE_BIN_FALLBACKS when not on PATH" {
  mkdir -p "$HOME/Fake App.app/bin"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$HOME/Fake App.app/bin/code"
  chmod +x "$HOME/Fake App.app/bin/code"
  export CODE_BIN_FALLBACKS="$HOME/nowhere/code:$HOME/Fake App.app/bin/code"
  run resolve
  [ "$status" -eq 0 ]
  [ "$output" = "$HOME/Fake App.app/bin/code" ]
}

@test "non-executable fallback candidate is skipped" {
  mkdir -p "$HOME/x"
  : > "$HOME/x/code"
  export CODE_BIN_FALLBACKS="$HOME/x/code"
  run resolve
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "returns non-zero and prints nothing when nothing found" {
  run resolve
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "default CODE_BIN_FALLBACKS includes the macOS app bundle path" {
  run bash -c "unset CODE_BIN_FALLBACKS; . '$KIT_DIR/lib/code-bin.sh'; printf '%s' \"\$CODE_BIN_FALLBACKS\""
  [ "$status" -eq 0 ]
  [[ "$output" == *"/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code"* ]]
}

@test "command -v code resolving to a relative path is rejected" {
  mkdir -p "$STUB_DIR/relsub"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$STUB_DIR/relsub/code"
  chmod +x "$STUB_DIR/relsub/code"
  export PATH="relsub:$PATH"
  cd "$STUB_DIR"
  run resolve
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "CODE_BIN='\$(resolve_code_bin || true)' is empty under set -euo pipefail when nothing found" {
  run bash -euo pipefail -c ". '$KIT_DIR/lib/code-bin.sh'; CODE_BIN=\"\$(resolve_code_bin || true)\"; echo \"[\$CODE_BIN]\""
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
}
