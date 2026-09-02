# Update Script Implementation Plan

Design Decisions Reached During Grilling — five ADRs locked in (2026-09-02):

- `docs/adr/0080-update-script-design.md` — Overall design: idempotency gate, three-surface unpatch/pull/repatch, extension rebuild, atomic manifest writes.
- `docs/adr/0081-kitsha-manifest-field.md` — `kitSha` field for idempotency (populate in install.sh, read/write in update.sh).
- `docs/adr/0082-update-script-manifest-atomicity.md` — Atomic temp-file-then-rename for manifest.json writes; no rollback (rely on patch idempotency).
- `docs/adr/0083-update-script-three-surface-patch.md` — Unpatch/repatch all three surfaces (settings.json, statusline.sh, ~/.claude.json).
- `docs/adr/0084-update-script-extension-rebuild.md` — Rebuild VS Code extension on every update.

## Implementation scope

1. **Patch install.sh** to write `kitSha` field to manifest at completion.
2. **Write `update.sh`** script with full unpatch/pull/repatch cycle, extension rebuild, atomic manifest writes.
3. **Patch README.md** to document "To update:" guidance (both quick-install and manual-install paths).
4. **Test idempotency:** Verify re-running `update.sh` exits 0 immediately (SHA compare gate).

## Open design questions

None — all decisions from grilling are locked in and recorded as ADRs above.

---

## Session Ledger

| Role         | Outcome                  |
|--------------|--------------------------|
| orchestrator | —                        |
| planner      | complete (grilling)      |
| critic #1    | revise (major)           |
| critic #2    | revise (minor)           |
| critic #3    | approve (minor)          |

## Critic Review

- **Final verdict:** approve
- **Severity:** minor
- **Iterations used:** 3 of ∞ (backstop 10)
- **Approval status:** ✓ Automatically approved by critic. No manual review required.
- **Risks / questions:** one minor wording issue in ADR 0080 Consequences flagged and fixed post-approval (misleading "read-only" bullet heading).
