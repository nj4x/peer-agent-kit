---
artifact-type: fs
lineage-rules: root
---

# peer-agent-kit — Functional Specification 001

Product-level outcomes for peer-agent delegation. FS states outcomes and capabilities; system contracts live in the companion SRS; invocation and realization mechanisms live in ADRs.

## Requirements

**FS-PAK-001 — Concurrent session delegation**
When a user runs multiple Claude Code sessions at the same time, each session shall be able to delegate work to a peer agent independently, without one session's delegation interfering with another's.

**FS-PAK-002 — Persistent peer-agent identity**
The peer agent shall retain its configuration — credentials, custom instructions, and accumulated memory — across delegation sessions, so the user does not re-configure or re-authenticate it per session.

**FS-PAK-003 — Visibility of peer-agent blockage** *(Deferred)*
When a delegated task stops progressing because the peer agent needs human input, the delegating caller shall be able to distinguish that state from the peer agent actively working, so the user can be alerted instead of waiting for a timeout.
*Status*: no realizing ADR. The peer agent (cline-sr) is installed from a private Marketplace with no local build access — its dispatch code cannot be patched to emit a waiting-for-input signal. Revisit if cline-sr upstream adds such a hook, or if a passive-detection design (watching existing output/log signals) is proposed.

**FS-PAK-004 — Low-friction repeated delegation**
Delegating successive tasks within the same project tree (including subdirectories of an already-open workspace) shall not incur avoidable instance restarts or loss of peer-agent working context.

**FS-PAK-005 — Unattended instance readiness with the user's editor profile**
When a session spawns its dedicated peer-agent window, the window shall become ready for delegated work without requiring interactive first-run responses from the user, and shall reflect the user's once-configured editor preferences (theme, pane layout, keybindings) without per-session reconfiguration.
