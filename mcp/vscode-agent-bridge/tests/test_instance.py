import asyncio
import json
import os
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
