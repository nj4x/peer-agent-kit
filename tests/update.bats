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
  show)
    # git show <sha>:skills/peer-agent/SKILL.md - old kit version, if the test sets one
    if [[ -n "${FAKE_OLD_SKILL:-}" && -f "$FAKE_OLD_SKILL" ]]; then
      cat "$FAKE_OLD_SKILL"
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

  # MCP entry carries the resolved `code` path (the stub on PATH) for the runtime bridge
  grep -q "\"BRIDGE_CODE_BIN\": \"$KIT_DIR/tests/stubs/code\"" "$HOME/.claude.json"
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

# --- Skill symlink (ADR 0088, issue #33) -------------------------------------

# write_manifest <skillInstalledByKit> <kitSha>
write_manifest() {
  mkdir -p "$HOME/.peer-agent-kit"
  printf '{\n  "claudeDir": "%s",\n  "mcpPriorEntry": null,\n  "pluginRoot": "%s",\n  "skillInstalledByKit": %s,\n  "skillBackup": null,\n  "kitSha": "%s",\n  "completed": true\n}\n' \
    "$CLAUDE_CONFIG_DIR" "$CLAUDE_CONFIG_DIR" "$1" "$2" > "$HOME/.peer-agent-kit/manifest.json"
}

seed_stale_skill() {
  mkdir -p "$CLAUDE_CONFIG_DIR/skills/peer-agent"
  printf -- '---\nname: peer-agent\n---\nQuick question or small task: `ask_peer_agent`\n' \
    > "$CLAUDE_CONFIG_DIR/skills/peer-agent/SKILL.md"
}

SKILL_BACKUP() { echo "$HOME/.peer-agent-kit-skill-backup"; }
kit_skill_sum() { shasum "$KIT_DIR/skills/peer-agent/SKILL.md" | cut -d' ' -f1; }

skill_is_kit_link() {
  [ -L "$CLAUDE_CONFIG_DIR/skills/peer-agent" ] \
    && [ "$(cd -P "$CLAUDE_CONFIG_DIR/skills/peer-agent" && pwd)" = "$KIT_DIR/skills/peer-agent" ]
}

UP_TO_DATE=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
BEHIND=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb

@test "up-to-date kit with a stale user skill copy still warns about it" {
  write_manifest false "$UP_TO_DATE"
  seed_stale_skill
  cd "$KIT_DIR"
  run bash "$KIT_DIR/update.sh" </dev/null 2>&1

  [ "$status" -eq 0 ]
  [[ "$output" == *"Kit is already up to date"* ]]
  [[ "$output" == *"differs from the kit copy"* ]]
  run skill_is_kit_link
  [ "$status" -ne 0 ]
}

@test "kit-installed skill copy from an older install becomes the kit symlink" {
  write_manifest true "$BEHIND"
  mkdir -p "$CLAUDE_CONFIG_DIR/skills"
  cp -r "$KIT_DIR/skills/peer-agent" "$CLAUDE_CONFIG_DIR/skills/peer-agent"
  before="$(kit_skill_sum)"
  cd "$KIT_DIR"
  run bash "$KIT_DIR/update.sh" </dev/null 2>&1

  [ "$status" -eq 0 ]
  skill_is_kit_link
  [ "$(kit_skill_sum)" = "$before" ]
  grep -q "\"pluginRoot\": \"$KIT_DIR\"" "$HOME/.peer-agent-kit/manifest.json"
  grep -q "CLAUDE_PLUGIN_ROOT='$KIT_DIR'" "$CLAUDE_CONFIG_DIR/settings.json"
}

@test "stale user skill copy with PEER_AGENT_KIT_REPLACE_SKILL=1 is backed up, recorded, and linked" {
  write_manifest false "$BEHIND"
  seed_stale_skill
  cd "$KIT_DIR"
  PEER_AGENT_KIT_REPLACE_SKILL=1 run bash "$KIT_DIR/update.sh" </dev/null 2>&1

  [ "$status" -eq 0 ]
  skill_is_kit_link
  grep -q 'ask_peer_agent' "$(SKILL_BACKUP)/SKILL.md"
  grep -q "\"skillReplacedBackup\": \"$(SKILL_BACKUP)\"" "$HOME/.peer-agent-kit/manifest.json"
  grep -q "\"kitSha\": \"$UP_TO_DATE\"" "$HOME/.peer-agent-kit/manifest.json"
  grep -q "\"pluginRoot\": \"$KIT_DIR\"" "$HOME/.peer-agent-kit/manifest.json"
  grep -q "CLAUDE_PLUGIN_ROOT='$KIT_DIR'" "$CLAUDE_CONFIG_DIR/settings.json"
}

@test "up-to-date kit: replacing a stale copy symlinked from another tree repoints settings.json at the kit" {
  write_manifest false "$UP_TO_DATE"
  mkdir -p "$HOME/dotfiles/skills/peer-agent" "$CLAUDE_CONFIG_DIR/skills"
  printf -- '---\nname: peer-agent\n---\nold `ask_peer_agent`\n' > "$HOME/dotfiles/skills/peer-agent/SKILL.md"
  ln -s "$HOME/dotfiles/skills/peer-agent" "$CLAUDE_CONFIG_DIR/skills/peer-agent"
  node "$KIT_DIR/lib/settings-patch.js" "$CLAUDE_CONFIG_DIR/settings.json" "$HOME/.peer-agent-kit/hooks" "$HOME/dotfiles"
  cd "$KIT_DIR"
  PEER_AGENT_KIT_REPLACE_SKILL=1 run bash "$KIT_DIR/update.sh" </dev/null 2>&1

  [ "$status" -eq 0 ]
  skill_is_kit_link
  grep -q "\"pluginRoot\": \"$KIT_DIR\"" "$HOME/.peer-agent-kit/manifest.json"
  grep -q "CLAUDE_PLUGIN_ROOT='$KIT_DIR'" "$CLAUDE_CONFIG_DIR/settings.json"
  ! grep -q "CLAUDE_PLUGIN_ROOT='$HOME/dotfiles'" "$CLAUDE_CONFIG_DIR/settings.json" || false
  grep -q 'ask_peer_agent' "$HOME/dotfiles/skills/peer-agent/SKILL.md"
}

@test "stale user skill copy is not replaced when a replaced-skill backup already exists" {
  write_manifest false "$UP_TO_DATE"
  seed_stale_skill
  mkdir -p "$(SKILL_BACKUP)"
  echo first > "$(SKILL_BACKUP)/SKILL.md"
  cd "$KIT_DIR"
  PEER_AGENT_KIT_REPLACE_SKILL=1 run bash "$KIT_DIR/update.sh" </dev/null 2>&1

  [ "$status" -eq 0 ]
  [[ "$output" == *"ln -s $KIT_DIR/skills/peer-agent"* ]]
  run skill_is_kit_link
  [ "$status" -ne 0 ]
  [ "$(cat "$(SKILL_BACKUP)/SKILL.md")" = "first" ]
}

@test "kit-installed copy equal to the previous kit version becomes the symlink without a prompt" {
  write_manifest true "$BEHIND"
  # The pull changed SKILL.md: the copy matches the old version, not the new one.
  export FAKE_OLD_SKILL="$HOME/old-skill.md"
  printf -- '---\nname: peer-agent\n---\nold kit rules\n' > "$FAKE_OLD_SKILL"
  mkdir -p "$CLAUDE_CONFIG_DIR/skills/peer-agent"
  cp "$FAKE_OLD_SKILL" "$CLAUDE_CONFIG_DIR/skills/peer-agent/SKILL.md"
  cd "$KIT_DIR"
  run bash "$KIT_DIR/update.sh" </dev/null 2>&1

  [ "$status" -eq 0 ]
  skill_is_kit_link
  [[ "$output" != *"differs from the kit copy"* ]]
  grep -q "CLAUDE_PLUGIN_ROOT='$KIT_DIR'" "$CLAUDE_CONFIG_DIR/settings.json"
}

@test "kit-installed flag with a differing copy never deletes it without consent" {
  write_manifest true "$BEHIND"
  seed_stale_skill
  cd "$KIT_DIR"
  run bash "$KIT_DIR/update.sh" </dev/null 2>&1

  [ "$status" -eq 0 ]
  [[ "$output" == *"differs from the kit copy"* ]]
  run skill_is_kit_link
  [ "$status" -ne 0 ]
  grep -q 'ask_peer_agent' "$CLAUDE_CONFIG_DIR/skills/peer-agent/SKILL.md"
}

@test "kit-installed flag with a differing copy and PEER_AGENT_KIT_REPLACE_SKILL=1 backs the copy up" {
  write_manifest true "$BEHIND"
  seed_stale_skill
  cd "$KIT_DIR"
  PEER_AGENT_KIT_REPLACE_SKILL=1 run bash "$KIT_DIR/update.sh" </dev/null 2>&1

  [ "$status" -eq 0 ]
  skill_is_kit_link
  grep -q 'ask_peer_agent' "$(SKILL_BACKUP)/SKILL.md"
}

@test "stale copy is not replaced when the manifest already records a replaced-skill backup" {
  write_manifest false "$UP_TO_DATE"
  node -e "const fs=require('fs');const p=process.argv[1];const m=JSON.parse(fs.readFileSync(p,'utf8'));m.skillReplacedBackup=process.argv[2];fs.writeFileSync(p,JSON.stringify(m))" \
    "$HOME/.peer-agent-kit/manifest.json" "$HOME/elsewhere"
  seed_stale_skill
  cd "$KIT_DIR"
  PEER_AGENT_KIT_REPLACE_SKILL=1 run bash "$KIT_DIR/update.sh" </dev/null 2>&1

  [ "$status" -eq 0 ]
  [[ "$output" == *"ln -s $KIT_DIR/skills/peer-agent"* ]]
  run skill_is_kit_link
  [ "$status" -ne 0 ]
  [ ! -e "$(SKILL_BACKUP)" ]
}

@test "kit skill symlink is left as is" {
  write_manifest true "$BEHIND"
  mkdir -p "$CLAUDE_CONFIG_DIR/skills"
  ln -s "$KIT_DIR/skills/peer-agent" "$CLAUDE_CONFIG_DIR/skills/peer-agent"
  cd "$KIT_DIR"
  run bash "$KIT_DIR/update.sh" </dev/null 2>&1

  [ "$status" -eq 0 ]
  skill_is_kit_link
  [[ "$output" != *"differs from the kit copy"* ]]
  [[ "$output" != *"Linking peer-agent skill"* ]]
}
