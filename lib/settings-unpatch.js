#!/usr/bin/env node
// peer-agent-kit — surgically removes the SessionStart and UserPromptSubmit hook
// entries from settings.json by matching marker strings in command fields.
// This is the inverse of settings-patch.js, using marker-based removal instead
// of byte-exact restore from backup.
'use strict';

const fs = require('fs');

const [, , settingsPath] = process.argv;
if (!settingsPath) {
  console.error('usage: settings-unpatch.js <settings.json>');
  process.exit(1);
}

const ACTIVATE_MARKER = 'peer-agent-activate.js';
const TRACKER_MARKER = 'peer-agent-mode-tracker.js';

let settings;
try {
  settings = JSON.parse(fs.readFileSync(settingsPath, 'utf8'));
} catch (e) {
  console.error(`error: cannot parse ${settingsPath}: ${e.message}`);
  process.exit(1);
}

if (!settings.hooks) {
  console.log('no hooks section found, nothing to remove');
  process.exit(0);
}

function removeHooks(event, marker) {
  const arr = settings.hooks[event];
  if (!Array.isArray(arr)) return 0;
  
  const originalLength = arr.length;
  const filtered = arr.filter(entry => {
    // Keep entries that don't contain our marker
    if (!Array.isArray(entry.hooks)) return true;
    return !entry.hooks.some(h => 
      typeof h.command === 'string' && h.command.includes(marker)
    );
  });
  
  const removed = originalLength - filtered.length;
  
  // Clean up empty arrays
  if (filtered.length === 0) {
    delete settings.hooks[event];
  } else {
    settings.hooks[event] = filtered;
  }
  
  return removed;
}

const removedStart = removeHooks('SessionStart', ACTIVATE_MARKER);
const removedSubmit = removeHooks('UserPromptSubmit', TRACKER_MARKER);

// Clean up empty hooks object
if (Object.keys(settings.hooks).length === 0) {
  delete settings.hooks;
}

fs.writeFileSync(settingsPath, JSON.stringify(settings, null, 2) + '\n');

console.log(`SessionStart hook: removed ${removedStart} entry(s)`);
console.log(`UserPromptSubmit hook: removed ${removedSubmit} entry(s)`);
