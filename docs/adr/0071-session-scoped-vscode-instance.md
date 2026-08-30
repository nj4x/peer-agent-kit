---
artifact-type: adr
lineage-rules:
  - "ADR must reference at least one source SRS item"
source-srs: .data/requirements/peer-agent-kit-SRS-001.md
---

# ADR-0071: Session-scoped VS Code Instance per MCP Server Process

**Status**: Accepted

**Source SRS**: SRS-PAK-001, SRS-PAK-002

## Context

When two Claude Code IDE sessions run concurrently in the same user account, each spawns its own vscode-agent-bridge MCP server process. Both servers call `code --user-data-dir ~/.vscode-agent-bridge/data`, intending to open a dedicated window for peer-agent delegation.

VS Code's single-instance-per-user-data-dir enforcement means the second `code` CLI invocation detects the first server's window already occupying `~/.vscode-agent-bridge/data` and hands off to it instead of spawning a new process. The result: both servers share one window and one extension host process.

The extension activates once and captures `BRIDGE_PORT` from its process environment (set by the first server). When the second server dispatches a task, its `HookServer` port is never passed to the extension — hook POSTs go to the first server's port, and the second server's task times out with `instance_down`.

## Decision

**Use session-scoped `DATA_DIR` keyed by MCP server process PID**, not a fixed global path.

Each MCP server process will:
1. Compute `DATA_DIR = Path(os.path.expanduser(f"~/.vscode-agent-bridge/data-{os.getpid()}"))` at initialization
2. **Before spawning**, create a symlink at `<DATA_DIR>/User/globalStorage/saoudrizwan.claude-dev` → the canonical config dir `~/.vscode-agent-bridge/data/User/globalStorage/saoudrizwan.claude-dev` (see ADR-0072). Creating it before spawn eliminates the race with VS Code's own globalStorage initialization.
3. Write seed settings into the session-scoped dir (`_seed_settings` operates on `self._data_dir`, not a module-level constant), so first-run prompts are suppressed in the PID-scoped window.
4. Pass this path to `code --user-data-dir <DATA_DIR>`

VS Code will see each PID-scoped `DATA_DIR` as a distinct user-data directory, triggering a fresh Electron process with its own `--user-data-dir` lock file and isolated environment variables. Each server's `BRIDGE_PORT` reaches its own window's extension.

## Consequences

- **Pro**: True per-session isolation; two concurrent Claude Code delegations work independently. No code change to Claude Code itself — the server process is responsible for its own `DATA_DIR` path. Matches server lifetime exactly (PID dies when server dies).
- **Pro**: Extension state (cline-sr's settings, auth, workspace memory) is symlinked from canonical dir, so all sessions share the same cline-sr config/API keys without duplicating storage.
- **Con**: Multiple VS Code windows consume more resources (RAM, background processes). For typical use (one interactive session + one background automation), acceptable; for many concurrent sessions (>5), resource pressure rises.
- **Con**: Orphaned `data-<pid>` directories accumulate as servers die. Mitigation: `InstanceManager.__init__` sweeps `~/.vscode-agent-bridge/data-*` directories whose embedded PID is no longer a running process (`os.kill(pid, 0)` probe) — self-healing, no uninstall.sh dependency. Stale symlinks inside swept dirs are removed with them; the canonical dir is never touched by the sweep. Sweep errors (per-directory removal failures, unexpected `os.kill` exceptions) are caught per-directory, logged at WARNING, and never raise from `__init__` — best-effort cleanup, not a liveness precondition. PID reuse can leave at most one stale dir per recycled PID; the dir is inert (no running VS Code holds its lock) and is swept on a later start once the PID's new occupant exits.

## API Contract

`InstanceManager.__init__()` changes:
```python
def __init__(self, code_bin: str = "code") -> None:
    self._code_bin = code_bin
    self.workspace: str | None = None
    self._alive = False
    self._connected = asyncio.Event()
    self._proc: asyncio.subprocess.Process | None = None
    self._pid = os.getpid()
    self._data_dir = Path(os.path.expanduser(f"~/.vscode-agent-bridge/data-{self._pid}"))
    self._open_root: Path | None = None   # actual VS Code folder (see ADR-0073)
```

`ensure_ready()` prepares the session dir before spawn:
```python
async def ensure_ready(self, workspace: str, port: int) -> None:
    """Spawn or reuse the dedicated window so `workspace` is open in it."""
    # NOTE: the early-return / workspace-comparison logic is superseded by
    # ADR-0073 (path normalization + sub-workspace containment); the guard
    # shown here is a placeholder, not the implementation contract.
    if self._alive and self.workspace == workspace:
        return
    
    if not self._alive:
        # First spawn only: prepare session dir BEFORE spawn.
        # Errors here are FATAL — propagate to the caller as a spawn failure
        # rather than continuing with a blank cline-sr config.
        self._create_config_symlink()   # see ADR-0072 for guard and bootstrap semantics
        self._seed_settings()           # writes to self._data_dir, not a module constant
    
    # ... existing spawn logic using self._data_dir ...
    # ... existing await connect logic ...
```

**Failure policy**: any exception from `_create_config_symlink()` or `_seed_settings()` propagates out of `ensure_ready` — the task fails visibly (`instance_down`/`internal_error`) instead of silently running with an isolated blank config.

`_seed_settings()` becomes an instance method reading `self._data_dir` (the current module-level `DATA_DIR` constant at `instance.py:21` is removed; both `_seed_settings` and the spawn args derive from `self._data_dir`).

## Related

- **ADR-0072**: Shared cline-sr config via symlink
- **ADR-0073**: Sub-workspace reuse with path normalization
- **ADR-0074**: Waiting-for-input detection via Notification hook
