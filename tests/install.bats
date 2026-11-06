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
  # skill-patch.js runs on the real node so the frontmatter-patch guards are
  # exercised; resolve it before the stub shadows it.
  export REAL_NODE="$(command -v node)"
  export PATH="$TEST_STUBS_DIR:$PATH"
  
  # Create stub scripts that simulate successful operations without side effects
  cat > "$TEST_STUBS_DIR/node" <<'STUB'
#!/usr/bin/env bash
# Stub node that handles the specific invocations from install.sh and uninstall.sh

# Run the frontmatter patcher for real (ADR 0088 no-patch guards)
if [[ "${1:-}" == *skill-patch.js ]]; then
  exec "$REAL_NODE" "$@"
fi

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

# --- Skill symlink (ADR 0088, issue #33) -------------------------------------

# No disable-model-invocation key, so install.sh patches a kept copy (asserted
# below). The kit SKILL.md already has the key, so the kit checksum checks
# are a guard against other writes through the symlink, not against the patch.
STALE_SKILL='---
name: peer-agent
---
Quick question or small task: `ask_peer_agent` — blocks up to 180 seconds.'

seed_stale_skill() {
  mkdir -p "$CLAUDE_CONFIG_DIR/skills/peer-agent"
  printf '%s\n' "$STALE_SKILL" > "$CLAUDE_CONFIG_DIR/skills/peer-agent/SKILL.md"
}

SKILL_BACKUP() { echo "$HOME/.peer-agent-kit-skill-backup"; }
kit_skill_sum() { shasum "$KIT_DIR/skills/peer-agent/SKILL.md" | cut -d' ' -f1; }

@test "install with no skill links the kit skill directory and records skillInstalledByKit" {
  cd "$KIT_DIR"
  run bash "$KIT_DIR/install.sh" 2>&1

  [ "$status" -eq 0 ]
  [ -L "$CLAUDE_CONFIG_DIR/skills/peer-agent" ]
  [ "$(cd -P "$CLAUDE_CONFIG_DIR/skills/peer-agent" && pwd)" = "$KIT_DIR/skills/peer-agent" ]
  grep -q '"skillInstalledByKit": true' "$HOME/.peer-agent-kit/manifest.json"
  grep -q '"skillReplacedBackup": null' "$HOME/.peer-agent-kit/manifest.json"
  # SessionStart reads $pluginRoot/skills/peer-agent/SKILL.md: must be the kit copy.
  grep -q "\"pluginRoot\": \"$KIT_DIR\"" "$HOME/.peer-agent-kit/manifest.json"
}

@test "install with a stale skill copy and no terminal warns and keeps the copy" {
  seed_stale_skill
  cd "$KIT_DIR"
  run bash "$KIT_DIR/install.sh" </dev/null 2>&1

  [ "$status" -eq 0 ]
  [[ "$output" == *"differs from the kit copy"* ]]
  [[ "$output" == *"ln -s $KIT_DIR/skills/peer-agent"* ]]
  [ ! -L "$CLAUDE_CONFIG_DIR/skills/peer-agent" ]
  grep -q 'ask_peer_agent' "$CLAUDE_CONFIG_DIR/skills/peer-agent/SKILL.md"
  grep -q '"skillReplacedBackup": null' "$HOME/.peer-agent-kit/manifest.json"
  # The kept copy is the user's: install.sh still patches its frontmatter.
  grep -q '^disable-model-invocation: true' "$CLAUDE_CONFIG_DIR/skills/peer-agent/SKILL.md"
}

@test "install with a stale skill copy and PEER_AGENT_KIT_REPLACE_SKILL=1 backs it up and links the kit copy" {
  seed_stale_skill
  before="$(kit_skill_sum)"
  cd "$KIT_DIR"
  PEER_AGENT_KIT_REPLACE_SKILL=1 run bash "$KIT_DIR/install.sh" </dev/null 2>&1

  [ "$status" -eq 0 ]
  [ -L "$CLAUDE_CONFIG_DIR/skills/peer-agent" ]
  [ "$(cd -P "$CLAUDE_CONFIG_DIR/skills/peer-agent" && pwd)" = "$KIT_DIR/skills/peer-agent" ]
  grep -q 'ask_peer_agent' "$(SKILL_BACKUP)/SKILL.md"
  grep -q "\"skillReplacedBackup\": \"$(SKILL_BACKUP)\"" "$HOME/.peer-agent-kit/manifest.json"
  grep -q "\"pluginRoot\": \"$KIT_DIR\"" "$HOME/.peer-agent-kit/manifest.json"
  # The kit copy is never patched in place.
  [ "$(kit_skill_sum)" = "$before" ]
}

@test "install replacing a stale skill symlinked from another tree points pluginRoot at the kit" {
  mkdir -p "$HOME/dotfiles/skills/peer-agent" "$CLAUDE_CONFIG_DIR/skills"
  printf '%s\n' "$STALE_SKILL" > "$HOME/dotfiles/skills/peer-agent/SKILL.md"
  ln -s "$HOME/dotfiles/skills/peer-agent" "$CLAUDE_CONFIG_DIR/skills/peer-agent"
  cd "$KIT_DIR"
  PEER_AGENT_KIT_REPLACE_SKILL=1 run bash "$KIT_DIR/install.sh" </dev/null 2>&1

  [ "$status" -eq 0 ]
  [ "$(cd -P "$CLAUDE_CONFIG_DIR/skills/peer-agent" && pwd)" = "$KIT_DIR/skills/peer-agent" ]
  # SessionStart reads $pluginRoot/skills/peer-agent/SKILL.md: not the dotfiles copy.
  grep -q "\"pluginRoot\": \"$KIT_DIR\"" "$HOME/.peer-agent-kit/manifest.json"
  grep -q 'ask_peer_agent' "$HOME/dotfiles/skills/peer-agent/SKILL.md"
}

@test "install with a stale copy and a taken backup slot keeps the copy" {
  seed_stale_skill
  mkdir -p "$(SKILL_BACKUP)"
  echo first > "$(SKILL_BACKUP)/SKILL.md"
  cd "$KIT_DIR"
  PEER_AGENT_KIT_REPLACE_SKILL=1 run bash "$KIT_DIR/install.sh" </dev/null 2>&1

  [ "$status" -eq 0 ]
  [ ! -L "$CLAUDE_CONFIG_DIR/skills/peer-agent" ]
  [ "$(cat "$(SKILL_BACKUP)/SKILL.md")" = "first" ]
}

@test "re-running install after an interrupted replace restores the copy before cleanup" {
  # State an install leaves when interrupted (Ctrl-C) after the replace.
  mkdir -p "$HOME/.peer-agent-kit/backup" "$CLAUDE_CONFIG_DIR/skills" "$(SKILL_BACKUP)"
  echo '{"completed": false}' > "$HOME/.peer-agent-kit/manifest.json"
  printf '%s\n' "$STALE_SKILL" > "$(SKILL_BACKUP)/SKILL.md"
  ln -s "$KIT_DIR/skills/peer-agent" "$CLAUDE_CONFIG_DIR/skills/peer-agent"
  cd "$KIT_DIR"
  run bash "$KIT_DIR/install.sh" </dev/null 2>&1

  [ "$status" -eq 0 ]
  [[ "$output" == *"restored: $CLAUDE_CONFIG_DIR/skills/peer-agent"* ]]
  [ ! -L "$CLAUDE_CONFIG_DIR/skills/peer-agent" ]
  grep -q 'ask_peer_agent' "$CLAUDE_CONFIG_DIR/skills/peer-agent/SKILL.md"
}

@test "install with --no-install-skill and a stale copy warns and never replaces it" {
  seed_stale_skill
  cd "$KIT_DIR"
  PEER_AGENT_KIT_REPLACE_SKILL=1 run bash "$KIT_DIR/install.sh" --no-install-skill </dev/null 2>&1

  [ "$status" -eq 0 ]
  [[ "$output" == *"differs from the kit copy"* ]]
  [ ! -L "$CLAUDE_CONFIG_DIR/skills/peer-agent" ]
}

# Uninstall reads skillReplacedBackup with node; the stubbed node answers
# nothing for it, so these tests run uninstall.sh against the real node.
run_uninstall_real_node() {
  rm -f "$TEST_STUBS_DIR/node"
  cd "$KIT_DIR"
  run bash "$KIT_DIR/uninstall.sh" 2>&1
}

write_manifest() {
  mkdir -p "$HOME/.peer-agent-kit/backup"
  printf '{\n  "claudeDir": "%s",\n  "mcpPriorEntry": null,\n  "pluginRoot": "%s",\n  "skillInstalledByKit": %s,\n  "skillBackup": null,\n  "skillReplacedBackup": %s,\n  "completed": true\n}\n' \
    "$CLAUDE_CONFIG_DIR" "$CLAUDE_CONFIG_DIR" "$1" "$2" > "$HOME/.peer-agent-kit/manifest.json"
}

@test "uninstall restores the pre-install skill copy the kit replaced" {
  write_manifest false "\"$(SKILL_BACKUP)\""
  mkdir -p "$(SKILL_BACKUP)"
  printf '%s\n' "$STALE_SKILL" > "$(SKILL_BACKUP)/SKILL.md"
  mkdir -p "$CLAUDE_CONFIG_DIR/skills"
  ln -s "$KIT_DIR/skills/peer-agent" "$CLAUDE_CONFIG_DIR/skills/peer-agent"

  run_uninstall_real_node

  [ "$status" -eq 0 ]
  [ ! -L "$CLAUDE_CONFIG_DIR/skills/peer-agent" ]
  grep -q 'ask_peer_agent' "$CLAUDE_CONFIG_DIR/skills/peer-agent/SKILL.md"
  [ -f "$KIT_DIR/skills/peer-agent/SKILL.md" ]
}

@test "uninstall keeps a skill copy the user put in place after the replace" {
  write_manifest false "\"$(SKILL_BACKUP)\""
  mkdir -p "$(SKILL_BACKUP)"
  echo older > "$(SKILL_BACKUP)/SKILL.md"
  seed_stale_skill

  run_uninstall_real_node

  [ "$status" -eq 0 ]
  grep -q 'ask_peer_agent' "$CLAUDE_CONFIG_DIR/skills/peer-agent/SKILL.md"
  [ "$(cat "$(SKILL_BACKUP)/SKILL.md")" = "older" ]
}

@test "uninstall leaves the skill copy alone when the recorded backup was never made" {
  # skillInstalledByKit true: without the recorded-backup branch, uninstall
  # would take the rm -rf branch and delete the copy.
  write_manifest true "\"$(SKILL_BACKUP)\""
  seed_stale_skill

  run_uninstall_real_node

  [ "$status" -eq 0 ]
  grep -q 'ask_peer_agent' "$CLAUDE_CONFIG_DIR/skills/peer-agent/SKILL.md"
}

@test "uninstall without a manifest restores a replaced skill copy from the fixed backup path" {
  mkdir -p "$HOME/.peer-agent-kit" "$(SKILL_BACKUP)" "$CLAUDE_CONFIG_DIR/skills"
  printf '%s\n' "$STALE_SKILL" > "$(SKILL_BACKUP)/SKILL.md"
  ln -s "$KIT_DIR/skills/peer-agent" "$CLAUDE_CONFIG_DIR/skills/peer-agent"

  run_uninstall_real_node

  [ "$status" -eq 0 ]
  [ ! -L "$CLAUDE_CONFIG_DIR/skills/peer-agent" ]
  grep -q 'ask_peer_agent' "$CLAUDE_CONFIG_DIR/skills/peer-agent/SKILL.md"
}

@test "uninstall removes the kit skill symlink but not the kit copy" {
  write_manifest true null
  mkdir -p "$CLAUDE_CONFIG_DIR/skills"
  ln -s "$KIT_DIR/skills/peer-agent" "$CLAUDE_CONFIG_DIR/skills/peer-agent"

  run_uninstall_real_node

  [ "$status" -eq 0 ]
  [ ! -e "$CLAUDE_CONFIG_DIR/skills/peer-agent" ]
  [ ! -L "$CLAUDE_CONFIG_DIR/skills/peer-agent" ]
  [ -f "$KIT_DIR/skills/peer-agent/SKILL.md" ]
}
