---
artifact-type: ticket
ticket-subtype: adr-direct
lineage-rules:
  - "Ticket must reference at least one source ADR"
  - "Spec field is intentionally omitted: this ticket traces directly to an ADR"
---

# 02 — Shared cline-sr config via pre-spawn symlink

**Source ADR**: docs/adr/0072-shared-cline-sr-config-symlink.md

## What to build

Add `InstanceManager._create_config_symlink()` so every PID-scoped session shares one canonical cline-sr config directory, wired before the window spawns.

- Add module constant `CANONICAL_CONFIG_DIR = Path(os.path.expanduser("~/.vscode-agent-bridge/data/User/globalStorage/saoudrizwan.claude-dev"))`.
- Implement `_create_config_symlink()` per the ADR-0072 API contract:
  - Bootstrap: `CANONICAL_CONFIG_DIR.mkdir(parents=True, exist_ok=True)` before linking (no VS Code process ever creates the canonical dir itself).
  - Guard with `is_symlink()` (not `exists()`): a link already pointing at the canonical dir is an idempotent no-op; a link pointing elsewhere raises `RuntimeError`; a real directory raises `RuntimeError` (never silently shadow shared config).
  - Identity check for existing symlink: compare `src.resolve() == tgt.resolve()` (both paths resolve through the filesystem, so relative targets resolve correctly against their respective parents, not CWD). Note: ADR-0072's code sample shows `Path(os.readlink(src)).resolve() == tgt.resolve()`, which is incorrect for relative link targets — `os.readlink` returns the raw link target, and resolving it anchors to the current working directory, not to `src.parent`. This ticket supersedes that with `src.resolve()`, which follows the link through the filesystem regardless of whether the target is absolute or relative, with no CWD dependency.
  - Create `src.parent` with `mkdir(parents=True, exist_ok=True)`, then `src.symlink_to(tgt)`.
- Call `_create_config_symlink()` followed by `_seed_settings()` in `ensure_ready()` on first spawn only (`if not self._alive`), before the subprocess is launched.
- Failure policy: any exception from either call propagates out of `ensure_ready` — the task fails visibly rather than running with a blank config.

## Tests

Redirect both `bridge.instance.CANONICAL_CONFIG_DIR` and `src.parent` (i.e. `manager._data_dir`) into `tmp_path` in every case below — no test touches the real home directory.

1. **Fresh install**: neither `CANONICAL_CONFIG_DIR` nor `src` exists — `_create_config_symlink()` creates the canonical dir, then the symlink; assert `src.is_symlink()` and `src.resolve() == CANONICAL_CONFIG_DIR.resolve()`.
2. **Idempotent re-entry**: `src` already symlinks to the canonical dir (test with both an absolute and a relative link target) — second call is a no-op, no exception.
3. **Stale link**: `src` symlinks elsewhere — call raises `RuntimeError`.
4. **Real directory**: `src` exists as a real directory (not a symlink) — call raises `RuntimeError`.

## Requirements

SRS-PAK-003

## Blocked by

01 — pid-scoped-data-dir

## Status

ready-for-agent

## Checklist

- [ ] Tests section's four cases (fresh install, idempotent re-entry, stale link, real directory) implemented and passing
- [ ] Symlink created at `<data_dir>/User/globalStorage/saoudrizwan.claude-dev` pointing at the canonical dir, before spawn
- [ ] Canonical dir auto-created on fresh install
- [ ] Idempotent re-entry when the correct link already exists (test with both absolute and relative symlink targets, both resolved via filesystem)
- [ ] `RuntimeError` on stale link to a different target
- [ ] `RuntimeError` on pre-existing real directory
- [ ] `CANONICAL_CONFIG_DIR` monkeypatched to `tmp_path / 'canonical'` by the ticket-01 autouse fixture (or a sibling autouse fixture) before each test runs; no test ever touches the real `~/.vscode-agent-bridge/data/User/globalStorage/`
- [ ] Exceptions propagate out of `ensure_ready` (test asserts task-visible failure, no silent continue)
- [ ] Full pytest suite passes
