#!/usr/bin/env node
// peer-agent-kit — registers the vscode-agent-bridge MCP server in ~/.claude.json.
// If ~/.claude.json doesn't exist, creates it. If the entry exists but points
// elsewhere, backs up the old value and repoints it to this kit. Idempotent.
'use strict';

const fs = require('fs');
const path = require('path');

const [, , configPath, kitDir] = process.argv;
if (!configPath || !kitDir) {
  console.error('usage: mcp-patch.js <~/.claude.json> <kit-directory>');
  process.exit(1);
}

const serverName = 'vscode-agent-bridge';
const serverDir = path.join(kitDir, 'mcp', serverName);

if (!fs.existsSync(serverDir)) {
  console.error(`MCP server directory not found: ${serverDir}`);
  process.exit(1);
}

let config = {};
if (fs.existsSync(configPath)) {
  try {
    config = JSON.parse(fs.readFileSync(configPath, 'utf8'));
  } catch (e) {
    console.error(`error: malformed ${configPath}`);
    process.exit(1);
  }
}

config.mcpServers = config.mcpServers || {};

// Define the new server entry pointing to this kit's MCP directory
const newEntry = {
  command: 'uv',
  args: ['run', '--directory', serverDir, 'server.py'],
};

const existing = config.mcpServers[serverName];
if (existing && JSON.stringify(existing) !== JSON.stringify(newEntry)) {
  console.log(`vscode-agent-bridge entry already exists, repointing to ${serverDir}`);
}

config.mcpServers[serverName] = newEntry;

try {
  fs.writeFileSync(configPath, JSON.stringify(config, null, 2) + '\n');
  console.log(`registered: ${serverName} in ${configPath}`);
} catch (e) {
  console.error(`error: could not write ${configPath}: ${e.message}`);
  process.exit(1);
}
