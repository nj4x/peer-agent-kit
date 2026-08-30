#!/usr/bin/env node
// peer-agent-kit — surgically removes the peer-agent badge block from
// statusline.sh by matching sentinel markers. This is the inverse of
// statusline-patch.js, using marker-based removal instead of byte-exact
// restore from backup.
'use strict';

const fs = require('fs');

const [, , statuslinePath] = process.argv;
if (!statuslinePath) {
  console.error('usage: statusline-unpatch.js <statusline.sh>');
  process.exit(1);
}

const BEGIN = '# PEER_AGENT-KIT BEGIN';
const END = '# PEER_AGENT-KIT END';

let content;
try {
  content = fs.readFileSync(statuslinePath, 'utf8');
} catch (e) {
  console.error(`error: cannot read ${statuslinePath}: ${e.message}`);
  process.exit(1);
}

if (!content.includes(BEGIN)) {
  console.log('statusline not patched (no sentinel found), skipping');
  process.exit(0);
}

const beginIdx = content.indexOf(BEGIN);
const endMarkerIdx = content.indexOf(END, beginIdx);

if (endMarkerIdx === -1) {
  console.error('error: found BEGIN sentinel but no matching END sentinel');
  process.exit(1);
}

// Remove from BEGIN through the END line's newline (inclusive). The patch
// inserted the block plus one trailing newline, so this is an exact inverse.
const endOfEndIdx = content.indexOf('\n', endMarkerIdx);
const afterBlock = endOfEndIdx === -1 ? '' : content.slice(endOfEndIdx + 1);
const restored = content.slice(0, beginIdx) + afterBlock;

fs.writeFileSync(statuslinePath, restored);
fs.chmodSync(statuslinePath, 0o755);

console.log('statusline restored (peer-agent block removed)');
