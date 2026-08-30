#!/usr/bin/env node
// peer-agent-kit — surgically restores ~/.claude.json on uninstall.
//
// Reads the manifest's mcpPriorEntry and restores only that key in mcpServers.
// If mcpPriorEntry is null/undefined, deletes the vscode-agent-bridge entry
// (kit created it). If the prior entry's args contain a --directory whose path
// no longer exists, drops the entry with a warning (stale pre-install entry).
// Never destroys live state: if config JSON is malformed, exits 0 with a warning.
'use strict';

const fs = require('fs');

const [, , configPath, manifestPath] = process.argv;
if (!configPath || !manifestPath) {
  console.error('usage: mcp-unpatch.js <configPath> <manifestPath>');
  process.exit(1);
}

// Read manifest and extract mcpPriorEntry (may be undefined for old manifests)
let mcpPriorEntry = null;
if (fs.existsSync(manifestPath)) {
  try {
    const manifest = JSON.parse(fs.readFileSync(manifestPath, 'utf8'));
    mcpPriorEntry = manifest.mcpPriorEntry ?? null;
  } catch (e) {
    console.error('warning: could not parse manifest.json; treating mcpPriorEntry as null');
  }
}

// If configPath missing: nothing to do
if (!fs.existsSync(configPath)) {
  console.log('note: MCP config not found; nothing to restore');
  process.exit(0);
}

// Read config; if malformed, warn and exit 0 WITHOUT touching the file
let config;
try {
  config = JSON.parse(fs.readFileSync(configPath, 'utf8'));
} catch (e) {
  console.error('warning: MCP config JSON is malformed; leaving file untouched');
  process.exit(0);
}

const serverName = 'vscode-agent-bridge';

// If mcpPriorEntry is null: delete the key if present (kit created it)
if (mcpPriorEntry === null || mcpPriorEntry === undefined) {
  if (config.mcpServers && config.mcpServers[serverName]) {
    delete config.mcpServers[serverName];
    console.log('removed: vscode-agent-bridge entry (created by kit)');
  } else {
    console.log('note: vscode-agent-bridge entry not present');
  }
} else {
  // Staleness check: if prior entry's args contain --directory with a path
  // that no longer exists, drop the entry instead of restoring
  const args = mcpPriorEntry.args || [];
  let staleDir = null;
  for (let i = 0; i < args.length - 1; i++) {
    if (args[i] === '--directory') {
      const dirPath = args[i + 1];
      if (!fs.existsSync(dirPath)) {
        staleDir = dirPath;
        break;
      }
    }
  }

  if (staleDir) {
    console.error(`warning: prior entry references non-existent directory ${staleDir}; dropping stale pre-install entry`);
    if (config.mcpServers && config.mcpServers[serverName]) {
      delete config.mcpServers[serverName];
      console.log('removed: vscode-agent-bridge entry (stale)');
    }
  } else {
    // Restore the prior entry
    config.mcpServers = config.mcpServers || {};
    config.mcpServers[serverName] = mcpPriorEntry;
    console.log('restored: vscode-agent-bridge prior entry');
  }
}

// Write file back with JSON.stringify(config, null, 2) + '\n', touching nothing else
try {
  fs.writeFileSync(configPath, JSON.stringify(config, null, 2) + '\n');
} catch (e) {
  console.error(`error: could not write ${configPath}: ${e.message}`);
  process.exit(1);
}
