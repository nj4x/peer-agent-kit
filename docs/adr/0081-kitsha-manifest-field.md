---
artifact-type: adr
lineage-rules: exempt
title: kitSha manifest field for update idempotency
status: accepted
date: 2026-09-02
authors: Roman Herasymenko
---

# ADR 0081: kitSha Manifest Field for Update Idempotency

**Status:** Accepted  
**Date:** 2026-09-02  
**Context:** Supporting ADR 0080; requires a stable git SHA field in manifest to gate `update.sh` idempotency.

## Decision

Add `kitSha` field to `~/.peer-agent-kit/manifest.json`:
- **Value:** git SHA of the last-applied kit commit (from `git rev-parse HEAD` in `$KIT_DIR`).
- **Populated at:** `install.sh` completion (new field, always written) and `update.sh` completion (written after all mutations).
- **Idempotency gate:** `update.sh` fetches remote with `git fetch origin`, then exits 0 immediately if remote HEAD SHA (from `git rev-parse origin/$REMOTE_HEAD`) equals stored `kitSha`. No new commits on remote = no update needed.
- **Default:** Absent on pre-0081 installs (field was never written). On first `update.sh` run, the gate is bypassed (no stored SHA to compare), the update proceeds, and the field is written at completion. New installs (post-0081) always have the field populated by `install.sh`.

## Rationale

- **Copied from caveman-kit:** Proven pattern (caveman-kit ADR 0007, extended here); caveman-kit explicitly fetches before compare to avoid stale-ref issues.
- **Lazy init acceptable:** If `kitSha` is absent, assume "initial state"; first update always runs (gate is bypassed, field then written).
- **Fetch before compare:** Remote-tracking refs can lag behind upstream by days or hours if user has not pulled recently. Explicit `git fetch origin` ensures fresh ref before comparison.
- **Fast-forward gate:** Prevents redundant unpatch/pull/repatch cycles when kit repo is unchanged.

## Consequences

- **Manifest schema change:** `kitSha` is a new optional field; must be documented in install.sh comments and manifest JSON schema (if one exists).
- **Git repo required:** `update.sh` assumes `$KIT_DIR/.git` exists; non-git kits cannot use `update.sh`.
