#!/usr/bin/env node
// peer-agent-kit — SessionStart hook.
//
// Resolves the active mode, persists it to a flag file (read by the
// statusline badge and the UserPromptSubmit hook), and — unless mode is
// 'off' — injects the peer-agent ruleset filtered to that mode's row/examples
// from the preinstalled peer-agent skill's SKILL.md.
'use strict';

const fs = require('fs');
const path = require('path');
const { VALID_MODES, getDefaultMode, safeWriteFlag, readFlag, clearFlag, resolveFlagPath, ensureGitExclude } = require('./peer-agent-config');

let cwd = null;
try {
  if (!process.stdin.isTTY) {
    const raw = fs.readFileSync(0, 'utf8');
    if (raw) {
      const data = JSON.parse(raw);
      if (data && typeof data.cwd === 'string') cwd = data.cwd;
    }
  }
} catch (e) { /* no/bad stdin → global flag fallback */ }

const { flagPath, repoRoot, globalFlag } = resolveFlagPath(cwd);

// The flag file — repo-scoped or global — is both the live session state and
// the persisted default (ADR 0004): every SessionStart honors it, including
// a real startup. Precedence (decision 6): repo flag file → global flag →
// PEER_AGENT_DEFAULT_MODE / built-in 'full'. The write goes to whichever file
// the mode came from — a passive session never creates the repo flag file,
// even when a .claude/ dir already exists (only an explicit '/peer-agent <mode>'
// scopes the mode to the repo).
let mode = readFlag(flagPath);
let target = flagPath;
if (mode === null && flagPath !== globalFlag) {
  mode = readFlag(globalFlag);
  if (mode !== null) target = globalFlag;
}
if (mode === null) {
  mode = getDefaultMode();
  target = globalFlag;
}

if (mode === 'off') {
  clearFlag(target);
  process.exit(0);
}

safeWriteFlag(target, mode);
if (target === flagPath && repoRoot) ensureGitExclude(repoRoot);

if (!process.env.CLAUDE_PLUGIN_ROOT) {
  process.stderr.write('peer-agent-kit: CLAUDE_PLUGIN_ROOT not set, cannot locate the peer-agent skill\n');
  process.exit(0);
}

const skillPath = path.join(process.env.CLAUDE_PLUGIN_ROOT, 'skills', 'peer-agent', 'SKILL.md');
let skillContent;
try {
  skillContent = fs.readFileSync(skillPath, 'utf8');
} catch (e) {
  process.stderr.write(`peer-agent-kit: could not read ${skillPath}\n`);
  process.exit(0);
}

// Strip YAML frontmatter, then keep only the active level's intensity-table
// row and example lines — the rest of the ruleset (rules, boundaries, etc.)
// applies at every level and is kept as-is.
const body = skillContent.replace(/^---[\s\S]*?---\s*/, '');

const MODE_ORDER = VALID_MODES.filter(m => m !== 'off');
const modeRank = MODE_ORDER.indexOf(mode);

const filtered = body.split('\n').reduce((acc, line) => {
  const tableRowMatch = line.match(/^\|\s*\*\*(\S+?)\*\*\s*\|/);
  if (tableRowMatch) {
    if (tableRowMatch[1] === mode) acc.push(line);
    return acc;
  }
  const exampleMatch = line.match(/^(- )(\S+?):\s/);
  if (exampleMatch) {
    const exampleMode = exampleMatch[2];
    const exampleRank = MODE_ORDER.indexOf(exampleMode);
    if (exampleRank !== -1 && exampleRank <= modeRank) {
      acc.push(exampleMatch[1] + line.slice(exampleMatch[0].length));
    }
    return acc;
  }
  acc.push(line);
  return acc;
}, []);

process.stdout.write(`PEER_AGENT MODE ACTIVE — level: ${mode}\n\n` + filtered.join('\n'));
