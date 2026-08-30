---
artifact-type: ticket
ticket-subtype: adr-direct
lineage-rules:
  - "Ticket must reference at least one source ADR"
  - "Spec field is intentionally omitted: this ticket traces directly to an ADR"
---

# 03 — Path normalization and sub-workspace reuse in ensure_ready

**Source ADR**: docs/adr/0073-sub-workspace-reuse-with-path-normalization.md

## What to build

Replace the raw string workspace comparison in `InstanceManager.ensure_ready()` with normalized paths and a sub-workspace containment short-circuit, per the ADR-0073 API contract.

- Add `self._open_root: Path | None = None` in `__init__` — the folder actually open in VS Code (last path passed to `code`).
- In `ensure_ready()`, resolve the requested workspace with `Path(workspace).resolve()`.
- Short-circuit: if `self._alive and self._open_root and workspace_resolved.is_relative_to(self._open_root)`, set `self.workspace = str(workspace_resolved)` (metadata only, `_open_root` unchanged) and return — no `--reuse-window` call, no reload. `is_relative_to` covers exact equality, so this replaces the old `self.workspace == workspace` guard entirely.
- Otherwise proceed with spawn/reuse using `str(workspace_resolved)` as the folder argument; after spawn, set both `self.workspace = str(workspace_resolved)` and `self._open_root = workspace_resolved`.
- Storage invariants: `self.workspace` is always a `str(Path.resolve())` result; only spawn/reuse-window updates `_open_root`, never the short-circuit branch — this keeps sibling sub-workspaces (`/project/src` then `/project/tests` under open root `/project`) inside the short-circuit regardless of order.
- Existing test fix: `test_ensure_ready_skips_spawn_when_already_open` (test_instance.py:65–72) relies on the short-circuit guard but does not set `_open_root`. Update it: set `manager._open_root = tmp_path / 'repo'` before calling `ensure_ready(str((tmp_path / 'repo').resolve()), ...)` so the guard fires and the no-spawn assertion holds. Use pytest's `tmp_path` fixture for all workspace paths in all three tests; it returns an absolute, resolved path on all platforms with no macOS `/tmp` → `/private/tmp` symlink issues.

## Requirements

SRS-PAK-004, SRS-PAK-005

## Blocked by

02 — shared-config-symlink

## Status

done

## Checklist

- [x] `tests/test_instance.py:65–72` updated: set `manager._open_root = tmp_path / 'repo'` before calling `ensure_ready(str((tmp_path / 'repo').resolve()), ...)` so the short-circuit guard `is_relative_to` fires and the no-spawn assertion holds — test `test_ensure_ready_skips_spawn_when_already_open` passed
- [x] `tests/test_instance.py:75–92` (`test_ensure_ready_reuses_window_on_workspace_switch`) updated to use `tmp_path` instead of hardcoded `/tmp/repo` and `/tmp/new` paths; still asserts reuse-window behavior — test `test_ensure_ready_reuses_window_on_workspace_switch` passed
- [x] Trailing-slash and symlink-alias workspaces no longer trigger a reload (tests with tmp_path symlinks, assertions compare resolved paths) — tests `test_ensure_ready_path_normalization_trailing_slash`, `test_ensure_ready_path_normalization_symlink_alias` passed
- [x] Sub-workspace of open root: no subprocess call, `workspace` updated, `_open_root` unchanged — test `test_ensure_ready_skips_spawn_for_sub_workspace` passed
- [x] Sibling sub-workspaces both short-circuit under the same open root — test `test_ensure_ready_sibling_sub_workspaces_both_short_circuit` passed
- [x] Disjoint workspace still triggers `--reuse-window` and updates `_open_root` — test `test_ensure_ready_reuses_window_on_workspace_switch` passed (asserts `--reuse-window` in args and `_open_root` updated)
- [x] First spawn sets both `workspace` and `_open_root` to the resolved path — test `test_ensure_ready_path_normalization_trailing_slash` passed (asserts `_open_root == repo.resolve()` after first spawn)
- [x] Full pytest suite passes — 91 passed, 0 failed (`.venv/bin/pytest`)
