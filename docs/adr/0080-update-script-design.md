---
artifact-type: adr
lineage-rules: exempt
title: Update script design for in-place kit upgrades
status: accepted
date: 2026-09-02
authors: Roman Herasymenko
---

# ADR 0080: Update Script Design for In-Place Kit Upgrades

**Status:** Accepted  
**Date:** 2026-09-02  
**Context:** Adopted from caveman-kit's `update.sh` pattern (commit 236104d) to enable in-place peer-agent-kit upgrades without uninstall+bootstrap cycle.

## Decision

Implement `update.sh` script that:
1. **Fetch remote** via `git fetch origin` to ensure remote-tracking refs are current before comparison.
2. **Idempotency gate** via `kitSha` manifest field (git SHA of last-applied kit commit); compare remote HEAD SHA against stored `kitSha`; if equal, exit 0 immediately (no new commits on remote).
3. **Unpatch all three surfaces** in sequence: `settings.json`, `statusline.sh`, `~/.claude.json` MCP entry.
4. **Pull kit repo** with `git pull origin $REMOTE_HEAD --ff-only` (fast-forward only), where `REMOTE_HEAD` is derived from `git symbolic-ref refs/remotes/origin/HEAD` (fallback: `main`). On failure (e.g., non-FF divergence), surfaces remain unpatched; user must resolve git divergence manually, then re-run `update.sh`.
5. **Rebuild VS Code extension** via `npm ci && npm run install-dev` in `extension/`.
6. **Sync Python env** via `uv sync` for `mcp/vscode-agent-bridge`.
7. **Copy hook files** from `hooks/` to `~/.peer-agent-kit/hooks/`.
8. **Overwrite Cline hook files** under `~/Documents/Cline/Hooks` (if present) to sync with repo.
9. **Repatch all three surfaces** using freshly-pulled patch scripts.
10. **Update skill** if `skillInstalledByKit=true`: overwrite `$CLAUDE_DIR/skills/peer-agent` from repo and repatch its frontmatter.
11. **Write `kitSha`** to manifest (atomic temp-file-then-rename) and exit 0.

## Rationale

- **Completeness:** Three-surface patch (vs caveman-kit's two) requires full unpatch/repatch cycle; leaving any stale is a drift risk.
- **Extension rebuild:** Silent staleness of compiled binaries is worse than the cost of rebuild. Users cannot diagnose extension behavior bugs without direct evidence.
- **Atomic manifest writes:** Prevent corruption of manifest.json on mid-flight failure; combined with idempotent patch scripts, re-runs are always safe.
- **No rollback:** Patch idempotency (both install and update scripts) is the safety net; rolling back adds complexity that doesn't justify itself.
- **kitSha in install.sh:** Populate the field from day one so manifest is complete post-install, avoiding lazy-init edge cases.
- **Node for manifest parsing:** peer-agent-kit already mandates `node` as a hard prereq; `node -e` JSON parse is simpler and more portable than jq-with-fallback.

## Prerequisites

- **Git repo:** `$KIT_DIR/.git` must exist; `update.sh` is git-dependent.
- **`node`, `npm`, `uv`, `git`:** All required on PATH (same as `install.sh` requirements).

## Consequences

- **First install must set `kitSha`:** Patch `install.sh` to write `kitSha` to manifest at completion.
- **Git fetch before gate:** Remote-tracking refs must be fresh; `git fetch origin` runs before idempotency comparison to avoid stale-ref skips.
- **Non-FF divergence unrecoverable by re-run:** If `git pull --ff-only` fails due to non-fast-forward history, user must resolve divergence manually (e.g., `git reset --hard origin/$REMOTE_HEAD` or rebase) before re-running.
- **Cline hook files overwritten without backup:** Files under `~/Documents/Cline/Hooks` are overwritten in place; no backup is created. User modifications to those files will be lost on each update.
- **No new backups created for settings/statusline/claude.json on update:** `update.sh` delegates all file mutations to the existing unpatch/patch scripts; it creates no additional backups beyond those already in `~/.peer-agent-kit/backup/` from install time.
- **Skill updates only if `skillInstalledByKit=true`:** In-repo skill changes propagate automatically on update; external skill sources (if added later) would need separate versioning.
- **README documentation:** Add "To update:" guidance alongside "To uninstall:" sections (both quick-install and manual-install paths).
