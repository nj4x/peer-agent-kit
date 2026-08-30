---
artifact-type: ticket
ticket-subtype: adr-direct
lineage-rules:
  - "Ticket must reference at least one source ADR"
  - "Spec field is intentionally omitted: this ticket traces directly to an ADR"
---

# 05 — Docs: sub-workspace path constraint and multi-session scope

**Source ADR**: docs/adr/0073-sub-workspace-reuse-with-path-normalization.md
**Source ADR**: docs/adr/0075-multi-session-concurrent-delegation-collision-gap.md

## What to build

Documentation updates mandated by ADR-0073's "Documentation actions" section and ADR-0075's remaining-gaps section. This ticket captures changes spanning ADRs 0071, 0072, 0073, and 0075.

- `skills/peer-agent/SKILL.md`: add briefing guidance — when a delegated task targets a sub-workspace of the folder already open in the dedicated window, cline-sr receives no workspace-root-change signal and resolves relative paths against the open root. Task prompts must reference files by absolute path or by path relative to the open root.
- `CONTEXT.md`: document the sub-workspace dispatch behavior (containment short-circuit, no window reload, no root-change signal to cline-sr) and the same path constraint; document the session-scoped instance model (PID-keyed data dirs, shared cline-sr config symlink) in the ubiquitous-language / architecture sections.
- `docs/adr/0069-vscode-agent-bridge-observability.md`: revise the scope statement — multi-session scenarios are now supported (ADRs 0071, 0072, 0073, 0075); note that logs include the data dir / server PID for window identification.

## Requirements

SRS-PAK-001, SRS-PAK-004, SRS-PAK-005

## Blocked by

03 — path-normalization-subworkspace

## Status

done

## Checklist

- [x] SKILL.md briefing guidance added (absolute or open-root-relative paths for sub-workspace tasks) — code: skills/peer-agent/SKILL.md "Sub-workspace targets" paragraph, verified by review agent against ADR-0073 and instance.py
- [x] CONTEXT.md covers sub-workspace dispatch and session-scoped instances — code: CONTEXT.md "Session-scoped VS Code instance" and "Sub-workspace dispatch" entries under Architecture decisions, plus "Open root" ubiquitous-language entry; verified against instance.py by review agent
- [x] ADR-0069 scope statement revised with a pointer to ADRs 0071–0075 — code: docs/adr/0069-vscode-agent-bridge-observability.md "Scope: multi-session now supported" paragraph, points to ADRs 0071, 0072, 0073, 0075 (0074 omitted, unrelated to multi-session)
- [x] Terminology matches CONTEXT.md ubiquitous language (Bridge, Session, Delegation mode) — code review agent confirmed capitalization/usage consistent with existing CONTEXT.md entries
