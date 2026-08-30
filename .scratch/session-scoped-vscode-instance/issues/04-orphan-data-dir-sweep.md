---
artifact-type: ticket
ticket-subtype: adr-direct
lineage-rules:
  - "Ticket must reference at least one source ADR"
  - "Spec field is intentionally omitted: this ticket traces directly to an ADR"
---

# 04 — Orphaned session data-dir sweep on server start

**Source ADR**: docs/adr/0071-session-scoped-vscode-instance.md

## What to build

Add a best-effort sweep in `InstanceManager.__init__` that removes `~/.vscode-agent-bridge/data-<pid>` directories whose embedded PID is no longer a running process, so dead servers do not accumulate orphaned session dirs.

- Enumerate `~/.vscode-agent-bridge/data-*` siblings; parse the PID suffix (skip entries that do not parse as an integer).
- Probe liveness with `os.kill(pid, 0)`, guarding the call itself with `try/except (OSError, OverflowError)`: `ProcessLookupError` means dead (sweep it); `PermissionError` means alive under another user (keep it); `OverflowError` (PID value outside the platform's `pid_t` range — the integer parse succeeds but the OS call cannot accept it) means treat as dead (keep the own-dir guard as the only protection against false sweep); success means alive (keep it). Never sweep the current process's own dir.
- Remove dead dirs recursively (stale symlinks inside go with them; a symlink is unlinked, never followed — the canonical dir's contents are never touched).
- The canonical dir `~/.vscode-agent-bridge/data` does not match the `data-*` PID pattern and is never a sweep candidate.
- Error policy: catch per-directory removal failures and unexpected `os.kill` exceptions (including `OverflowError`), log at WARNING, continue with the remaining dirs. The sweep never raises from `__init__` — cleanup is best-effort, not a liveness precondition.
- When the OS recycles a PID from an exited MCP server, the sweep skips the pre-existing `data-{pid}` dir (correctly, via the own-dir guard). The new session then reuses the old session's data dir. Test that `ensure_ready` handles this correctly: idempotent symlink guard succeeds, `_seed_settings` merge succeeds, no exceptions raised.
- **Accepted gap**: the sweep probes MCP-server PID liveness, not the VS Code Electron child process. If a server dies without its VS Code window (crash, SIGKILL, OOM), the window can outlive it; the next sweep (from any server) sees the dead server PID and removes its data dir out from under the still-running window. This matches ADR-0071's own framing — "best-effort, not a liveness precondition" — and is accepted rather than mitigated: the alternative (tracking and probing the VS Code child PID) adds a second liveness signal that ADR-0071 does not specify. Revisit only if this is observed in practice.

## Requirements

SRS-PAK-001, SRS-PAK-002

## Blocked by

01 — pid-scoped-data-dir, 02 — shared-config-symlink

## Status

ready-for-agent

## Checklist

- [ ] Dirs with dead PIDs removed on `InstanceManager` construction
- [ ] Dirs with live PIDs, the own-PID dir, and the canonical `data` dir untouched
- [ ] Non-integer suffixes skipped without error
- [ ] Oversized PID suffix (parses as int but out of `pid_t` range, e.g. `data-9999999999`) triggers `OverflowError` from `os.kill`, caught, dir swept, no exception raised
- [ ] Symlinks inside swept dirs unlinked, link targets untouched (test with a symlink into a surviving dir)
- [ ] Removal failure logged at WARNING, sweep continues, `__init__` does not raise
- [ ] PID-reuse scenario: pre-create `~/.vscode-agent-bridge/data-{self._pid}` with a correct symlink and valid settings.json; construct InstanceManager with the same PID; verify the sweep does not remove it (own-dir guard), `ensure_ready` succeeds (idempotent symlink guard, `_seed_settings` merge), no exceptions raised
- [ ] Full pytest suite passes
