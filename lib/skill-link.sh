# peer-agent skill link helpers (ADR 0088). Sourced by install.sh and update.sh.
#
# The kit installs its skill as a directory symlink
#   $CLAUDE_DIR/skills/peer-agent -> $KIT_DIR/skills/peer-agent
# so every kit update reaches sessions with no copy step. A skill copy the
# user put in place is never replaced silently: callers warn, and replace it
# only after the user agrees.
#
# PEER_AGENT_KIT_REPLACE_SKILL: 1 = replace a stale copy without asking,
# 0 = never replace it. Unset = ask when stdin is a terminal, else keep it.

# skill_state <skill_dir> <kit_skill_dir>
# Prints one of:
#   missing  nothing exists at <skill_dir>
#   linked   <skill_dir> resolves to <kit_skill_dir>
#   same     a separate copy whose SKILL.md matches the kit's
#   differs  a separate copy whose SKILL.md differs from the kit's, or is absent
skill_state() {
  local dir="$1" src="$2"
  if [ ! -e "$dir" ] && [ ! -L "$dir" ]; then
    echo missing
  elif [ "$(cd -P "$dir" 2>/dev/null && pwd)" = "$(cd -P "$src" && pwd)" ]; then
    echo linked
  elif cmp -s "$dir/SKILL.md" "$src/SKILL.md"; then
    echo same
  else
    echo differs
  fi
}

# skill_link <skill_dir> <kit_skill_dir> — create the symlink.
skill_link() {
  mkdir -p "$(dirname "$1")" && ln -s "$2" "$1"
}

# skill_warn_stale <skill_dir> <kit_skill_dir> — explain the stale copy.
skill_warn_stale() {
  echo "warning: $1/SKILL.md is missing or differs from the kit copy $2/SKILL.md." >&2
  echo "  Sessions get delegation rules that may not match the MCP server." >&2
}

# skill_manual_fix_hint <skill_dir> <kit_skill_dir>
skill_manual_fix_hint() {
  echo "  To use the kit copy: back up $1, remove it, then run: ln -s $2 $1" >&2
}

# skill_confirm_replace <skill_dir> <kit_skill_dir>
# Returns 0 when the stale copy may be replaced with the kit symlink.
skill_confirm_replace() {
  case "${PEER_AGENT_KIT_REPLACE_SKILL:-}" in
    1) return 0 ;;
    0) return 1 ;;
  esac
  [ -t 0 ] || return 1
  printf 'Replace %s with a symlink to %s? The current copy is backed up and restored on uninstall. (Y/n) ' "$1" "$2"
  local answer
  read -r answer || return 1
  case "$answer" in
    n|N|no|NO) return 1 ;;
  esac
  return 0
}

# skill_backup_path — where a replaced copy is kept. Outside ~/.peer-agent-kit
# on purpose: install.sh deletes that directory to clean up an incomplete
# install, and the copy must survive that. One slot: callers never replace
# while it is taken.
skill_backup_path() {
  echo "$HOME/.peer-agent-kit-skill-backup"
}

# skill_backup_taken — returns 0 when the backup slot holds a copy.
skill_backup_taken() {
  local backup
  backup="$(skill_backup_path)"
  [ -e "$backup" ] || [ -L "$backup" ]
}

# skill_replace <skill_dir> <kit_skill_dir> <backup_path>
# Move the copy to <backup_path>, then link the kit copy in its place. The
# caller records <backup_path> in the manifest first, so uninstall.sh can
# restore the copy whichever step fails.
skill_replace() {
  mkdir -p "$(dirname "$3")" && mv "$1" "$3" && ln -s "$2" "$1"
}

# skill_restore_backup <skill_dir> <kit_skill_dir> <backup_path>
# Put a replaced copy back. Only replaces the kit symlink or an empty path;
# a copy the user put there since is kept, and the backup stays for them.
skill_restore_backup() {
  local dir="$1" src="$2" backup="$3"
  [ -e "$backup" ] || [ -L "$backup" ] || return 0
  case "$(skill_state "$dir" "$src")" in
    missing) ;;
    linked)
      if [ ! -L "$dir" ]; then
        echo "warning: $dir is not a symlink — left as is; your earlier skill copy is at $backup" >&2
        return 0
      fi
      rm "$dir"
      ;;
    *)
      echo "warning: $dir is not the kit symlink — left as is; your earlier skill copy is at $backup" >&2
      return 0
      ;;
  esac
  mv "$backup" "$dir" && echo "restored: $dir (pre-install copy)"
}
