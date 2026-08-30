---
artifact-type: srs
lineage-rules:
  - "SRS must reference at least one source FS item"
source-fs: .data/requirements/peer-agent-kit-FS-001.md
---

# peer-agent-kit — System Requirements Specification 001

System contracts satisfying peer-agent-kit-FS-001. Contracts state observable system behavior (EARS format); realization mechanisms (data-dir layout, symlinks, hook wiring) are recorded in ADRs.

**Source FS**: FS-PAK-001, FS-PAK-002, FS-PAK-003, FS-PAK-004, FS-PAK-005

## Requirements

**SRS-PAK-001 — Per-server instance isolation**
WHEN a vscode-agent-bridge MCP server process starts, THE SYSTEM SHALL associate delegation with an isolated peer-agent instance environment scoped to that server process's lifetime.
*Source FS*: FS-PAK-001

**SRS-PAK-002 — Concurrent dispatch without cross-talk**
WHILE multiple bridge server processes run concurrently under one user account, THE SYSTEM SHALL route each server's task dispatches and lifecycle hook events exclusively to that server's own instance.
*Source FS*: FS-PAK-001

**SRS-PAK-003 — Shared peer-agent configuration store**
THE SYSTEM SHALL expose one shared peer-agent configuration store (credentials, custom instructions, memory) to all delegation instances of a user account, such that configuration written in any session is visible to subsequent and concurrent sessions.
*Source FS*: FS-PAK-002

**SRS-PAK-004 — Sub-workspace dispatch without reload**
WHEN a task's target workspace path is contained within the workspace currently open in the instance, THE SYSTEM SHALL dispatch the task without reloading or replacing the instance's open workspace.
*Source FS*: FS-PAK-004

**SRS-PAK-005 — Workspace-path equivalence**
WHEN the system compares two workspace paths for equality or containment, THE SYSTEM SHALL treat paths that designate the same filesystem location as equivalent.
*Source FS*: FS-PAK-004

**SRS-PAK-006 — Waiting-for-input status surfacing** *(Deferred — no realizing ADR)*
WHEN the peer agent enters a state of waiting for human input on a delegated task, THE SYSTEM SHALL report a status distinguishable from active work to the delegating caller on its next poll.
*Source FS*: FS-PAK-003

**SRS-PAK-007 — First-run prompt suppression and profile propagation**
WHEN the system spawns a peer-agent instance with a fresh instance environment, THE SYSTEM SHALL suppress interactive first-run prompts that would block task dispatch, AND SHALL apply the user's previously configured editor profile to the new instance environment when one exists.
*Source FS*: FS-PAK-005

**SRS-PAK-008 — Brief delivery integrity**
WHEN a delegated task is dispatched to the peer agent, THE SYSTEM SHALL deliver the delegating caller's complete question text to the peer agent, regardless of question length.
*Source FS*: FS-PAK-004
