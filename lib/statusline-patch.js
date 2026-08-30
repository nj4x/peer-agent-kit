#!/usr/bin/env node
// peer-agent-kit — inserts a peer-agent-mode badge block into an existing
// statusline.sh, right before its last output line, wrapped in sentinel
// comments. Idempotent: skips if the block is already present. Uninstall
// removes the block surgically via statusline-unpatch.js, so patches from
// other kits and later user edits survive.
'use strict';

const fs = require('fs');

const BEGIN = '# PEER_AGENT-KIT BEGIN';
const END = '# PEER_AGENT-KIT END';

const BLOCK = [
  BEGIN,
  'PEER_AGENT_FLAG="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/.peer-agent-active"',
  '# Repo flag wins only when its file exists; a bare .claude/ dir must not',
  '# shadow the global flag (ADR 0004 decision 6).',
  'PEER_AGENT_DIR="$PWD"',
  'while [ "$PEER_AGENT_DIR" != "/" ]; do',
  '  if [ -e "$PEER_AGENT_DIR/.git" ]; then',
  '    if [ -f "$PEER_AGENT_DIR/.claude/.peer-agent-mode" ]; then',
  '      PEER_AGENT_FLAG="$PEER_AGENT_DIR/.claude/.peer-agent-mode"',
  '    fi',
  '    break',
  '  fi',
  '  PEER_AGENT_DIR="$(dirname "$PEER_AGENT_DIR")"',
  'done',
  'if [ -f "$PEER_AGENT_FLAG" ] && [ ! -L "$PEER_AGENT_FLAG" ]; then',
  "  PEER_AGENT_MODE=$(head -c 16 \"$PEER_AGENT_FLAG\" 2>/dev/null | tr -d '\\n\\r' | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9-')",
  '  case "$PEER_AGENT_MODE" in',
  '    lite|full|max)',
  '      if [ "$PEER_AGENT_MODE" = "full" ]; then',
  "        printf '[CLINE] '",
  '      else',
  "        CLINE_SUFFIX=$(printf '%s' \"$PEER_AGENT_MODE\" | tr '[:lower:]' '[:upper:]')",
  "        printf '[CLINE:%s] ' \"$CLINE_SUFFIX\"",
  '      fi',
  '      ;;',
  '  esac',
  'fi',
  END
].join('\n');

const filePath = process.argv[2];
if (!filePath) {
  console.error('usage: statusline-patch.js <statusline.sh>');
  process.exit(1);
}

const content = fs.readFileSync(filePath, 'utf8');

if (content.includes(BEGIN)) {
  console.log('statusline already patched, skipping');
  process.exit(0);
}

const lines = content.split('\n');
// Skip trailing blank lines to find the real last output line.
let lastIdx = lines.length - 1;
while (lastIdx > 0 && lines[lastIdx].trim() === '') lastIdx--;

const before = lines.slice(0, lastIdx);
const lastLine = lines[lastIdx];
const after = lines.slice(lastIdx + 1);

const patched = [...before, BLOCK, lastLine, ...after].join('\n');
fs.writeFileSync(filePath, patched);
fs.chmodSync(filePath, 0o755);
console.log('statusline patched');
