#!/usr/bin/env bash
# peer-agent-kit uninstaller.
#
# Restores settings.json and statusline.sh from the exact backups install.sh
# made, then removes ~/.peer-agent-kit. Byte-exact restore, not a surgical diff —
# simpler and safer than trying to reverse-parse what was injected.
set -euo pipefail

KIT_HOME="$HOME/.peer-agent-kit"
MANIFEST="$KIT_HOME/manifest.json"

if [ ! -d "$KIT_HOME" ]; then
  echo "error: peer-agent-kit is not installed ($KIT_HOME not found)" >&2
  exit 1
fi

if ! command -v node >/dev/null 2>&1; then
  echo "error: node not found on PATH" >&2
  exit 1
fi

if [ ! -f "$MANIFEST" ]; then
  echo "error: $MANIFEST missing — cannot determine what to restore." >&2
  echo "Remove $KIT_HOME manually and revert settings.json/statusline.sh by hand." >&2
  exit 1
fi

CLAUDE_DIR="$(node -e "console.log(JSON.parse(require('fs').readFileSync('$MANIFEST','utf8')).claudeDir)")"
SETTINGS_BACKUP="$(node -e "console.log(JSON.parse(require('fs').readFileSync('$MANIFEST','utf8')).settingsBackup)")"
STATUSLINE_BACKUP="$(node -e "const m=JSON.parse(require('fs').readFileSync('$MANIFEST','utf8')); console.log(m.statuslineBackup || '')")"
SKILL_INSTALLED_BY_KIT="$(node -e "const m=JSON.parse(require('fs').readFileSync('$MANIFEST','utf8')); console.log(m.skillInstalledByKit === true ? 'true' : 'false')")"
SKILL_BACKUP="$(node -e "const m=JSON.parse(require('fs').readFileSync('$MANIFEST','utf8')); console.log(m.skillBackup || '')")"

SETTINGS="$CLAUDE_DIR/settings.json"
STATUSLINE="$CLAUDE_DIR/statusline.sh"

if [ ! -f "$SETTINGS_BACKUP" ]; then
  echo "error: settings backup not found at $SETTINGS_BACKUP" >&2
  exit 1
fi
cp "$SETTINGS_BACKUP" "$SETTINGS"
echo "restored: $SETTINGS"

if [ -n "$STATUSLINE_BACKUP" ]; then
  if [ -f "$STATUSLINE_BACKUP" ]; then
    cp "$STATUSLINE_BACKUP" "$STATUSLINE"
    echo "restored: $STATUSLINE"
  else
    echo "warning: statusline backup recorded but missing at $STATUSLINE_BACKUP — left $STATUSLINE untouched" >&2
  fi
fi

# Skill cleanup (ADR 0002/0003): remove entirely if the kit installed it;
# otherwise restore the pre-patch backup and leave the skill in place.
SKILL_DIR="$CLAUDE_DIR/skills/peer-agent"
if [ "$SKILL_INSTALLED_BY_KIT" = "true" ]; then
  rm -rf "$SKILL_DIR"
  echo "removed: $SKILL_DIR (installed by peer-agent-kit)"
elif [ -n "$SKILL_BACKUP" ]; then
  if [ -f "$SKILL_BACKUP" ] && [ -d "$SKILL_DIR" ]; then
    if cp "$SKILL_BACKUP" "$SKILL_DIR/SKILL.md"; then
      echo "restored: $SKILL_DIR/SKILL.md"
    else
      echo "warning: failed to restore $SKILL_DIR/SKILL.md from backup — left as-is" >&2
    fi
  elif [ ! -d "$SKILL_DIR" ]; then
    echo "warning: $SKILL_DIR no longer exists — skipping SKILL.md restore" >&2
  else
    echo "warning: skill backup recorded but missing at $SKILL_BACKUP — left SKILL.md untouched" >&2
  fi
fi

rm -rf "$KIT_HOME"
echo "removed: $KIT_HOME"
echo
echo "peer-agent-kit uninstalled. Restart Claude Code."
