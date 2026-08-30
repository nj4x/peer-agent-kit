---
artifact-type: adr
lineage-rules:
  - "ADR must reference at least one source SRS item"
source-srs: .data/requirements/peer-agent-kit-SRS-001.md
---

# ADR-0075: Multi-Session Concurrent Delegation — Collision Gap & Fix Strategy

**Status**: Accepted

**Source SRS**: SRS-PAK-001, SRS-PAK-002

## Context

The original peer-agent-kit design assumed one MCP server per user account. When two Claude Code IDE sessions run concurrently (e.g., one interactive, one background automation), each spawns its own vscode-agent-bridge MCP server. Both attempt to manage a shared dedicated VS Code window via `code --user-data-dir ~/.vscode-agent-bridge/data`.

VS Code's single-instance-per-user-data-dir enforcement means only the first server's window actually spawns; the second server's `code` invocation hands off to the existing window. The result is a hard collision:
- Both servers' `InstanceManager` objects own references to the same window process
- Only the first server's `BRIDGE_PORT` reaches the window's extension (captured at activation from the first server's process environment)
- Second server's hook events POST to a port the extension isn't listening on
- Second server's tasks time out with `instance_down` or hang indefinitely

ADR-0069 explicitly declares this scenario out-of-scope ("single-instance server assumed"), making the collision a documented gap rather than a hidden bug.

## Decision

**Implement session-scoped VS Code instances (ADR-0071, ADR-0072, ADR-0073) to give each MCP server its own isolated window and environment.**

This resolves the collision by eliminating the shared resource — no more fighting over `~/.vscode-agent-bridge/data`. Each session gets:
- Fresh `--user-data-dir` keyed by server PID
- Isolated `BRIDGE_PORT` (server receives its own ephemeral HookServer port)
- Own Electron process and extension host
- Shared cline-sr config (symlink, see ADR-0072) so sessions reuse the same API keys and memory

## Consequences

- **Pro**: Eliminates the collision entirely. Two concurrent Claude Code sessions can delegate independently without interference. Common use case (interactive + background) now works correctly.
- **Pro**: Aligns with user expectations: running two separate IDE instances (metaphorically) should behave independently.
- **Pro**: Fixes ADR-0069's out-of-scope limitation — multi-session support is now in-scope and tested.
- **Con**: Resource cost: each concurrent session owns its own VS Code window, consuming ~300MB RAM per window. For typical use (1–2 concurrent sessions), acceptable; for many sessions (5+), resource pressure rises.
- **Con**: Removes the original design's single-window simplicity. Observability/debugging must now distinguish which session owns which window (e.g., via PID suffix in data dir).

## Remaining Gaps (After ADR-0071/0072/0073)

This ADR documents the gap and points to the fix. After implementing ADRs 0071–0073, this collision is resolved. No additional architectural change is needed.

**Documentation update**: ADR-0069 (Observability) should be revised to note that multi-session scenarios are now supported, and logging should include `data_dir` or server PID for window identification.

## Related

- **ADR-0071**: Session-scoped VS Code instance (implements the fix)
- **ADR-0072**: Shared cline-sr config via symlink
- **ADR-0073**: Sub-workspace reuse
- **ADR-0069**: Observability (original scope statement)

## Notes

This ADR is a postmortem that acknowledges a gap (multi-session collision) that was discovered during grilling, and points to the architectural fixes (ADRs 0071–0073) that resolve it. The gap was not a bug — it was an explicit scope boundary in ADR-0069 — but extending the scope via these ADRs brings multi-session support into the product.
