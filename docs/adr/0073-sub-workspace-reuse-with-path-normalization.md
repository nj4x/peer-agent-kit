---
artifact-type: adr
lineage-rules:
  - "ADR must reference at least one source SRS item"
source-srs: .data/requirements/peer-agent-kit-SRS-001.md
---

# ADR-0073: Sub-workspace Reuse with Path Normalization

**Status**: Accepted

**Source SRS**: SRS-PAK-004, SRS-PAK-005

## Context

`InstanceManager.ensure_ready(workspace)` currently compares workspaces using raw string equality (`self.workspace == workspace`). This means:
1. Trailing slashes cause false mismatches (`/foo` vs `/foo/`)
2. Symlink aliases cause false mismatches (`/real/path` vs `/symlink/alias`)
3. No support for sub-workspace optimization: if workspace B is nested inside already-open workspace A, the current logic still calls `code --reuse-window <B>`, reloading the extension host and destroying cline-sr's in-memory state — even though B's files are already accessible under A.

## Decision

**Normalize both paths and implement sub-workspace containment check:**

1. **Path normalization**: Call `Path.resolve()` on both the current and requested workspace. Store the resolved path. Comparison and containment checks operate on resolved paths.
2. **Sub-workspace reuse**: When `ensure_ready(workspace)` is called with a workspace B that is nested under the currently open workspace A (`Path(B).resolve().is_relative_to(Path(A).resolve())`), skip the `code --reuse-window` call entirely. Just update `self.workspace` to B and proceed — cline-sr already has the parent directory open and can access B's files.

## Consequences

- **Pro**: Eliminates false path mismatches due to trailing slashes or symlinks — one source of subtle path-equality bugs.
- **Pro**: Avoids unnecessary window reloads when delegating to a sub-workspace. The 30-second `SPAWN_TIMEOUT` reconnect wait is eliminated, and cline-sr retains its in-memory conversation context.
- **Pro**: Common delegation pattern (Claude Code working in `/project`, delegate to `/project/src/component`) now runs without window reload.
- **Con**: This is an integration contract, not just a task-correctness nicety: cline-sr receives no workspace-root-change signal on the sub-workspace path, so it resolves relative paths against the parent workspace A. **Caller constraint**: task prompts targeting sub-workspace B must reference files by absolute path or by path relative to A. The delegating skill (SKILL.md briefing guidance) and CONTEXT.md must document this constraint.
- **Con**: `Path.resolve()` calls filesystem stat for symlink resolution — negligible overhead but worth noting for high-call-rate scenarios (not applicable here; `ensure_ready` is called once per delegated task).

## API Contract

`InstanceManager.ensure_ready()` refactored:
```python
async def ensure_ready(self, workspace: str, port: int) -> None:
    """Spawn or reuse the dedicated window so `workspace` is open in it."""
    workspace_resolved = Path(workspace).resolve()
    # self._open_root: Path | None — resolved path of the folder actually open in
    # VS Code (set on every spawn/reuse-window, never by the sub-workspace branch)
    
    # Sub-workspace check: if new workspace is nested in open root, skip window reload.
    # self._open_root tracks the actual VS Code folder (the last path passed to `code`);
    # self.workspace is caller-facing metadata and is updated independently.
    if self._alive and self._open_root and workspace_resolved.is_relative_to(self._open_root):
        self.workspace = str(workspace_resolved)  # update metadata only; _open_root unchanged
        return
    
    # Different workspace: open in reused window (or spawn if not alive)
    # (Note: is_relative_to also returns True for exact equality, so no separate
    # exact-match guard is needed — the branch above already handles it.)
    self._connected.clear()
    if not self._alive:
        self._create_config_symlink()   # first-spawn only, pre-spawn (ADR-0071/0072)
        self._seed_settings()
    args = [self._code_bin, "--user-data-dir", str(self._data_dir)]
    if self._alive:
        args.append("--reuse-window")
    args.append(str(workspace_resolved))
    
    # ... existing spawn logic ...
    self.workspace = str(workspace_resolved)
    self._open_root = workspace_resolved   # record actual VS Code folder for future containment checks
    # ... existing await connect logic ...
```

Storage invariants:
- `self.workspace` is always a `str(Path.resolve())` result — normalized absolute path, no trailing slashes, symlinks resolved. It is caller-facing metadata (last requested workspace).
- `self._open_root: Path | None` is the folder actually open in VS Code. Only spawn/reuse-window updates it; the sub-workspace short-circuit never does. This keeps sibling sub-workspaces (`/project/src` then `/project/tests` under open root `/project`) inside the short-circuit regardless of delegation order.

**Supersession note**: this pseudocode replaces the raw `self.workspace == workspace` early-return shown in ADR-0071's API contract — an implementer must use this normalized containment logic, not ADR-0071's placeholder guard.

## Documentation actions

- `skills/peer-agent/SKILL.md`: add briefing guidance — task prompts targeting a sub-workspace must reference files by absolute path or by path relative to the open root.
- `CONTEXT.md`: document the sub-workspace dispatch behavior (no window reload, no workspace-root-change signal to cline-sr) and the same path constraint.

## Related

- **ADR-0071**: Session-scoped VS Code instance (depends on reliable path comparison)
