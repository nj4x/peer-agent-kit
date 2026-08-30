#!/usr/bin/env node
// peer-agent-kit — inserts `disable-model-invocation: true` into the peer-agent
// skill's YAML frontmatter (ADR 0002). Line-based edit, no YAML dependency.
// Idempotent: exits 0 without touching the file if the key is already set.
// Exit 1 on any parse/write failure — install.sh treats that as non-fatal.
'use strict';

const fs = require('fs');

const KEY = 'disable-model-invocation';

const filePath = process.argv[2];
if (!filePath) {
  console.error('usage: skill-patch.js <SKILL.md>');
  process.exit(1);
}

let content;
try {
  content = fs.readFileSync(filePath, 'utf8');
} catch (e) {
  console.error(`error: cannot read ${filePath}: ${e.message}`);
  process.exit(1);
}

// Preserve the file's dominant line ending so the inserted line doesn't mix
// CRLF/LF with the rest of the frontmatter.
const eol = (content.match(/\r\n/g) || []).length >= (content.match(/(?<!\r)\n/g) || []).length ? '\r\n' : '\n';
const lines = content.split(/\r\n|\n/);
if (lines[0].trim() !== '---') {
  console.error('error: SKILL.md has no YAML frontmatter — cannot patch');
  process.exit(1);
}

// Frontmatter is a flat key:/key: value mapping — every non-blank line
// starts at column 0 with `key:`. A `---` line indented under a block
// scalar would never match that shape, so scanning only unindented `---`
// candidates in the frontmatter's own flat-mapping region avoids misreading
// a block-scalar's content as the closing fence.
let closeIdx = -1;
for (let i = 1; i < lines.length; i++) {
  const line = lines[i];
  if (line.trim() === '---') { closeIdx = i; break; }
  if (line.trim() !== '' && /^\S/.test(line) && !/^[\w.-]+:/.test(line)) break;
}
if (closeIdx === -1) {
  console.error('error: unterminated or non-flat YAML frontmatter in SKILL.md — cannot patch');
  process.exit(1);
}

const frontmatter = lines.slice(1, closeIdx);
if (frontmatter.some(l => l.trimStart().startsWith(`${KEY}:`))) {
  console.log('skill already patched, skipping');
  process.exit(0);
}

lines.splice(closeIdx, 0, `${KEY}: true`);

try {
  fs.writeFileSync(filePath, lines.join(eol));
} catch (e) {
  console.error(`error: cannot write ${filePath}: ${e.message}`);
  process.exit(1);
}
console.log('skill frontmatter patched');
