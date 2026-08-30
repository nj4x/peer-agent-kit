# CONTEXT.md

Domain terminology for peer-agent-kit.

## Ubiquitous language


**Bridge**:
The single orchestration object per MCP server process owning the `BridgeQueue`, `InstanceManager`, and `HookServer`. Exposes `ask()` / `submit()` / `poll()` / `close()` methods for the four MCP tools and runs the pump/sweep loop that dispatches queued tasks to the dedicated VS Code window.
_Avoid_: orchestrator, facade, coordinator

**Session** (observability):
One MCP server process lifetime, identified by its start timestamp (`YYYYMMDDTHHMMSS`). Session-scoped events (WS connect/disconnect, sweep runs, instance spawn/exit) go to a global session log at `~/.vscode-agent-bridge/logs/<session-id>.log`, independent of any workspace.
_Avoid_: run, instance (conflicts with `InstanceManager`'s Instance)

**Task Log**:
The per-task log file under `~/.vscode-agent-bridge/<normalized-workspace-dir-name>/<task-id>.log`, recording queue status transitions and hook POSTs for one task. Its events are also mirrored into the current Session's log for a single chronological view.
_Avoid_: task file, record log
