#!/usr/bin/env bash
# peer-agent-kit in-place update script.
#
# Updates the kit and re-links the peer-agent skill without uninstalling.
# Requires an existing manifest.json (from a prior successful install).
# Patches are idempotent; if no changes detected, exits 0 with "already up to date".
set -euo pipefail

print_help() {
  cat <<EOF
Usage: update.sh [--help]

In-place update for peer-agent-kit. Checks for new commits, repatches settings.json
and statusline.sh, copies updated hook files, and links the peer-agent skill to
the kit copy. A skill copy you installed yourself is replaced only after you
agree (set PEER_AGENT_KIT_REPLACE_SKILL=1 to agree in advance, 0 to refuse).

Requires an existing manifest.json from a prior install. First install still
requires install.sh.

Exit 0 if update succeeds or no new commits found. Non-zero on error.
EOF
}

[ "${1:-}" = "--help" ] && print_help && exit 0

# ===== Setup =====

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KIT_HOME="$HOME/.peer-agent-kit"
MANIFEST="$KIT_HOME/manifest.json"
MCP_CONFIG="$HOME/.claude.json"

fail() {
  echo "[peer-agent-kit] error: $*" >&2
  echo "[peer-agent-kit] Update failed; run again to retry or run uninstall.sh + install.sh to recover" >&2
  exit 1
}

trap 'fail "unexpected error"' ERR

# ===== Manifest check =====

if [ ! -f "$MANIFEST" ]; then
  fail "manifest.json not found at $MANIFEST. First install requires: install.sh"
fi

if ! command -v node >/dev/null 2>&1; then
  fail "node not found on PATH"
fi

if [ ! -d "$KIT_DIR/.git" ]; then
  fail "$KIT_DIR is not a git repository"
fi

# Parse manifest using node -e (no jq per ADR 0080)
parse_manifest() {
  local field="$1"
  node -e "try{const m=JSON.parse(require('fs').readFileSync('$MANIFEST','utf8'));console.log(m.$field??'')}catch(e){console.log('')}"
}

CLAUDE_DIR="$(parse_manifest 'claudeDir')"
[ -z "$CLAUDE_DIR" ] && fail "claudeDir not in manifest"

PLUGIN_ROOT="$(parse_manifest 'pluginRoot')"
[ -z "$PLUGIN_ROOT" ] && fail "pluginRoot not in manifest"

SKILL_INSTALLED_BY_KIT="$(parse_manifest 'skillInstalledByKit')"
[ -z "$SKILL_INSTALLED_BY_KIT" ] && SKILL_INSTALLED_BY_KIT="false"

SKILL_REPLACED_BACKUP="$(parse_manifest 'skillReplacedBackup')"

SETTINGS="$CLAUDE_DIR/settings.json"
STATUSLINE="$CLAUDE_DIR/statusline.sh"
SKILL_DIR="$CLAUDE_DIR/skills/peer-agent"
SKILL_SOURCE="$KIT_DIR/skills/peer-agent"

if [ ! -f "$SETTINGS" ]; then
  fail "settings.json not found at $SETTINGS"
fi

# shellcheck source=lib/skill-link.sh
. "$KIT_DIR/lib/skill-link.sh" || fail "skill-link helper missing"

# manifest_set <key> <value> [<key> <value>...] — atomic string-field write (ADR 0082).
manifest_set() {
  node -e "
const fs = require('fs');
const [manifestPath, ...pairs] = process.argv.slice(1);
const manifest = JSON.parse(fs.readFileSync(manifestPath, 'utf8'));
for (let i = 0; i < pairs.length; i += 2) manifest[pairs[i]] = pairs[i + 1];
const tmpPath = manifestPath + '.tmp';
fs.writeFileSync(tmpPath, JSON.stringify(manifest, null, 2) + '\n');
fs.renameSync(tmpPath, manifestPath);
" "$MANIFEST" "$@"
}

# Bring the installed skill in line with the kit copy (ADR 0088). Runs on
# every update, the up-to-date case included, because a stale copy can sit
# behind a current kitSha. When it links the kit copy in, it also points
# pluginRoot at the kit (the old value may lead through the replaced link to
# another tree) and sets SKILL_RELINKED=1 so the caller repatches settings.json.
SKILL_RELINKED=0
sync_skill() {
  local state kit_root
  state="$(skill_state "$SKILL_DIR" "$SKILL_SOURCE")"
  [ "$state" = "linked" ] && return 0
  kit_root="$(cd -P "$KIT_DIR" && pwd)"

  # A kit-installed copy equals SKILL.md as of the previous kitSha, not the
  # freshly pulled one: compare against the old version, or every pull that
  # edits SKILL.md would send the kit's own copy down the consent path.
  if [ "$state" = "differs" ] && [ "$SKILL_INSTALLED_BY_KIT" = "true" ] && [ "$CURRENT_KIT_SHA" != "none" ] \
    && cmp -s "$SKILL_DIR/SKILL.md" <(git -C "$KIT_DIR" show "$CURRENT_KIT_SHA:skills/peer-agent/SKILL.md" 2>/dev/null); then
    state="same"
  fi

  # A copy the kit installed (older installs used cp -r) becomes the symlink
  # without asking, but only when nothing the user wrote can be lost: an
  # identical copy, or nothing at all. skillInstalledByKit cannot tell a kit
  # copy from one the user edited or put there since, so a differing copy
  # takes the consent-and-backup path below.
  if [ "$SKILL_INSTALLED_BY_KIT" = "true" ] && { [ "$state" = "same" ] || [ "$state" = "missing" ]; }; then
    echo "[peer-agent-kit] Linking peer-agent skill to $SKILL_SOURCE..."
    manifest_set pluginRoot "$kit_root" || fail "manifest update failed"
    PLUGIN_ROOT="$kit_root"
    rm -rf "$SKILL_DIR"
    skill_link "$SKILL_DIR" "$SKILL_SOURCE" || fail "could not link the peer-agent skill"
    SKILL_RELINKED=1
    return 0
  fi

  case "$state" in
    same) return 0 ;;
    missing)
      echo "[peer-agent-kit] warning: peer-agent skill not found at $SKILL_DIR — run: ln -s $SKILL_SOURCE $SKILL_DIR" >&2
      return 0
      ;;
  esac

  # A copy the user installed: replace only after they agree. One backup
  # slot: when it is taken, the user fixes the copy by hand.
  local backup
  backup="$(skill_backup_path)"
  skill_warn_stale "$SKILL_DIR" "$SKILL_SOURCE"
  if [ -n "$SKILL_REPLACED_BACKUP" ] || skill_backup_taken \
    || ! skill_confirm_replace "$SKILL_DIR" "$SKILL_SOURCE"; then
    skill_manual_fix_hint "$SKILL_DIR" "$SKILL_SOURCE"
    return 0
  fi
  # Record the backup path first, so uninstall.sh can restore the copy
  # whichever step below fails.
  manifest_set skillReplacedBackup "$backup" pluginRoot "$kit_root" || fail "manifest update failed"
  SKILL_REPLACED_BACKUP="$backup"
  PLUGIN_ROOT="$kit_root"
  echo "[peer-agent-kit] Replacing $SKILL_DIR with a symlink to $SKILL_SOURCE (backup: $backup)..."
  skill_replace "$SKILL_DIR" "$SKILL_SOURCE" "$backup" || fail "could not replace the peer-agent skill"
  SKILL_RELINKED=1
}

# ===== Git check and fetch =====

cd "$KIT_DIR"

echo "[peer-agent-kit] Fetching remote updates..."
git fetch origin || fail "git fetch failed"

# Detect default branch (main for this repo)
REMOTE_HEAD="$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|.*/||' || echo 'main')"
REMOTE_SHA="$(git rev-parse "origin/$REMOTE_HEAD" 2>/dev/null || fail "could not resolve origin branch")"

# Parse current kitSha from manifest (may be absent for old installs)
CURRENT_KIT_SHA="$(parse_manifest 'kitSha')"
[ -z "$CURRENT_KIT_SHA" ] && CURRENT_KIT_SHA="none"

if [ "$REMOTE_SHA" = "$CURRENT_KIT_SHA" ]; then
  echo "[peer-agent-kit] Kit is already up to date (SHA: $REMOTE_SHA)"
  sync_skill
  if [ "$SKILL_RELINKED" = "1" ]; then
    echo "[peer-agent-kit] Repatching settings.json for the new pluginRoot..."
    node "$KIT_DIR/lib/settings-patch.js" "$SETTINGS" "$KIT_HOME/hooks" "$PLUGIN_ROOT" || fail "settings repatch failed"
  fi
  exit 0
fi

if [ "$CURRENT_KIT_SHA" = "none" ]; then
  echo "[peer-agent-kit] Initial update detected (no prior kitSha in manifest)"
else
  echo "[peer-agent-kit] New commits available ($CURRENT_KIT_SHA → $REMOTE_SHA)"
fi

# ===== Unpatch =====

echo "[peer-agent-kit] Unpatching settings.json..."
node "$KIT_DIR/lib/settings-unpatch.js" "$SETTINGS" || fail "settings unpatch failed"

if [ -f "$STATUSLINE" ] && [ ! -L "$STATUSLINE" ]; then
  echo "[peer-agent-kit] Unpatching statusline.sh..."
  node "$KIT_DIR/lib/statusline-unpatch.js" "$STATUSLINE" || fail "statusline unpatch failed"
fi

echo "[peer-agent-kit] Unpatching MCP config..."
node "$KIT_DIR/lib/mcp-unpatch.js" "$MCP_CONFIG" "$MANIFEST" || fail "MCP unpatch failed"

# ===== Update kit files =====

echo "[peer-agent-kit] Pulling latest kit..."
git -C "$KIT_DIR" pull origin "$REMOTE_HEAD" --ff-only || fail "git pull failed — surfaces left unpatched; resolve git divergence and re-run"

# ===== Extension rebuild (ADR 0084) =====

echo "[peer-agent-kit] Rebuilding VS Code extension..."
cd "$KIT_DIR/extension"
npm ci --no-fund --no-audit </dev/null 2>/dev/null || fail "extension npm ci failed"
npm run install-dev </dev/null 2>/dev/null || fail "extension install-dev failed"
cd "$KIT_DIR"

# ===== Sync Python env =====

echo "[peer-agent-kit] Syncing Python environment..."
uv sync --directory "$KIT_DIR/mcp/vscode-agent-bridge" || fail "uv sync failed"

# ===== Copy hook files =====

echo "[peer-agent-kit] Copying hook files..."
cp "$KIT_DIR"/hooks/*.js "$KIT_HOME/hooks/" || fail "could not copy hook scripts"

# ===== Sync Cline hook files =====

if [ -d "$HOME/Documents/Cline/Hooks" ]; then
  echo "[peer-agent-kit] Syncing Cline hook files..."
  for hook_template in "$KIT_DIR/extension/hooks/"*; do
    hook_name="$(basename "$hook_template")"
    target="$HOME/Documents/Cline/Hooks/$hook_name"
    if [ -f "$target" ]; then
      # Check if target contains the bridge marker (line-anchored to avoid false positives)
      if ! grep -q "^# vscode-agent-bridge hook" "$target" 2>/dev/null; then
        echo "[peer-agent-kit] warning: skipping $hook_name — does not contain bridge marker" >&2
        continue
      fi
    fi
    cp "$hook_template" "$target"
    chmod +x "$target" 2>/dev/null || true
  done
fi

# ===== Skill update =====

# Before the settings repatch: sync_skill may move pluginRoot to the kit.
# The symlinked kit copy already carries the frontmatter key, so no
# skill-patch.js run: it would write into the kit's git tree.
sync_skill

# ===== Repatch =====

# Sourced after git pull so the freshly pulled helper is used.
# shellcheck source=lib/code-bin.sh
. "$KIT_DIR/lib/code-bin.sh" || fail "code-bin helper missing"
# Re-source the skill helpers too, so the skill step below uses the pulled version.
# shellcheck source=lib/skill-link.sh
. "$KIT_DIR/lib/skill-link.sh" || fail "skill-link helper missing"
CODE_BIN="$(resolve_code_bin || true)"

echo "[peer-agent-kit] Repatching MCP config..."
node "$KIT_DIR/lib/mcp-patch.js" "$MCP_CONFIG" "$KIT_DIR" "$CODE_BIN" || fail "MCP repatch failed"

echo "[peer-agent-kit] Repatching settings.json..."
node "$KIT_DIR/lib/settings-patch.js" "$SETTINGS" "$KIT_HOME/hooks" "$PLUGIN_ROOT" || fail "settings repatch failed"

if [ -f "$STATUSLINE" ] && [ ! -L "$STATUSLINE" ]; then
  echo "[peer-agent-kit] Repatching statusline.sh..."
  node "$KIT_DIR/lib/statusline-patch.js" "$STATUSLINE" || fail "statusline repatch failed"
fi

# ===== Update manifest atomically (ADR 0082) =====

NEW_SHA="$(git -C "$KIT_DIR" rev-parse HEAD)"

echo "[peer-agent-kit] Updating manifest..."
manifest_set kitSha "$NEW_SHA" || fail "manifest update failed"

echo
echo "[peer-agent-kit] peer-agent-kit updated to $(git -C "$KIT_DIR" rev-parse HEAD | cut -c1-8)"
echo "Restart Claude Code for the updates to take effect."
