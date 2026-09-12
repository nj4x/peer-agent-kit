#!/usr/bin/env node
// peer-agent-kit — injects the SessionStart, SubagentStart, and UserPromptSubmit hook entries
// into an existing Claude Code settings.json, preserving every other key.
'use strict';

const fs = require('fs');

const [, , settingsPath, hooksDir, pluginRoot] = process.argv;
if (!settingsPath || !hooksDir || !pluginRoot) {
  console.error('usage: settings-patch.js <settings.json> <hooksDir> <pluginRoot>');
  process.exit(1);
}

const settings = JSON.parse(fs.readFileSync(settingsPath, 'utf8'));
settings.hooks = settings.hooks || {};

const activateCmd = `CLAUDE_PLUGIN_ROOT='${pluginRoot}' node '${hooksDir}/peer-agent-activate.js'`;
const trackerCmd = `CLAUDE_PLUGIN_ROOT='${pluginRoot}' node '${hooksDir}/peer-agent-mode-tracker.js'`;

function hasCommand(entry, command) {
  return Array.isArray(entry.hooks) && entry.hooks.some(h => h.command === command);
}

// A marker match with a different command means a stale path from an earlier
// install location — drop just that hook (siblings in the same entry, e.g. a
// foreign hook, must survive) and replace it rather than leaving it to fail
// at runtime.
function inject(event, command, marker) {
  if (!Array.isArray(settings.hooks[event])) settings.hooks[event] = [];
  const arr = settings.hooks[event];
  if (arr.some(entry => hasCommand(entry, command))) return false;
  let repointed = false;
  const kept = arr
    .map(entry => {
      if (!Array.isArray(entry.hooks)) return entry;
      const remaining = entry.hooks.filter(h => !(typeof h.command === 'string' && h.command.includes(marker)));
      if (remaining.length < entry.hooks.length) repointed = true;
      return { ...entry, hooks: remaining };
    })
    .filter(entry => !Array.isArray(entry.hooks) || entry.hooks.length > 0);
  if (repointed) {
    settings.hooks[event] = kept;
    console.log(`${event} hook entry already exists, repointing to ${hooksDir}`);
  }
  settings.hooks[event].push({ hooks: [{ type: 'command', command }] });
  return true;
}

const addedStart = inject('SessionStart', activateCmd, 'peer-agent-activate.js');
const addedSubmit = inject('UserPromptSubmit', trackerCmd, 'peer-agent-mode-tracker.js');
const addedSubagent = inject('SubagentStart', activateCmd, 'peer-agent-activate.js');

fs.writeFileSync(settingsPath, JSON.stringify(settings, null, 2) + '\n');

console.log(`SessionStart hook: ${addedStart ? 'added' : 'already present'}`);
console.log(`SubagentStart hook: ${addedSubagent ? 'added' : 'already present'}`);
console.log(`UserPromptSubmit hook: ${addedSubmit ? 'added' : 'already present'}`);
