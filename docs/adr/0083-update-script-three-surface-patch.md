---
artifact-type: adr
lineage-rules: exempt
title: Three-surface patch cycle in update.sh
status: accepted
date: 2026-09-02
authors: Roman Herasymenko
---

# ADR 0083: Three-Surface Patch Cycle in update.sh

**Status:** Accepted  
**Date:** 2026-09-02  
**Context:** peer-agent-kit patches three surfaces (settings.json, statusline.sh, ~/.claude.json MCP entry); update must sync all three.

## Decision

`update.sh` unpatch/pull/repatch cycle includes:
1. **settings.json** (SessionStart/SubagentStart/UserPromptSubmit hooks).
2. **statusline.sh** (peer-agent badge block).
3. **~/.claude.json** (MCP server vscode-agent-bridge entry).

All three undergo: unpatch → pull → repatch in sequence.

## Rationale

- **Surgical unpatch/patch are idempotent:** Each surface's unpatch/patch scripts skip if already applied/unapplied; full cycle is safe.
- **Drift prevention:** Leaving any surface untouched risks stale hook paths or MCP config if repo changes.
- **Low cost:** Patch scripts are fast; no performance justification for skipping.

## Consequences

- **Mandatory `lib/mcp-unpatch.js` / `lib/mcp-patch.js` in update.sh:** These scripts must be present and idempotent (already are).
- **MCP server config rarely changes:** But when it does, update.sh ensures sync; no special case needed.
