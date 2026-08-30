# Manifest: template-profile bootstrap (grilling 2026-08-30)

Design Decisions Reached During Grilling on `docs/research/vscode-user-dir-preseeding.md` (eliminating VS Code first-run friction and propagating the user's editor profile into bridge session windows). The ADR below is ground truth; this file is only a pointer list for critic review.

- docs/adr/0076-template-profile-bootstrap.md

Supporting lineage updates (context, not review targets):
- .data/requirements/peer-agent-kit-FS-001.md (added FS-PAK-005)
- .data/requirements/peer-agent-kit-SRS-001.md (added SRS-PAK-007)
- CONTEXT.md (added "Template profile" term and ADR-0076 summary)

---

## Session Ledger

| Role         | Outcome                  |
|--------------|--------------------------|
| orchestrator | —                        |
| planner      | complete (revision pass) |
| critic #1    | revise (major)           |
| critic #2    | approve (minor)          |

## Critic Review

- **Final verdict:** approve
- **Severity:** minor
- **Iterations used:** 2 of ∞ (backstop 10)
- **Approval status:** ✓ Automatically approved by critic. No manual review required.
- **Risks / questions (open minors, advisory):**
  - ID-005: merge order lets template settings override the two automation-critical suppression keys; force-write them post-merge to keep SRS-PAK-007 unconditional.
  - ID-006: copying all of `globalStorage/` exceeds FS-PAK-005 scope (pulls other extensions' auth state); consider dropping it from the copy list.
  - ID-007: install.sh interactive launch is arguably scope creep vs. SRS-PAK-007; alternative is a documented one-time command.
  - ID-008: `User/settings.json` existence may be a false-positive configured-marker if VS Code auto-creates it; a dedicated sentinel file is safer.
  - ID-009: §Location wording contradiction ("never contend" vs "lock contention remains possible") — reword the invariant.
  - ID-010: workspaceStorage copy lacks the explicit "departure from research doc" callout that vscdb has.
  - ID-011: plain-file copy concurrency with a live template window unbounded — state atomic-write reliance or instruct closing the window.
