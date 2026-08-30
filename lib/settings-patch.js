#!/usr/bin/env node
// peer-agent-kit — injects the SessionStart and UserPromptSubmit hook entries
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

function alreadyInjected(event, marker) {
  const arr = settings.hooks[event];
  if (!Array.isArray(arr)) return false;
  return arr.some(entry =>
    Array.isArray(entry.hooks) &&
    entry.hooks.some(h => typeof h.command === 'string' && h.command.includes(marker))
  );
}

function inject(event, command, marker) {
  if (!Array.isArray(settings.hooks[event])) settings.hooks[event] = [];
  if (alreadyInjected(event, marker)) return false;
  settings.hooks[event].push({ hooks: [{ type: 'command', command }] });
  return true;
}

const addedStart = inject('SessionStart', activateCmd, 'peer-agent-activate.js');
const addedSubmit = inject('UserPromptSubmit', trackerCmd, 'peer-agent-mode-tracker.js');

fs.writeFileSync(settingsPath, JSON.stringify(settings, null, 2) + '\n');

console.log(`SessionStart hook: ${addedStart ? 'added' : 'already present'}`);
console.log(`UserPromptSubmit hook: ${addedSubmit ? 'added' : 'already present'}`);
