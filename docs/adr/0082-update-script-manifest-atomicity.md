---
artifact-type: adr
lineage-rules: exempt
title: Atomic manifest writes in update.sh
status: accepted
date: 2026-09-02
authors: Roman Herasymenko
---

# ADR 0082: Atomic Manifest Writes in update.sh

**Status:** Accepted  
**Date:** 2026-09-02  
**Context:** Prevent manifest.json corruption if `update.sh` fails mid-flight.

## Decision

- **Manifest writes:** Always use temp-file-then-rename (atomic) pattern when updating `manifest.json`.
- **Idempotent unpatch/patch scripts:** Rely on their existing idempotency; no separate rollback mechanism in `update.sh`.
- **Error handling:** On ERR, log to stderr and exit non-zero. Document that re-running `update.sh` is safe when patch failures occur (patches skip if already applied). Non-patch errors (e.g., git pull failure after unpatch) require manual intervention.

## Rationale

- **Atomicity prevents corruption:** Temp + rename is POSIX-atomic; avoids leaving manifest in half-written state.
- **Idempotency is sufficient recovery:** Patch scripts already detect prior application (marker strings); re-runs are safe and complete the update.
- **Rollback complexity unjustified:** Rolling back patches (restore from backup) is complex and rarely needed; re-run + idempotency covers the common case.

## Consequences

- **Patch failures:** Idempotent unpatch/patch scripts allow re-run to safely complete. Users should re-run after fixing underlying issues (e.g., permission errors, disk space).
- **Git failures:** If `git pull --ff-only` fails after unpatch (e.g., non-fast-forward divergence), all three surfaces are left unpatched. User must resolve git divergence manually (e.g., `git reset --hard origin/$REMOTE_HEAD` or rebase the kit repo), then re-run `update.sh`. The re-run will unpatch/pull/repatch successfully.
- **uv sync failure:** If `uv sync` fails after git pull (step 6 of ADR 0080), all three surfaces remain unpatched and the Python env is out of sync. Fix the underlying issue (e.g., `uv` not on PATH, network, disk), then re-run; the idempotent unpatch/repatch cycle makes re-run safe.
- **Backup files stay in `~/.peer-agent-kit/backup/`:** Available for manual recovery if needed, but not automatically used by `update.sh`.
