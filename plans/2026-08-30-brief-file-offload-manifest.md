# Manifest: brief-file offload (grilling 2026-08-30)

Design Decisions Reached During Grilling on `docs/research/brief-truncation-analysis.md` (silent URI truncation of long delegation briefs, and the peer-agent skill's insufficient guidance on embedding referenced artifacts verbatim). The ADR below is ground truth; this file is only a pointer list for critic review.

- docs/adr/0077-brief-file-offload.md

Supporting lineage updates (context, not review targets):
- .data/requirements/peer-agent-kit-SRS-001.md (added SRS-PAK-008)
- .data/requirements/peer-agent-kit-FS-001.md (extended FS-PAK-004 with complete-delivery clause)

Out of scope for this ADR (decided during grilling, not ADR-worthy — see grilling transcript Q7b/Q12): peer-agent SKILL.md guidance on embedding referenced artifacts verbatim. To be implemented as a plain SKILL.md wording change + commit message, not an ADR.

Verification performed during design (2026-08-30): cline-sr confirmed able to read an absolute path outside its open workspace root (`~/.vscode-agent-bridge/briefs/test-brief-read.md` marker read back via ask_peer_agent).

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
  - ID-010: 50KB WARNING is deferrable scope (second threshold + separate code path); consider moving to an ADR-0069 observability follow-up.
  - ID-011: Python/JS encoding parity unspecified — state how bridge.py replicates `encodeURIComponent()` (e.g. `urllib.parse.quote(prompt, safe="!'()*-._~")`).
  - ID-012: owning component for the threshold check unassigned (implementation-level; resolve during implementation).
  - ID-013: `briefs/` subdirectory creation unstated — treat makedirs failure identically to write failure.
  - ID-014: "OS lower bound" wording in Decision inconsistent with Context's "OS/VS Code" attribution; actual floor is VS Code URI handler behavior.
  - ID-015: 50KB ≈ 12k-token estimate is ASCII-calibrated; CJK-heavy briefs cost 25-33k tokens at same byte count.
