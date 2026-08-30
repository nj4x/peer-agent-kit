---
artifact-type: adr
lineage-rules:
  - "ADR must reference at least one source SRS item"
source-srs: .data/requirements/peer-agent-kit-SRS-001.md
---

# ADR-0072: Shared cline-sr Config via Symlink

**Status**: Accepted

**Source SRS**: SRS-PAK-003

## Context

When multiple VS Code instances open under peer-agent-kit delegation (one per MCP server process), each has its own `--user-data-dir` to maintain isolation (ADR-0071). Within that user-data directory, VS Code stores extension-specific state at `<user-data-dir>/User/globalStorage/<publisher>.<extension-name>/`.

For cline-sr (publisher `saoudrizwan`, name `claude-dev`), this is `User/globalStorage/saoudrizwan.claude-dev/`. This directory holds:
- API keys and authentication tokens (Claude, browser tools, etc.)
- Custom instructions and workspace memory
- Extension preferences and configuration

Creating a fresh copy in each session's `--user-data-dir` means each window gets a blank state: no API keys, no memory of prior conversations, no custom instructions — defeating the purpose of having shared agent context.

## Decision

**Symlink each session's `User/globalStorage/saoudrizwan.claude-dev` to a canonical shared directory** (`~/.vscode-agent-bridge/data/User/globalStorage/saoudrizwan.claude-dev`).

All sessions read/write cline-sr's config from the same underlying directory, maintaining unified API keys, memory, and preferences. The symlink is created by `InstanceManager` **before** the VS Code window spawns (ADR-0071) — pre-spawn creation eliminates the race with VS Code's own globalStorage initialization, which begins as soon as the extension host activates.

**Bootstrap**: with PID-scoped instances, no VS Code process ever uses `~/.vscode-agent-bridge/data` as its `--user-data-dir`, so the canonical directory is never created by VS Code itself. `_create_config_symlink()` therefore creates `CANONICAL_CONFIG_DIR` (with `mkdir(parents=True, exist_ok=True)`) before linking, guaranteeing the symlink target exists on a fresh install; cline-sr's first write through the link populates it.

## Consequences

- **Pro**: All sessions share cline-sr's API keys, workspace memory, and preferences without duplication. No need to re-enter credentials or custom instructions per session.
- **Pro**: Conversation history and agent memory are persistent across session boundaries — a session can resume where a prior session left off.
- **Con**: Concurrent sessions racing on the same `saoudrizwan.claude-dev` directory could corrupt state if two write simultaneously. Accepted because cline-sr's own persistence layer (VS Code `globalState`/`secrets` backed by per-key writes, plus discrete task-history files) writes small independent files per key — concurrent sessions touch disjoint keys in practice, and a torn write corrupts at most one key, not the store. FS-PAK-002 (config retention) is therefore met for realistic workloads. Full mitigation (advisory lock or copy-on-write) is recorded as a known gap — revisit if a corruption is ever observed.
- **Con**: If the canonical directory is deleted or corrupted, all sessions lose state immediately (no per-session copy to fall back to).

## API Contract

No public API change; internal to `InstanceManager._create_config_symlink()` (ADR-0071).

Canonical config dir constant:
```python
CANONICAL_CONFIG_DIR = Path(os.path.expanduser("~/.vscode-agent-bridge/data/User/globalStorage/saoudrizwan.claude-dev"))
```

Symlink creation (in `InstanceManager`, called before spawn — ADR-0071):
```python
def _create_config_symlink(self) -> None:
    """Symlink this session's globalStorage to canonical cline-sr config."""
    tgt = CANONICAL_CONFIG_DIR
    tgt.mkdir(parents=True, exist_ok=True)   # bootstrap: target must exist on fresh install
    src = self._data_dir / "User" / "globalStorage" / "saoudrizwan.claude-dev"
    src.parent.mkdir(parents=True, exist_ok=True)
    if src.is_symlink():
        if Path(os.readlink(src)).resolve() == tgt.resolve():
            return                            # already wired (idempotent re-entry)
        raise RuntimeError(f"{src} is a symlink to {os.readlink(src)}, "
                           f"expected {tgt}; remove the stale link")
    if src.exists():
        # a real dir exists (e.g. VS Code initialized it in a previous partial run):
        # do not silently shadow shared config — fail loudly per ADR-0071 failure policy
        raise RuntimeError(f"{src} exists as a real directory, expected symlink; "
                           "remove or migrate it before delegating")
    src.symlink_to(tgt)
```

Guard semantics: `is_symlink()` (not `exists()`) distinguishes an already-placed link from a real directory VS Code may have created; a real directory is an error, not a silent skip. Because the call happens before the first spawn of this session's window, VS Code cannot race the link creation within a session.

## Related

- **ADR-0071**: Session-scoped VS Code instance (PID-keyed data dir)
