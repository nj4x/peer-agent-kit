#!/usr/bin/env bats
# bats-core tests for lib/skill-link.sh (ADR 0088)

setup() {
  export KIT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
  TMP="$(mktemp -d)"
  SRC="$TMP/kit/skills/peer-agent"
  DIR="$TMP/claude/skills/peer-agent"
  mkdir -p "$SRC"
  printf -- '---\nname: peer-agent\n---\nnew rules\n' > "$SRC/SKILL.md"
  unset PEER_AGENT_KIT_REPLACE_SKILL
  . "$KIT_DIR/lib/skill-link.sh"
}

teardown() {
  rm -rf "$TMP"
}

@test "skill_state: nothing at the skill path is missing" {
  [ "$(skill_state "$DIR" "$SRC")" = "missing" ]
}

@test "skill_state: a directory symlink to the kit copy is linked" {
  skill_link "$DIR" "$SRC"
  [ -L "$DIR" ]
  [ "$(skill_state "$DIR" "$SRC")" = "linked" ]
}

@test "skill_state: a copy with the kit's SKILL.md content is same" {
  mkdir -p "$(dirname "$DIR")"
  cp -r "$SRC" "$DIR"
  [ "$(skill_state "$DIR" "$SRC")" = "same" ]
}

@test "skill_state: a copy with older SKILL.md content is differs" {
  mkdir -p "$DIR"
  printf -- '---\nname: peer-agent\n---\nold rules: ask_peer_agent\n' > "$DIR/SKILL.md"
  [ "$(skill_state "$DIR" "$SRC")" = "differs" ]
}

@test "skill_state: a directory without SKILL.md is differs" {
  mkdir -p "$DIR"
  touch "$DIR/.gitkeep"
  [ "$(skill_state "$DIR" "$SRC")" = "differs" ]
}

@test "skill_confirm_replace: PEER_AGENT_KIT_REPLACE_SKILL=1 agrees, 0 refuses" {
  export PEER_AGENT_KIT_REPLACE_SKILL=1
  run skill_confirm_replace "$DIR" "$SRC" </dev/null
  [ "$status" -eq 0 ]
  export PEER_AGENT_KIT_REPLACE_SKILL=0
  run skill_confirm_replace "$DIR" "$SRC" </dev/null
  [ "$status" -ne 0 ]
}

@test "skill_confirm_replace: refuses without a terminal when the variable is unset" {
  run skill_confirm_replace "$DIR" "$SRC" </dev/null
  [ "$status" -ne 0 ]
}

@test "skill_replace: moves the copy to the backup path and links the kit copy" {
  mkdir -p "$DIR"
  echo old > "$DIR/SKILL.md"
  skill_replace "$DIR" "$SRC" "$TMP/backup/skill-peer-agent"
  [ "$(cat "$TMP/backup/skill-peer-agent/SKILL.md")" = "old" ]
  [ "$(skill_state "$DIR" "$SRC")" = "linked" ]
}

@test "skill_restore_backup: replaces the kit symlink with the backup" {
  skill_link "$DIR" "$SRC"
  mkdir -p "$TMP/bak"
  echo old > "$TMP/bak/SKILL.md"
  skill_restore_backup "$DIR" "$SRC" "$TMP/bak"
  [ ! -L "$DIR" ]
  [ "$(cat "$DIR/SKILL.md")" = "old" ]
  [ ! -e "$TMP/bak" ]
}

@test "skill_restore_backup: restores into an empty path" {
  mkdir -p "$TMP/bak" "$(dirname "$DIR")"
  echo old > "$TMP/bak/SKILL.md"
  skill_restore_backup "$DIR" "$SRC" "$TMP/bak"
  [ "$(cat "$DIR/SKILL.md")" = "old" ]
}

@test "skill_restore_backup: keeps a foreign copy and the backup" {
  mkdir -p "$DIR" "$TMP/bak"
  echo mine > "$DIR/SKILL.md"
  echo old > "$TMP/bak/SKILL.md"
  run skill_restore_backup "$DIR" "$SRC" "$TMP/bak"
  [ "$status" -eq 0 ]
  [[ "$output" == *"left as is"* ]]
  [ "$(cat "$DIR/SKILL.md")" = "mine" ]
  [ "$(cat "$TMP/bak/SKILL.md")" = "old" ]
}

@test "skill_restore_backup: no backup is a no-op" {
  skill_link "$DIR" "$SRC"
  skill_restore_backup "$DIR" "$SRC" "$TMP/none"
  [ -L "$DIR" ]
}

@test "kit SKILL.md carries disable-model-invocation, so the symlinked skill needs no patch" {
  grep -q '^disable-model-invocation: true' "$KIT_DIR/skills/peer-agent/SKILL.md"
}
