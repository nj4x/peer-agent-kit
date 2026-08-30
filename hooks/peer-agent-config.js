#!/usr/bin/env node
// peer-agent-kit — shared config + safe flag-file helpers.
'use strict';

const fs = require('fs');
const path = require('path');

// Matches the delegation modes defined in the preinstalled peer-agent skill's
// SKILL.md (lite/full/max), plus 'off'.
const VALID_MODES = ['off', 'lite', 'full', 'max'];

function getDefaultMode() {
  const envMode = process.env.PEER_AGENT_DEFAULT_MODE;
  if (envMode && VALID_MODES.includes(envMode.toLowerCase())) return envMode.toLowerCase();
  return 'full';
}

function findRepoRoot(startDir) {
  let dir = path.resolve(startDir);
  for (;;) {
    if (fs.existsSync(path.join(dir, '.git'))) return dir;
    const parent = path.dirname(dir);
    if (parent === dir) return null;
    dir = parent;
  }
}

// Repo-scoped flag when cwd sits in a git repo whose root already has a
// .claude/ directory; global flag otherwise. The flag file (either scope) is
// both the live session state and the persisted default (ADR 0004). Hooks
// never auto-create .claude/ passively; only an explicit '/peer-agent <mode>'
// does, via createRepoClaudeDir. gitRoot reports the repo root even when
// resolution fell back to global, so callers can offer that upgrade.
// globalFlag is always returned: when the repo flag file is absent, callers
// fall back to reading the global flag before the built-in default (ADR 0004
// decision 6 precedence) — a bare .claude/ dir alone must not shadow it.
function resolveFlagPath(cwd) {
  const claudeDir = process.env.CLAUDE_CONFIG_DIR || path.join(require('os').homedir(), '.claude');
  const globalFlag = path.join(claudeDir, '.peer-agent-active');
  if (!cwd || typeof cwd !== 'string') return { flagPath: globalFlag, repoRoot: null, gitRoot: null, globalFlag };
  let root = null;
  try { root = findRepoRoot(cwd); } catch (e) { /* fall through to global */ }
  if (root) {
    try {
      // lstat, not stat: a symlinked .claude/ (e.g. committed by a hostile
      // repo — git only blocks the name .git, not .claude) must not be
      // followed, or safeWriteFlag/clearFlag would write/delete through it
      // into an attacker-chosen directory.
      if (fs.lstatSync(path.join(root, '.claude')).isDirectory()) {
        return { flagPath: path.join(root, '.claude', '.peer-agent-mode'), repoRoot: root, gitRoot: root, globalFlag };
      }
    } catch (e) { /* .claude missing → global */ }
  }
  return { flagPath: globalFlag, repoRoot: null, gitRoot: root, globalFlag };
}

// Symlink-safe .claude/ creation for the explicit '/peer-agent <mode>' path
// (ADR 0004 decision 2, amended). mkdir WITHOUT recursive: an existing entry
// — including a hostile symlink committed by the repo — surfaces as EEXIST
// instead of being silently accepted, and the caller re-runs resolveFlagPath
// so its lstat check decides whether the dir is usable.
function createRepoClaudeDir(repoRoot) {
  try {
    fs.mkdirSync(path.join(repoRoot, '.claude'));
    return true;
  } catch (e) {
    return e.code === 'EEXIST';
  }
}

const EXCLUDE_LINE = '.claude/.peer-agent-mode';

// Best-effort, idempotent. A worktree/submodule .git *file*, or a symlinked
// .git dir (same hostile-repo risk as .claude above), is skipped — lstat
// (not stat) never follows the symlink. Not load-bearing (ADR 0004 decision 5).
function ensureGitExclude(repoRoot) {
  try {
    const gitDir = path.join(repoRoot, '.git');
    if (!fs.lstatSync(gitDir).isDirectory()) return;
    const excludePath = path.join(gitDir, 'info', 'exclude');
    let existing = '';
    try { existing = fs.readFileSync(excludePath, 'utf8'); } catch (e) { /* absent */ }
    if (existing.split('\n').some(l => l.trim() === EXCLUDE_LINE)) return;
    fs.mkdirSync(path.dirname(excludePath), { recursive: true });
    const sep = existing && !existing.endsWith('\n') ? '\n' : '';
    fs.appendFileSync(excludePath, `${sep}${EXCLUDE_LINE}\n`);
  } catch (e) { /* best-effort */ }
}

// Refuses a symlink at the flag path — defends against a local attacker
// pointing the flag at a sensitive file that a reader (statusline, the
// UserPromptSubmit hook) would then read and act on. Atomic write via
// temp file + rename.
function safeWriteFlag(flagPath, content) {
  try {
    const dir = path.dirname(flagPath);
    fs.mkdirSync(dir, { recursive: true });
    try {
      if (fs.lstatSync(flagPath).isSymbolicLink()) return;
    } catch (e) {
      if (e.code !== 'ENOENT') return;
    }
    const tmp = path.join(dir, `.peer-agent-active.${process.pid}.${Date.now()}`);
    fs.writeFileSync(tmp, String(content), { mode: 0o600 });
    fs.renameSync(tmp, flagPath);
  } catch (e) {
    // best-effort — the flag is not load-bearing for correctness
  }
}

// Longest valid mode is "lite"/"full" (4 bytes); 16 leaves slack without
// letting the flag be used to smuggle arbitrary content into context.
const MAX_FLAG_BYTES = 16;

function readFlag(flagPath) {
  try {
    const st = fs.lstatSync(flagPath);
    if (st.isSymbolicLink() || !st.isFile() || st.size > MAX_FLAG_BYTES) return null;
    const raw = fs.readFileSync(flagPath, 'utf8').trim().toLowerCase();
    return VALID_MODES.includes(raw) ? raw : null;
  } catch (e) {
    return null;
  }
}

function clearFlag(flagPath) {
  try { fs.unlinkSync(flagPath); } catch (e) { /* already gone */ }
}

module.exports = { VALID_MODES, getDefaultMode, safeWriteFlag, readFlag, clearFlag, resolveFlagPath, ensureGitExclude, createRepoClaudeDir };
