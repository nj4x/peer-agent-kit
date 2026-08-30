import asyncio

import pytest
from aiohttp.test_utils import TestClient, TestServer

from bridge.bridge import Bridge
from bridge.logsetup import task_id_var


@pytest.fixture
async def wired(monkeypatch):
    bridge = Bridge()

    async def fake_ensure_ready(workspace, port):
        bridge.instance.workspace = workspace
        bridge.instance.mark_connected()

    monkeypatch.setattr(bridge.instance, "ensure_ready", fake_ensure_ready)

    async with TestClient(TestServer(bridge.hooks.app)) as client:
        ws = await client.ws_connect("/ws")
        await asyncio.sleep(0)
        yield bridge, ws
        if not ws.closed:
            await ws.close()


async def test_pump_clears_task_id_after_dispatch(wired):
    """A persistent caller (the sweeper task) must not see a prior task's id
    bleed into the next _pump call's log context (ADR-0069)."""
    bridge, ws = wired
    record = bridge.queue.submit("q", "/tmp")

    await bridge._pump(1800.0)
    await ws.receive_json()  # drain the dispatch

    assert record.status == "dispatched"
    assert task_id_var.get() == ""


async def test_pump_clears_task_id_when_nothing_dispatchable(wired):
    bridge, _ws = wired
    task_id_var.set("stale-from-earlier-call")

    await bridge._pump(1800.0)

    assert task_id_var.get() == ""


async def test_get_logs_for_session_all_tasks(wired):
    """get_logs_for_session with no handle returns all tasks."""
    bridge, _ws = wired
    r1 = bridge.queue.submit("q1", "/tmp")
    r2 = bridge.queue.submit("q2", "/tmp")

    result = bridge.get_logs_for_session()

    assert result["status"] == "ok"
    assert "session_log" in result
    assert len(result["tasks"]) == 2
    assert {t["id"] for t in result["tasks"]} == {r1.id, r2.id}
    assert all(t["grep_hint"].startswith("task_id=") for t in result["tasks"])


async def test_get_logs_for_session_single_handle(wired):
    """get_logs_for_session with a handle returns only that task."""
    bridge, _ws = wired
    r1 = bridge.queue.submit("q1", "/tmp")
    r2 = bridge.queue.submit("q2", "/tmp")

    result = bridge.get_logs_for_session(handle=r1.id)

    assert result["status"] == "ok"
    assert len(result["tasks"]) == 1
    assert result["tasks"][0]["id"] == r1.id


async def test_get_logs_for_session_unknown_handle(wired):
    """get_logs_for_session with unknown handle returns error."""
    bridge, _ws = wired

    result = bridge.get_logs_for_session(handle="nonexistent")

    assert result["status"] == "unknown_handle"
    assert result["handle"] == "nonexistent"


def test_latest_vscode_exthost_dir_not_exist(monkeypatch, tmp_path):
    """_latest_vscode_exthost_dir returns None when logs dir doesn't exist."""
    bridge = Bridge()
    monkeypatch.setattr("pathlib.Path.home", lambda: tmp_path)

    result = bridge._latest_vscode_exthost_dir()
    assert result is None


def test_latest_vscode_exthost_dir_empty(tmp_path, monkeypatch):
    """_latest_vscode_exthost_dir returns None when logs dir is empty."""
    bridge = Bridge()
    data_dir = tmp_path / ".vscode-agent-bridge" / "data"
    data_dir.mkdir(parents=True)
    monkeypatch.setattr("pathlib.Path.home", lambda: tmp_path)

    result = bridge._latest_vscode_exthost_dir()
    assert result is None


def test_latest_vscode_exthost_dir_picks_latest(tmp_path, monkeypatch):
    """_latest_vscode_exthost_dir returns the lexicographically latest dir."""
    bridge = Bridge()
    logs_dir = tmp_path / ".vscode-agent-bridge" / "data" / "logs"
    logs_dir.mkdir(parents=True)
    (logs_dir / "20260829T100000").mkdir()
    (logs_dir / "20260829T110000").mkdir()
    (logs_dir / "20260829T090000").mkdir()

    monkeypatch.setattr("pathlib.Path.home", lambda: tmp_path)

    result = bridge._latest_vscode_exthost_dir()
    assert result == str(logs_dir / "20260829T110000")


# Tests for _exclude_workspace_rag
from bridge.bridge import _exclude_workspace_rag


def test_exclude_workspace_rag_fresh_repo(tmp_path):
    """Fresh git repo with no exclude file - should create it."""
    workspace = tmp_path / "workspace"
    workspace.mkdir()
    git_info = workspace / ".git" / "info"
    git_info.mkdir(parents=True)
    
    _exclude_workspace_rag(str(workspace))
    
    exclude_file = workspace / ".git" / "info" / "exclude"
    assert exclude_file.exists()
    assert exclude_file.read_text() == ".workspace_rag/\n"


def test_exclude_workspace_rag_existing_exclude_no_entry(tmp_path):
    """Existing exclude file without .workspace_rag entry - should append."""
    workspace = tmp_path / "workspace"
    workspace.mkdir()
    git_info = workspace / ".git" / "info"
    git_info.mkdir(parents=True)
    
    exclude_file = git_info / "exclude"
    exclude_file.write_text("*.pyc\n")
    
    _exclude_workspace_rag(str(workspace))
    
    content = exclude_file.read_text()
    assert "*.pyc\n" in content
    assert ".workspace_rag/\n" in content


def test_exclude_workspace_rag_already_excluded(tmp_path):
    """Existing exclude file with .workspace_rag entry - no duplicate."""
    workspace = tmp_path / "workspace"
    workspace.mkdir()
    git_info = workspace / ".git" / "info"
    git_info.mkdir(parents=True)
    
    exclude_file = git_info / "exclude"
    exclude_file.write_text("*.pyc\n.workspace_rag/\n")
    
    _exclude_workspace_rag(str(workspace))
    
    content = exclude_file.read_text()
    assert content.count(".workspace_rag") == 1


def test_exclude_workspace_rag_non_git_workspace(tmp_path):
    """Non-git workspace - no-op, no error."""
    workspace = tmp_path / "workspace"
    workspace.mkdir()
    
    _exclude_workspace_rag(str(workspace))
    
    # Should not create .git or anything
    assert not (workspace / ".git").exists()


def test_exclude_workspace_rag_no_trailing_newline(tmp_path):
    """Existing exclude file without trailing newline - should add one."""
    workspace = tmp_path / "workspace"
    workspace.mkdir()
    git_info = workspace / ".git" / "info"
    git_info.mkdir(parents=True)
    
    exclude_file = git_info / "exclude"
    exclude_file.write_text("*.pyc")  # No trailing newline
    
    _exclude_workspace_rag(str(workspace))
    
    content = exclude_file.read_text()
    assert content == "*.pyc\n.workspace_rag/\n"


def test_exclude_workspace_rag_worktree(tmp_path):
    """Worktree case: .git is a file."""
    workspace = tmp_path / "workspace"
    workspace.mkdir()
    
    # Create a real git dir elsewhere
    real_git = tmp_path / "real_git"
    (real_git / "info").mkdir(parents=True)
    
    # Create .git file pointing to real git dir
    git_file = workspace / ".git"
    git_file.write_text(f"gitdir: {real_git}")
    
    _exclude_workspace_rag(str(workspace))
    
    exclude_file = real_git / "info" / "exclude"
    assert exclude_file.exists()
    assert ".workspace_rag/\n" in exclude_file.read_text()


def test_exclude_workspace_rag_entry_without_trailing_slash(tmp_path):
    """Existing exclude with .workspace_rag (no slash) - no duplicate."""
    workspace = tmp_path / "workspace"
    workspace.mkdir()
    git_info = workspace / ".git" / "info"
    git_info.mkdir(parents=True)
    
    exclude_file = git_info / "exclude"
    exclude_file.write_text("*.pyc\n.workspace_rag\n")
    
    _exclude_workspace_rag(str(workspace))
    
    content = exclude_file.read_text()
    # Should not add duplicate
    lines = [l.strip() for l in content.splitlines()]
    assert lines.count(".workspace_rag") + lines.count(".workspace_rag/") == 1
