---
artifact-type: ticket
ticket-subtype: adr-direct
lineage-rules:
  - "Ticket must reference at least one source ADR"
  - "Spec field is intentionally omitted: this ticket traces directly to an ADR"
---

# 01 — PID-scoped VS Code data dir per MCP server process

**Source ADR**: docs/adr/0071-session-scoped-vscode-instance.md

## What to build

Replace the fixed global `DATA_DIR` in `mcp/vscode-agent-bridge/bridge/instance.py` with a session-scoped path keyed by the MCP server process PID, so each server spawns its own isolated VS Code window.

- In `InstanceManager.__init__`, set `self._pid = os.getpid()` and `self._data_dir = Path(os.path.expanduser(f"~/.vscode-agent-bridge/data-{self._pid}"))`.
- Remove the module-level `DATA_DIR` constant (instance.py:21).
- Convert `_seed_settings()` from a module function to an instance method reading `self._data_dir`.
- Spawn args use `str(self._data_dir)` for `--user-data-dir`.
- Include `data_dir` in the spawn log line so multi-session logs identify which window belongs to which server (ADR-0075 observability note).
- Rewrite the test infrastructure in `tests/test_instance.py` that depends on the removed symbols:
  - The autouse `tmp_data_dir` fixture (lines 27–31) monkeypatches `bridge.instance.DATA_DIR`; after removal it raises `AttributeError` on every test in the file. Replace it with an autouse fixture that redirects each `InstanceManager`'s data dir into `tmp_path` — e.g. monkeypatch `Path.expanduser` / the home base so `self._data_dir` computes under `tmp_path`, or monkeypatch `InstanceManager.__init__` post-construction via a factory fixture that sets `manager._data_dir = tmp_path / "data"`. Keep it autouse so no test ever writes to the real `~/.vscode-agent-bridge/`.
  - Drop `_seed_settings` from the module import list (line 11); it no longer exists as a free function.
  - Distinct-data-dir test: the PID→dir mapping cannot be exercised by constructing two managers in one test process (`os.getpid()` returns the same value for both), and neither fixture strategy above varies the PID. Monkeypatch `os.getpid` itself: `monkeypatch.setattr(os, 'getpid', lambda: 1001)` before constructing the first manager, then `monkeypatch.setattr(os, 'getpid', lambda: 1002)` before constructing the second; assert `manager_a._data_dir != manager_b._data_dir` and that each dir name embeds its mocked PID (`data-1001`, `data-1002`). This test bypasses the post-construction `_data_dir` override (it must observe the computed value), but still redirects the home base into `tmp_path` so nothing touches the real home dir.

## Requirements

SRS-PAK-001, SRS-PAK-002

## Blocked by

none

## Status

done

## Checklist

- [x] Module-level `DATA_DIR` constant removed; all references derive from `self._data_dir` — code: `bridge/instance.py`, `grep -rn "DATA_DIR" mcp/vscode-agent-bridge` returns no hits
- [x] `_seed_settings` is an instance method writing to `self._data_dir / "User" / "settings.json"` — code: `InstanceManager._seed_settings`, `bridge/instance.py:69-80`
- [x] Spawn log line includes the data dir path — code: `bridge/instance.py:96-102` (`data_dir=%s`)
- [x] `tests/test_instance.py`: autouse `tmp_data_dir` fixture no longer monkeypatches `bridge.instance.DATA_DIR`; replacement fixture redirects each manager's `_data_dir` into `tmp_path` (autouse, so no test touches the real home dir) — test suite passed, 79 passed
- [x] `tests/test_instance.py`: `_seed_settings` import removed; the three seed-settings tests (defaults, preserves-overrides, unparsable-untouched) call `manager._seed_settings()` on an `InstanceManager` instance and assert against that manager's `_data_dir / "User" / "settings.json"` — tests `test_seed_settings_creates_file_with_defaults`, `test_seed_settings_preserves_existing_overrides`, `test_seed_settings_leaves_unparsable_file_untouched` passed
- [x] `tests/test_instance.py`: `test_ensure_ready_seeds_settings_before_spawn` asserts against the manager's `_data_dir`, not the old fixture return value — test passed
- [x] Tests: two `InstanceManager` objects constructed with monkeypatched `os.getpid` (lambda returning 1001, then 1002) compute distinct data dirs, each embedding its mocked PID — test `test_data_dir_is_scoped_to_process_pid` passed
- [x] Tests: seed settings land in the PID-scoped dir — test `test_seed_settings_lands_in_pid_scoped_dir` passed
- [x] Full pytest suite passes — `.venv/bin/pytest -q`: 79 passed
