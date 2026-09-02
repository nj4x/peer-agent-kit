---
artifact-type: adr
lineage-rules: exempt
title: VS Code extension rebuild on update.sh
status: accepted
date: 2026-09-02
authors: Roman Herasymenko
---

# ADR 0084: VS Code Extension Rebuild on update.sh

**Status:** Accepted  
**Date:** 2026-09-02  
**Context:** VS Code extension (vscode-agent-bridge) is compiled; stale binary hides bugs.

## Decision

`update.sh` rebuilds the extension after `git pull`:
```bash
npm ci && npm run install-dev  # in extension/ directory
```

Extension is reinstalled to `~/.vscode/extensions/nj4x.vscode-agent-bridge-*` on every update.

## Rationale

- **Silent staleness risk:** Extension bugs are invisible at runtime; users cannot diagnose stale binary without external evidence.
- **Compilation cost acceptable:** `npm ci && npm run install-dev` is fast (tens of seconds); worth the safety.
- **Mirrors install.sh pattern:** Consistency with initial setup reduces surprise.

## Consequences

- **npm prerequisite:** `update.sh` assumes npm is on PATH (already required by install.sh).
- **Rebuild failure unrecoverable by re-run:** If `npm ci && npm run install-dev` fails, previous extension binary remains installed (no rollback). User must fix underlying issue (e.g., npm installation failure, disk space) and re-run. Idempotency of npm commands allows this, but stale extension may be in use until rebuild succeeds.
- **Longer update time:** Extension rebuild adds ~30-60 seconds to typical update run.
- **No opt-out:** Extension always rebuilds; no flag to skip (intentional — stale binary is worse).
