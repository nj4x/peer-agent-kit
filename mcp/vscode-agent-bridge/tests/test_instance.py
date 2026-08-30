import asyncio
import hashlib
import math
import json
import os
import shutil
import sqlite3
import sys
from pathlib import Path

import pytest

import bridge.instance
from bridge.instance import (
    SEED_SETTINGS,
    InstanceManager,
    InstanceUnreachable,
    SPAWN_TIMEOUT,
)


class FakeProcess:
    def __init__(self) -> None:
        self.returncode: int | None = None
        self.pid = 4242

    async def wait(self) -> int:
        return 0

    def terminate(self) -> None:
        pass


@pytest.fixture(autouse=True)
def tmp_data_dir(tmp_path, monkeypatch):
    # Patches expanduser, not a module constant: _data_dir is now computed
    # per-instance from a PID-scoped `~` path, so no fixed symbol to swap.
    real_expanduser = os.path.expanduser

    def _fake_expanduser(path: str) -> str:
        if path.startswith("~"):
            return str(tmp_path) + path[1:]
        return real_expanduser(path)

    monkeypatch.setattr(os.path, "expanduser", _fake_expanduser)
    monkeypatch.setattr(bridge.instance, "CANONICAL_CONFIG_DIR", tmp_path / "canonical")
    monkeypatch.setattr(bridge.instance, "TEMPLATE_USER_DIR", tmp_path / "template" / "User")
    return tmp_path


def _settings_path(manager: InstanceManager):
    return manager._data_dir / "User" / "settings.json"


def _global_storage_path(manager: InstanceManager):
    return manager._data_dir / "User" / "globalStorage" / "saoudrizwan.claude-dev"


@pytest.fixture
def fake_spawn(monkeypatch):
    calls: list[tuple[tuple, dict]] = []

    async def _create_subprocess_exec(*args, **kwargs):
        calls.append((args, kwargs))
        return FakeProcess()

    monkeypatch.setattr(asyncio, "create_subprocess_exec", _create_subprocess_exec)
    return calls


async def test_ensure_ready_spawns_without_reuse_window_when_dead(fake_spawn):
    manager = InstanceManager(code_bin="code")

    async def connect_soon():
        await asyncio.sleep(0)
        manager.mark_connected()

    task = asyncio.create_task(connect_soon())
    await manager.ensure_ready("/tmp/repo", port=4321)
    await task

    args, kwargs = fake_spawn[0]
    assert "--reuse-window" not in args
    # Path is normalized (symlinks resolved, e.g., /tmp -> /private/tmp on macOS)
    assert args[-1] == str(Path("/tmp/repo").resolve())
    assert kwargs["env"]["BRIDGE_PORT"] == "4321"
    assert manager.workspace == str(Path("/tmp/repo").resolve())
    assert manager.alive


async def test_ensure_ready_skips_spawn_when_already_open(fake_spawn, tmp_path):
    manager = InstanceManager()
    manager._alive = True
    manager._open_root = tmp_path / "repo"
    manager._connected.set()

    await manager.ensure_ready(str((tmp_path / "repo").resolve()), port=4321)
    assert fake_spawn == []


async def test_ensure_ready_skips_spawn_for_sub_workspace(fake_spawn, tmp_path):
    """Sub-workspace nested under open root should skip window reload (ADR-0073)."""
    repo = tmp_path / "repo"
    repo_src = repo / "src"
    repo.mkdir()
    repo_src.mkdir()

    manager = InstanceManager()
    manager._alive = True
    manager.workspace = str(repo.resolve())
    manager._open_root = repo.resolve()  # Parent workspace is open
    manager._connected.set()

    await manager.ensure_ready(str(repo_src), port=4321)

    assert fake_spawn == []  # No spawn for sub-workspace
    assert manager.workspace == str(repo_src.resolve())
    assert manager._open_root == repo.resolve()  # _open_root unchanged


async def test_ensure_ready_sibling_sub_workspaces_both_short_circuit(fake_spawn, tmp_path):
    """Sibling sub-workspaces under the same open root both skip window reload (ADR-0073)."""
    project = tmp_path / "project"
    project_src = project / "src"
    project_tests = project / "tests"
    project.mkdir()
    project_src.mkdir()
    project_tests.mkdir()

    manager = InstanceManager()
    manager._alive = True
    manager._open_root = project.resolve()
    manager._connected.set()

    await manager.ensure_ready(str(project_src), port=4321)
    await manager.ensure_ready(str(project_tests), port=4322)

    assert fake_spawn == []  # neither sibling triggers a spawn/reuse-window call
    assert manager._open_root == project.resolve()  # open root never changes
    assert manager.workspace == str(project_tests.resolve())


async def test_ensure_ready_path_normalization_trailing_slash(fake_spawn, tmp_path):
    """Trailing slashes should not cause false mismatches (ADR-0073)."""
    repo = tmp_path / "repo"
    repo.mkdir()

    manager = InstanceManager()

    async def connect_soon():
        await asyncio.sleep(0)
        manager.mark_connected()

    # First spawn with /repo
    task = asyncio.create_task(connect_soon())
    await manager.ensure_ready(str(repo), port=4321)
    await task

    assert len(fake_spawn) == 1
    assert manager._open_root == repo.resolve()

    # Request with trailing slash - should skip spawn due to normalization
    task = asyncio.create_task(connect_soon())
    await manager.ensure_ready(str(repo) + "/", port=4321)
    await task

    assert len(fake_spawn) == 1  # No additional spawn


async def test_ensure_ready_path_normalization_symlink_alias(fake_spawn, tmp_path):
    """A symlink alias resolving into the open root should not trigger a reload (ADR-0073)."""
    real = tmp_path / "real"
    real.mkdir()
    alias = tmp_path / "alias"
    alias.symlink_to(real)

    manager = InstanceManager()
    manager._alive = True
    manager._open_root = real.resolve()
    manager._connected.set()

    await manager.ensure_ready(str(alias), port=4321)

    assert fake_spawn == []
    assert manager._open_root == real.resolve()  # unchanged
    assert manager.workspace == str(real.resolve())


async def test_ensure_ready_reuses_window_on_workspace_switch(fake_spawn, tmp_path):
    manager = InstanceManager()
    manager._alive = True
    manager._open_root = tmp_path / "old"
    manager.workspace = str(tmp_path / "old")
    manager._connected.set()

    async def connect_soon():
        await asyncio.sleep(0)
        manager.mark_connected()

    task = asyncio.create_task(connect_soon())
    await manager.ensure_ready(str(tmp_path / "new"), port=4321)
    await task

    args, _ = fake_spawn[0]
    assert "--reuse-window" in args
    new_resolved = str((tmp_path / "new").resolve())
    assert args[-1] == new_resolved
    assert manager.workspace == new_resolved
    assert manager._open_root == (tmp_path / "new").resolve()


async def test_ensure_ready_times_out_if_extension_never_connects(fake_spawn, monkeypatch):
    monkeypatch.setattr("bridge.instance.SPAWN_TIMEOUT", 0.01)
    manager = InstanceManager()
    with pytest.raises(InstanceUnreachable):
        await manager.ensure_ready("/tmp/repo", port=4321)
    assert not manager.alive


def test_seed_settings_includes_uri_handler_trust_and_copilot_disable_keys():
    """Regression guard against accidental key drops (ADR-0076, SRS-PAK-007)."""
    assert SEED_SETTINGS["extensions.confirmedUriHandlerExtensionIds"] == ["cline-sr.cline-sr"]
    assert SEED_SETTINGS["github.copilot.enable"] == {"*": False}


def test_seed_settings_creates_file_with_defaults(tmp_data_dir):
    manager = InstanceManager()
    manager._seed_settings()
    written = json.loads(_settings_path(manager).read_text())
    assert written == SEED_SETTINGS


def test_seed_settings_preserves_existing_overrides(tmp_data_dir):
    manager = InstanceManager()
    settings_path = _settings_path(manager)
    settings_path.parent.mkdir(parents=True)
    settings_path.write_text(json.dumps({"update.mode": "manual", "editor.fontSize": 15}))

    manager._seed_settings()
    written = json.loads(settings_path.read_text())
    assert written["update.mode"] == "manual"
    assert written["editor.fontSize"] == 15
    assert written["security.workspace.trust.enabled"] is False


def test_seed_settings_leaves_unparsable_file_untouched(tmp_data_dir):
    manager = InstanceManager()
    settings_path = _settings_path(manager)
    settings_path.parent.mkdir(parents=True)
    settings_path.write_text("{not json")

    manager._seed_settings()
    assert settings_path.read_text() == "{not json"


async def test_ensure_ready_seeds_settings_before_spawn(fake_spawn, tmp_data_dir):
    manager = InstanceManager()

    async def connect_soon():
        await asyncio.sleep(0)
        manager.mark_connected()

    task = asyncio.create_task(connect_soon())
    await manager.ensure_ready("/tmp/repo", port=4321)
    await task

    assert _settings_path(manager).exists()


def test_data_dir_is_scoped_to_process_pid(tmp_data_dir, monkeypatch):
    monkeypatch.setattr(os, "getpid", lambda: 1001)
    manager_a = InstanceManager()

    monkeypatch.setattr(os, "getpid", lambda: 1002)
    manager_b = InstanceManager()

    assert manager_a._data_dir != manager_b._data_dir
    assert manager_a._data_dir.name == "data-1001"
    assert manager_b._data_dir.name == "data-1002"


def test_seed_settings_lands_in_pid_scoped_dir(tmp_data_dir, monkeypatch):
    monkeypatch.setattr(os, "getpid", lambda: 1003)
    manager = InstanceManager()

    manager._seed_settings()

    settings_path = _settings_path(manager)
    assert manager._data_dir.name == "data-1003"
    assert settings_path.exists()
    assert json.loads(settings_path.read_text()) == SEED_SETTINGS


async def test_close_terminates_process(fake_spawn):
    manager = InstanceManager()

    async def connect_soon():
        await asyncio.sleep(0)
        manager.mark_connected()

    task = asyncio.create_task(connect_soon())
    await manager.ensure_ready("/tmp/repo", port=4321)
    await task

    assert manager._proc is not None
    assert manager.alive

    manager.close()
    assert not manager.alive
    assert manager._proc.returncode is None  # still running after terminate


def test_close_idempotent_when_no_proc():
    manager = InstanceManager()
    manager._alive = True
    manager.close()
    assert not manager.alive


def test_mark_disconnected_clears_alive():
    manager = InstanceManager()
    manager.mark_connected()
    assert manager.alive
    manager.mark_disconnected()
    assert not manager.alive


def test_create_config_symlink_fresh_install(tmp_data_dir):
    manager = InstanceManager()
    src = _global_storage_path(manager)
    assert not bridge.instance.CANONICAL_CONFIG_DIR.exists()
    assert not src.exists()

    manager._create_config_symlink()

    assert bridge.instance.CANONICAL_CONFIG_DIR.is_dir()
    assert src.is_symlink()
    assert src.resolve() == bridge.instance.CANONICAL_CONFIG_DIR.resolve()


def test_create_config_symlink_idempotent_absolute_target(tmp_data_dir):
    manager = InstanceManager()
    src = _global_storage_path(manager)
    tgt = bridge.instance.CANONICAL_CONFIG_DIR
    tgt.mkdir(parents=True)
    src.parent.mkdir(parents=True)
    src.symlink_to(tgt.resolve())  # absolute target

    manager._create_config_symlink()  # no-op, no exception

    assert src.resolve() == tgt.resolve()


def test_create_config_symlink_idempotent_relative_target(tmp_data_dir):
    manager = InstanceManager()
    src = _global_storage_path(manager)
    tgt = bridge.instance.CANONICAL_CONFIG_DIR
    tgt.mkdir(parents=True)
    src.parent.mkdir(parents=True)
    relative_target = os.path.relpath(tgt.resolve(), src.parent)
    src.symlink_to(relative_target)  # relative target

    manager._create_config_symlink()  # no-op, no exception

    assert src.resolve() == tgt.resolve()


def test_create_config_symlink_stale_link_raises(tmp_data_dir):
    manager = InstanceManager()
    src = _global_storage_path(manager)
    elsewhere = tmp_data_dir / "elsewhere"
    elsewhere.mkdir()
    src.parent.mkdir(parents=True)
    src.symlink_to(elsewhere)

    with pytest.raises(RuntimeError):
        manager._create_config_symlink()


def test_create_config_symlink_real_directory_raises(tmp_data_dir):
    manager = InstanceManager()
    src = _global_storage_path(manager)
    src.mkdir(parents=True)

    with pytest.raises(RuntimeError):
        manager._create_config_symlink()


async def test_ensure_ready_creates_symlink_before_spawn(tmp_data_dir, monkeypatch):
    manager = InstanceManager()
    src = _global_storage_path(manager)
    symlinked_at_spawn_time = []

    async def _create_subprocess_exec(*args, **kwargs):
        symlinked_at_spawn_time.append(src.is_symlink())
        return FakeProcess()

    monkeypatch.setattr(asyncio, "create_subprocess_exec", _create_subprocess_exec)

    async def connect_soon():
        await asyncio.sleep(0)
        manager.mark_connected()

    task = asyncio.create_task(connect_soon())
    await manager.ensure_ready("/tmp/repo", port=4321)
    await task

    assert symlinked_at_spawn_time == [True]  # link exists by the time spawn is invoked
    assert src.resolve() == bridge.instance.CANONICAL_CONFIG_DIR.resolve()


async def test_ensure_ready_skips_symlink_and_reseed_on_reuse(fake_spawn, tmp_data_dir, monkeypatch):
    manager = InstanceManager()
    manager._alive = True
    manager.workspace = "/tmp/old"
    manager._connected.set()

    calls: list[str] = []
    monkeypatch.setattr(manager, "_create_config_symlink", lambda: calls.append("symlink"))
    monkeypatch.setattr(manager, "_seed_settings", lambda: calls.append("seed"))

    async def connect_soon():
        await asyncio.sleep(0)
        manager.mark_connected()

    task = asyncio.create_task(connect_soon())
    await manager.ensure_ready("/tmp/new", port=4321)
    await task

    assert calls == []  # already-wired session: no re-link, no re-seed on window reuse


async def test_ensure_ready_propagates_symlink_error(fake_spawn, tmp_data_dir, monkeypatch):
    manager = InstanceManager()

    def _boom():
        raise RuntimeError("stale link")

    monkeypatch.setattr(manager, "_create_config_symlink", _boom)

    with pytest.raises(RuntimeError):
        await manager.ensure_ready("/tmp/repo", port=4321)
    assert fake_spawn == []
    assert not manager.alive


# --- orphaned data-dir sweep (04-orphan-data-dir-sweep) ---


def _bridge_root(tmp_data_dir):
    return tmp_data_dir / ".vscode-agent-bridge"


def _fake_kill(outcomes: dict):
    def _kill(pid: int, sig: int) -> None:
        outcome = outcomes.get(pid, ProcessLookupError)
        if outcome is None:
            return  # alive
        raise outcome(f"fake os.kill for pid {pid}")

    return _kill


def test_sweep_removes_dead_pid_dirs(tmp_data_dir, monkeypatch):
    root = _bridge_root(tmp_data_dir)
    dead_dir = root / "data-555"
    dead_dir.mkdir(parents=True)
    (dead_dir / "marker.txt").write_text("x")

    monkeypatch.setattr(os, "getpid", lambda: 1000)
    monkeypatch.setattr(os, "kill", _fake_kill({555: ProcessLookupError}))

    InstanceManager()

    assert not dead_dir.exists()


def test_sweep_keeps_live_pid_own_pid_and_canonical_dirs(tmp_data_dir, monkeypatch):
    root = _bridge_root(tmp_data_dir)
    live_dir = root / "data-600"
    live_dir.mkdir(parents=True)
    canonical_dir = root / "data"
    canonical_dir.mkdir(parents=True)
    (canonical_dir / "marker.txt").write_text("keep me")

    monkeypatch.setattr(os, "getpid", lambda: 700)
    own_dir = root / "data-700"
    own_dir.mkdir(parents=True)

    monkeypatch.setattr(os, "kill", _fake_kill({600: None}))

    InstanceManager()

    assert live_dir.exists()
    assert own_dir.exists()
    assert canonical_dir.exists()
    assert (canonical_dir / "marker.txt").exists()


def test_sweep_skips_non_integer_suffix(tmp_data_dir, monkeypatch):
    root = _bridge_root(tmp_data_dir)
    weird_dir = root / "data-abc"
    weird_dir.mkdir(parents=True)

    monkeypatch.setattr(os, "getpid", lambda: 1000)
    monkeypatch.setattr(os, "kill", _fake_kill({}))

    InstanceManager()  # must not raise

    assert weird_dir.exists()


def test_sweep_oversized_pid_suffix_swept_via_overflow_error(tmp_data_dir, monkeypatch, caplog):
    root = _bridge_root(tmp_data_dir)
    oversized_dir = root / "data-9999999999"
    oversized_dir.mkdir(parents=True)

    monkeypatch.setattr(os, "getpid", lambda: 1000)
    monkeypatch.setattr(os, "kill", _fake_kill({9999999999: OverflowError}))

    with caplog.at_level("WARNING"):
        InstanceManager()  # must not raise

    assert not oversized_dir.exists()
    assert any("9999999999" in record.message for record in caplog.records)


def test_sweep_unlinks_symlink_inside_dead_dir_without_following(tmp_data_dir, monkeypatch):
    root = _bridge_root(tmp_data_dir)
    surviving = root / "data-800"
    surviving.mkdir(parents=True)
    (surviving / "keep.txt").write_text("still here")

    dead_dir = root / "data-555"
    dead_dir.mkdir(parents=True)
    link = dead_dir / "linked"
    link.symlink_to(surviving)

    monkeypatch.setattr(os, "getpid", lambda: 1000)
    monkeypatch.setattr(os, "kill", _fake_kill({555: ProcessLookupError, 800: None}))

    InstanceManager()

    assert not dead_dir.exists()
    assert surviving.exists()
    assert (surviving / "keep.txt").exists()


def test_sweep_removal_failure_logged_warning_and_continues(tmp_data_dir, monkeypatch, caplog):
    root = _bridge_root(tmp_data_dir)
    dead_a = root / "data-555"
    dead_a.mkdir(parents=True)
    dead_b = root / "data-556"
    dead_b.mkdir(parents=True)

    monkeypatch.setattr(os, "getpid", lambda: 1000)
    monkeypatch.setattr(os, "kill", _fake_kill({555: ProcessLookupError, 556: ProcessLookupError}))

    real_rmtree = shutil.rmtree

    def _flaky_rmtree(path, *args, **kwargs):
        if Path(path) == dead_a:
            raise OSError("permission denied")
        return real_rmtree(path, *args, **kwargs)

    monkeypatch.setattr(shutil, "rmtree", _flaky_rmtree)

    with caplog.at_level("WARNING"):
        InstanceManager()  # must not raise

    assert dead_a.exists()  # removal failed, left in place
    assert not dead_b.exists()  # sweep continued past the failure
    assert any("failed to remove" in record.message for record in caplog.records)


async def test_sweep_pid_reuse_own_dir_guard_then_ensure_ready_succeeds(tmp_data_dir, monkeypatch, fake_spawn):
    root = _bridge_root(tmp_data_dir)
    reused_pid = 900
    stale_dir = root / f"data-{reused_pid}"
    canonical_dir = root / "data" / "User" / "globalStorage" / "saoudrizwan.claude-dev"
    canonical_dir.mkdir(parents=True)
    src = stale_dir / "User" / "globalStorage" / "saoudrizwan.claude-dev"
    src.parent.mkdir(parents=True)
    src.symlink_to(canonical_dir)
    settings_path = stale_dir / "User" / "settings.json"
    settings_path.write_text(json.dumps(SEED_SETTINGS))

    monkeypatch.setattr(bridge.instance, "CANONICAL_CONFIG_DIR", canonical_dir)
    monkeypatch.setattr(os, "getpid", lambda: reused_pid)

    kill_calls: list[int] = []

    def _kill(pid: int, sig: int) -> None:
        kill_calls.append(pid)
        raise ProcessLookupError(f"fake os.kill for pid {pid}")

    # Every PID (including a dead reused one) would report dead if probed.
    # The own-dir guard must skip the probe entirely for our own pid.
    monkeypatch.setattr(os, "kill", _kill)

    manager = InstanceManager()
    assert stale_dir.exists()  # own-dir guard: not swept despite os.kill saying dead
    assert reused_pid not in kill_calls  # guard skipped the probe, not just the sweep

    async def connect_soon():
        await asyncio.sleep(0)
        manager.mark_connected()

    task = asyncio.create_task(connect_soon())
    await manager.ensure_ready("/tmp/repo", port=4321)
    await task

    assert manager.alive
    assert json.loads(settings_path.read_text()) == SEED_SETTINGS


# --- template-profile bootstrap (ADR-0076) ---


def _template_dir() -> Path:
    return bridge.instance.TEMPLATE_USER_DIR


def _dest_user_dir(manager: InstanceManager) -> Path:
    return manager._data_dir / "User"


def _make_vscdb(path: Path, value: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(str(path))
    conn.execute("CREATE TABLE kv (k TEXT, v TEXT)")
    conn.execute("INSERT INTO kv VALUES ('key', ?)", (value,))
    conn.commit()
    conn.close()


def _read_vscdb(path: Path) -> str:
    conn = sqlite3.connect(str(path))
    row = conn.execute("SELECT v FROM kv WHERE k = 'key'").fetchone()
    conn.close()
    return row[0]


def test_copy_template_profile_noop_when_template_unconfigured(tmp_data_dir):
    manager = InstanceManager()
    manager._copy_template_profile()
    assert not _dest_user_dir(manager).exists()


def test_copy_template_profile_copies_settings_keybindings_snippets(tmp_data_dir):
    template = _template_dir()
    template.mkdir(parents=True)
    (template / "settings.json").write_text('{"editor.fontSize": 14}')
    (template / "keybindings.json").write_text("[]")
    (template / "snippets").mkdir()
    (template / "snippets" / "python.json").write_text("{}")

    manager = InstanceManager()
    manager._copy_template_profile()

    dest = _dest_user_dir(manager)
    assert dest.joinpath("settings.json").read_text() == '{"editor.fontSize": 14}'
    assert dest.joinpath("keybindings.json").read_text() == "[]"
    assert dest.joinpath("snippets", "python.json").read_text() == "{}"


def test_copy_template_profile_copies_workspace_storage_vscdb_via_backup(tmp_data_dir):
    template = _template_dir()
    template.mkdir(parents=True)
    (template / "settings.json").write_text("{}")
    _make_vscdb(template / "workspaceStorage" / "abc123" / "state.vscdb", "geometry")

    manager = InstanceManager()
    manager._copy_template_profile()

    dest_db = _dest_user_dir(manager) / "workspaceStorage" / "abc123" / "state.vscdb"
    assert dest_db.exists()
    assert _read_vscdb(dest_db) == "geometry"


def test_copy_template_profile_excludes_cline_sr_global_storage_symlink_target(tmp_data_dir):
    template = _template_dir()
    template.mkdir(parents=True)
    (template / "settings.json").write_text("{}")
    (template / "globalStorage" / "saoudrizwan.claude-dev").mkdir(parents=True)
    (template / "globalStorage" / "saoudrizwan.claude-dev" / "state.json").write_text("{}")
    (template / "globalStorage" / "other-ext").mkdir(parents=True)
    (template / "globalStorage" / "other-ext" / "state.json").write_text('{"k": 1}')

    manager = InstanceManager()
    manager._copy_template_profile()

    dest_global = _dest_user_dir(manager) / "globalStorage"
    assert not (dest_global / "saoudrizwan.claude-dev").exists()
    assert (dest_global / "other-ext" / "state.json").read_text() == '{"k": 1}'


def test_copy_template_profile_skips_history(tmp_data_dir):
    template = _template_dir()
    template.mkdir(parents=True)
    (template / "settings.json").write_text("{}")
    (template / "History" / "entry").mkdir(parents=True)

    manager = InstanceManager()
    manager._copy_template_profile()

    assert not (_dest_user_dir(manager) / "History").exists()


def test_copy_template_profile_vscdb_backup_skips_sidecars(tmp_data_dir):
    """Verify .vscdb-wal/-shm/-journal sidecars are not copied (ADR-0076)."""
    template = _template_dir()
    template.mkdir(parents=True)
    (template / "settings.json").write_text("{}")
    _make_vscdb(template / "workspaceStorage" / "ws" / "state.vscdb", "test")
    (template / "workspaceStorage" / "ws" / "state.vscdb-wal").write_text("sidecar")

    manager = InstanceManager()
    manager._copy_template_profile()

    dest = _dest_user_dir(manager)
    assert (dest / "workspaceStorage" / "ws" / "state.vscdb").exists()
    assert not (dest / "workspaceStorage" / "ws" / "state.vscdb-wal").exists()


# --- per-workspace layout seeding (ADR-0078) ---


def _make_empty_window_storage(
    manager: InstanceManager, name: str = "1788116271141", value: str = "layout"
) -> Path:
    db = manager._data_dir / "User" / "workspaceStorage" / name / "state.vscdb"
    _make_vscdb(db, value)
    return db


def test_workspace_storage_id_is_stable_md5_hex(tmp_data_dir, tmp_path):
    manager = InstanceManager()
    folder = tmp_path / "proj"
    folder.mkdir()
    first = manager._workspace_storage_id(folder)
    second = manager._workspace_storage_id(folder)
    assert first == second
    assert len(first) == 32
    assert all(c in "0123456789abcdef" for c in first)


def test_workspace_storage_id_differs_per_folder(tmp_data_dir, tmp_path):
    manager = InstanceManager()
    a = tmp_path / "a"
    b = tmp_path / "b"
    a.mkdir()
    b.mkdir()
    assert manager._workspace_storage_id(a) != manager._workspace_storage_id(b)


def test_workspace_storage_id_none_for_missing_folder(tmp_data_dir, tmp_path):
    manager = InstanceManager()
    assert manager._workspace_storage_id(tmp_path / "gone") is None


@pytest.mark.skipif(sys.platform != "darwin", reason="macOS birthtime formula")
def test_workspace_storage_id_matches_vscode_formula_macos(tmp_data_dir, tmp_path):
    """VS Code (macOS): md5(fsPath + String(birthtime ms)) — workspaces.ts.

    Node rounds fractional ms half-up (dateFromMs adds 0.5), hence the +0.5.
    Formula verified against six real workspaceStorage dirs VS Code created.
    """
    manager = InstanceManager()
    folder = tmp_path / "proj"
    folder.mkdir()
    st = folder.stat()
    ms = math.trunc(st.st_birthtime * 1000 + 0.5)
    expected = hashlib.md5((str(folder) + str(ms)).encode()).hexdigest()
    assert manager._workspace_storage_id(folder) == expected


@pytest.mark.skipif(not sys.platform.startswith("linux"), reason="Linux inode formula")
def test_workspace_storage_id_matches_vscode_formula_linux(tmp_data_dir, tmp_path):
    """VS Code (Linux): md5(fsPath + String(inode)) — birthtime unreliable there."""
    manager = InstanceManager()
    folder = tmp_path / "proj"
    folder.mkdir()
    expected = hashlib.md5((str(folder) + str(folder.stat().st_ino)).encode()).hexdigest()
    assert manager._workspace_storage_id(folder) == expected


def test_seed_workspace_layout_cleans_up_when_workspace_json_write_fails(
    tmp_data_dir, tmp_path, monkeypatch, caplog
):
    manager = InstanceManager()
    _make_empty_window_storage(manager)
    folder = (tmp_path / "proj").resolve()
    folder.mkdir()

    real_write_text = Path.write_text

    def _fail_on_workspace_json(self, *args, **kwargs):
        if self.name == "workspace.json":
            raise OSError("disk full")
        return real_write_text(self, *args, **kwargs)

    monkeypatch.setattr(Path, "write_text", _fail_on_workspace_json)
    with caplog.at_level("WARNING"):
        manager._seed_workspace_layout(folder)  # must not raise

    ws_id = manager._workspace_storage_id(folder)
    assert not (manager._data_dir / "User" / "workspaceStorage" / ws_id).exists()


def test_find_empty_window_state_db_skips_symlinked_dirs(tmp_data_dir, tmp_path):
    manager = InstanceManager()
    outside = tmp_path / "outside"
    _make_vscdb(outside / "state.vscdb", "evil")
    root = manager._data_dir / "User" / "workspaceStorage"
    root.mkdir(parents=True)
    (root / "999").symlink_to(outside)

    assert manager._find_empty_window_state_db() is None


def test_seed_workspace_layout_clones_empty_window_state(tmp_data_dir, tmp_path):
    manager = InstanceManager()
    _make_empty_window_storage(manager, value="arranged-panes")
    folder = (tmp_path / "proj").resolve()
    folder.mkdir()

    manager._seed_workspace_layout(folder)

    ws_id = manager._workspace_storage_id(folder)
    dest = manager._data_dir / "User" / "workspaceStorage" / ws_id
    assert _read_vscdb(dest / "state.vscdb") == "arranged-panes"
    assert json.loads((dest / "workspace.json").read_text()) == {"folder": folder.as_uri()}


def test_seed_workspace_layout_skips_when_dest_exists(tmp_data_dir, tmp_path):
    """D6: an already-seeded (or previously opened) folder keeps its state."""
    manager = InstanceManager()
    _make_empty_window_storage(manager, value="new-layout")
    folder = (tmp_path / "proj").resolve()
    folder.mkdir()
    ws_id = manager._workspace_storage_id(folder)
    existing = manager._data_dir / "User" / "workspaceStorage" / ws_id
    _make_vscdb(existing / "state.vscdb", "pre-existing")

    manager._seed_workspace_layout(folder)

    assert _read_vscdb(existing / "state.vscdb") == "pre-existing"
    assert not (existing / "workspace.json").exists()


def test_seed_workspace_layout_noop_without_empty_window_source(tmp_data_dir, tmp_path):
    manager = InstanceManager()
    folder = (tmp_path / "proj").resolve()
    folder.mkdir()

    manager._seed_workspace_layout(folder)

    ws_id = manager._workspace_storage_id(folder)
    assert not (manager._data_dir / "User" / "workspaceStorage" / ws_id).exists()


def test_seed_workspace_layout_ignores_folder_hash_dirs_as_source(tmp_data_dir, tmp_path):
    """Dirs with workspace.json belong to real folders, never the seed source."""
    manager = InstanceManager()
    src_dir = manager._data_dir / "User" / "workspaceStorage" / "aabbcc"
    _make_vscdb(src_dir / "state.vscdb", "other-folder")
    (src_dir / "workspace.json").write_text('{"folder": "file:///elsewhere"}')
    folder = (tmp_path / "proj").resolve()
    folder.mkdir()

    manager._seed_workspace_layout(folder)

    ws_id = manager._workspace_storage_id(folder)
    assert not (manager._data_dir / "User" / "workspaceStorage" / ws_id).exists()


def test_seed_workspace_layout_picks_most_recent_empty_window_dir(tmp_data_dir, tmp_path):
    manager = InstanceManager()
    old = _make_empty_window_storage(manager, name="111", value="old")
    new = _make_empty_window_storage(manager, name="222", value="new")
    os.utime(old, (1000, 1000))
    os.utime(new, (2000, 2000))
    folder = (tmp_path / "proj").resolve()
    folder.mkdir()

    manager._seed_workspace_layout(folder)

    ws_id = manager._workspace_storage_id(folder)
    dest = manager._data_dir / "User" / "workspaceStorage" / ws_id
    assert _read_vscdb(dest / "state.vscdb") == "new"


def test_seed_workspace_layout_best_effort_on_error(tmp_data_dir, tmp_path, monkeypatch, caplog):
    manager = InstanceManager()
    _make_empty_window_storage(manager)
    folder = (tmp_path / "proj").resolve()
    folder.mkdir()

    def _boom(*args, **kwargs):
        raise OSError("disk full")

    monkeypatch.setattr(manager, "_backup_sqlite_file", _boom)
    with caplog.at_level("WARNING"):
        manager._seed_workspace_layout(folder)  # must not raise

    assert any("layout seed" in record.message.lower() for record in caplog.records)


def test_seed_workspace_layout_no_half_seeded_dir_when_backup_fails(
    tmp_data_dir, tmp_path, monkeypatch
):
    """A dest dir without state.vscdb must not survive — it would trip the D6
    exists-check and block future seed attempts."""
    manager = InstanceManager()
    _make_empty_window_storage(manager)
    folder = (tmp_path / "proj").resolve()
    folder.mkdir()

    def _silent_fail(src: Path, dst: Path) -> None:
        dst.parent.mkdir(parents=True, exist_ok=True)  # dir created, no db written

    monkeypatch.setattr(manager, "_backup_sqlite_file", _silent_fail)
    manager._seed_workspace_layout(folder)

    ws_id = manager._workspace_storage_id(folder)
    assert not (manager._data_dir / "User" / "workspaceStorage" / ws_id).exists()


async def test_ensure_ready_seeds_workspace_layout_on_spawn(fake_spawn, tmp_data_dir, tmp_path):
    manager = InstanceManager()
    _make_empty_window_storage(manager, value="spawn-layout")
    folder = (tmp_path / "proj").resolve()
    folder.mkdir()

    async def connect_soon():
        await asyncio.sleep(0)
        manager.mark_connected()

    task = asyncio.create_task(connect_soon())
    await manager.ensure_ready(str(folder), port=4321)
    await task

    ws_id = manager._workspace_storage_id(folder)
    dest = manager._data_dir / "User" / "workspaceStorage" / ws_id
    assert _read_vscdb(dest / "state.vscdb") == "spawn-layout"


async def test_ensure_ready_seeds_workspace_layout_on_reuse(fake_spawn, tmp_data_dir, tmp_path):
    """Every --reuse-window folder switch seeds the incoming folder (D5/D6)."""
    manager = InstanceManager()
    manager._alive = True
    manager._open_root = (tmp_path / "other").resolve()
    manager._connected.set()
    _make_empty_window_storage(manager, value="reuse-layout")
    folder = (tmp_path / "proj").resolve()
    folder.mkdir()

    async def connect_soon():
        await asyncio.sleep(0)
        manager.mark_connected()

    task = asyncio.create_task(connect_soon())
    await manager.ensure_ready(str(folder), port=4321)
    await task

    ws_id = manager._workspace_storage_id(folder)
    dest = manager._data_dir / "User" / "workspaceStorage" / ws_id
    assert _read_vscdb(dest / "state.vscdb") == "reuse-layout"
    args, _ = fake_spawn[0]
    assert "--reuse-window" in args


async def test_ensure_ready_sub_workspace_shortcut_does_not_seed(fake_spawn, tmp_data_dir, tmp_path):
    """No window reload on the ADR-0073 shortcut, so no seed either."""
    repo = tmp_path / "repo"
    sub = repo / "src"
    repo.mkdir()
    sub.mkdir()
    manager = InstanceManager()
    manager._alive = True
    manager._open_root = repo.resolve()
    manager._connected.set()
    _make_empty_window_storage(manager)

    await manager.ensure_ready(str(sub.resolve()), port=4321)

    ws_id = manager._workspace_storage_id(sub.resolve())
    assert not (manager._data_dir / "User" / "workspaceStorage" / ws_id).exists()
    assert fake_spawn == []


def test_copy_template_profile_best_effort_on_unexpected_error(tmp_data_dir, monkeypatch, caplog):
    template = _template_dir()
    template.mkdir(parents=True)
    (template / "settings.json").write_text("{}")

    def _boom(*args, **kwargs):
        raise OSError("disk full")

    monkeypatch.setattr(shutil, "copy2", _boom)

    manager = InstanceManager()
    with caplog.at_level("WARNING"):
        manager._copy_template_profile()  # must not raise

    assert any("template profile" in record.message.lower() for record in caplog.records)


async def test_ensure_ready_copies_template_profile_before_seed_settings_on_fresh_spawn(
    fake_spawn, tmp_data_dir
):
    calls: list[str] = []
    manager = InstanceManager()

    original_copy = manager._copy_template_profile
    original_seed = manager._seed_settings

    def _copy():
        calls.append("copy")
        original_copy()

    def _seed():
        calls.append("seed")
        original_seed()

    manager._copy_template_profile = _copy
    manager._seed_settings = _seed

    async def connect_soon():
        await asyncio.sleep(0)
        manager.mark_connected()

    task = asyncio.create_task(connect_soon())
    await manager.ensure_ready("/tmp/repo", port=4321)
    await task

    assert calls == ["copy", "seed"]


async def test_ensure_ready_skips_copy_template_profile_on_reuse(fake_spawn, tmp_data_dir, monkeypatch):
    manager = InstanceManager()
    manager._alive = True
    manager.workspace = "/tmp/old"
    manager._connected.set()

    calls: list[str] = []
    monkeypatch.setattr(manager, "_copy_template_profile", lambda: calls.append("copy"))
    monkeypatch.setattr(manager, "_create_config_symlink", lambda: calls.append("symlink"))
    monkeypatch.setattr(manager, "_seed_settings", lambda: calls.append("seed"))

    async def connect_soon():
        await asyncio.sleep(0)
        manager.mark_connected()

    task = asyncio.create_task(connect_soon())
    await manager.ensure_ready("/tmp/new", port=4321)
    await task

    assert calls == []  # already-wired session: no re-copy on window reuse
