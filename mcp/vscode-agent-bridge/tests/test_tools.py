import asyncio
from unittest.mock import MagicMock

import pytest
from aiohttp.test_utils import TestClient, TestServer

import server as srv
from bridge.bridge import Bridge


def _make_ctx(bridge: Bridge) -> MagicMock:
    ctx = MagicMock()
    ctx.request_context.lifespan_context = bridge
    return ctx


@pytest.fixture(autouse=True)
async def fresh_state(monkeypatch, tmp_path):
    """Give every test its own Bridge, wired the way lifespan() would, but
    backed by aiohttp's TestClient instead of a real TCP bind, and a stub
    instance spawn instead of a real `code` process. Tools receive the Bridge
    via a mocked Context, as the MCP framework would inject it (ADR-0068)."""
    bridge = Bridge()

    async def fake_ensure_ready(workspace, port):
        bridge.instance.workspace = workspace
        bridge.instance.mark_connected()

    monkeypatch.setattr(bridge.instance, "ensure_ready", fake_ensure_ready)
    ctx = _make_ctx(bridge)

    async with TestClient(TestServer(bridge.hooks.app)) as client:
        ws = await client.ws_connect("/ws")
        await asyncio.sleep(0)
        yield bridge, ws, tmp_path, ctx
        if not ws.closed:
            await ws.close()


async def _drain_submit(ws) -> dict:
    return await ws.receive_json()


async def test_submit_to_peer_agent_returns_handle_immediately(fresh_state):
    bridge, ws, tmp_path, ctx = fresh_state

    result = await srv.submit_to_peer_agent("do a thing", str(tmp_path), ctx)
    assert result["status"] == "submitted"
    assert result["reason"] is None
    handle = result["handle"]

    submitted = await _drain_submit(ws)
    assert submitted["prompt"] == "do a thing"

    poll = await srv.poll_peer_agent(handle, ctx, poll_timeout_seconds=0)
    assert poll["status"] == "pending"
    assert poll["tool_uses"] == 0


async def test_poll_unknown_handle(fresh_state):
    bridge, ws, tmp_path, ctx = fresh_state

    result = await srv.poll_peer_agent("does-not-exist", ctx)
    assert result == {
        "status": "failed",
        "answer": None,
        "command": None,
        "reason": "unknown_handle",
        "tool_uses": None,
        "last_event_at": None,
        "activity": None,
    }


async def test_second_submit_queues_behind_first(fresh_state):
    bridge, ws, tmp_path, ctx = fresh_state

    first = await srv.submit_to_peer_agent("q1", str(tmp_path), ctx)
    await _drain_submit(ws)  # first got dispatched

    second = await srv.submit_to_peer_agent("q2", str(tmp_path), ctx)
    poll_second = await srv.poll_peer_agent(second["handle"], ctx, poll_timeout_seconds=0)
    assert poll_second["status"] == "pending"
    assert bridge.queue.get(second["handle"]).status == "queued"

    bridge.queue.complete("answer1", None)
    await bridge._pump(1800.0)
    dispatched_second = await _drain_submit(ws)
    assert dispatched_second["prompt"] == "q2"
    assert bridge.queue.get(second["handle"]).status == "dispatched"


async def test_close_peer_agent_succeeds_when_idle(fresh_state):
    bridge, ws, tmp_path, ctx = fresh_state

    result = await srv.close_peer_agent(ctx)
    assert result == {"status": "closed"}
    assert not bridge.instance.alive


async def test_close_peer_agent_refuses_when_in_flight(fresh_state, tmp_path):
    bridge, ws, tmp_path, ctx = fresh_state

    await srv.submit_to_peer_agent("task", str(tmp_path), ctx)
    await _drain_submit(ws)

    result = await srv.close_peer_agent(ctx)
    assert result == {"status": "busy"}


async def test_close_peer_agent_refuses_when_queued(fresh_state, tmp_path):
    bridge, ws, tmp_path, ctx = fresh_state

    await srv.submit_to_peer_agent("task1", str(tmp_path), ctx)
    await _drain_submit(ws)

    # Submit second (stays queued)
    await srv.submit_to_peer_agent("task2", str(tmp_path), ctx)

    result = await srv.close_peer_agent(ctx)
    assert result == {"status": "busy"}


async def test_get_logs_for_session_via_tool(fresh_state, tmp_path):
    bridge, ws, tmp_path, ctx = fresh_state

    submitted = await srv.submit_to_peer_agent("q1", str(tmp_path), ctx)
    await _drain_submit(ws)

    result = await srv.get_logs_for_session(ctx)
    assert result["status"] == "ok"
    assert result["tasks"][0]["id"] == submitted["handle"]


async def test_poll_peer_agent_uses_bridge_poll_timeout_env_default(fresh_state, monkeypatch):
    """poll_peer_agent resolves BRIDGE_POLL_TIMEOUT env var when caller omits poll_timeout_seconds."""
    bridge, ws, tmp_path, ctx = fresh_state

    # Submit and dispatch a task that will stay pending
    await srv.submit_to_peer_agent("pending task", str(tmp_path), ctx)
    await _drain_submit(ws)

    # Set a very short timeout via env var
    monkeypatch.setenv("BRIDGE_POLL_TIMEOUT", "0.05")

    # Call without explicit poll_timeout_seconds - should use env default
    result = await srv.poll_peer_agent(bridge.queue.in_flight().id, ctx)

    # Should return timed_out due to the 0.05s env timeout
    assert result["status"] == "timed_out"


# Tests for ADR-0086: Brief-File Summary Prefix

async def test_submit_to_peer_agent_with_summary(fresh_state, tmp_path, monkeypatch):
    """submit_to_peer_agent accepts and propagates summary parameter."""
    bridge, ws, tmp_path, ctx = fresh_state
    monkeypatch.setattr("pathlib.Path.home", lambda: tmp_path)
    
    from bridge.bridge import ENCODED_BRIEF_THRESHOLD
    
    # Submit with a long question (triggers offload) and a summary
    long_question = "x" * (ENCODED_BRIEF_THRESHOLD + 1)
    result = await srv.submit_to_peer_agent(long_question, str(tmp_path), ctx, summary="Test summary")
    
    dispatched = await _drain_submit(ws)
    
    # The dispatched prompt should start with the summary prefix
    assert dispatched["prompt"].startswith("Test summary. Your full task brief is at")
    assert "read it first" in dispatched["prompt"]


async def test_submit_to_peer_agent_without_summary(fresh_state, tmp_path, monkeypatch):
    """submit_to_peer_agent without summary works as before (regression)."""
    bridge, ws, tmp_path, ctx = fresh_state
    monkeypatch.setattr("pathlib.Path.home", lambda: tmp_path)
    
    from bridge.bridge import ENCODED_BRIEF_THRESHOLD
    
    # Submit with a long question (triggers offload) but no summary
    long_question = "x" * (ENCODED_BRIEF_THRESHOLD + 1)
    await srv.submit_to_peer_agent(long_question, str(tmp_path), ctx)
    
    dispatched = await _drain_submit(ws)
    
    # The dispatched prompt should be the standard pointer without prefix
    assert dispatched["prompt"].startswith("Your full task brief is at")
    assert not dispatched["prompt"].startswith(". Your")


async def test_submit_to_peer_agent_short_question_summary_ignored(fresh_state, tmp_path, monkeypatch):
    """submit_to_peer_agent with short question ignores summary (inline dispatch)."""
    bridge, ws, tmp_path, ctx = fresh_state
    monkeypatch.setattr("pathlib.Path.home", lambda: tmp_path)
    
    # Submit with a short question (no offload) and a summary
    short_question = "short task"
    await srv.submit_to_peer_agent(short_question, str(tmp_path), ctx, summary="Ignored summary")
    
    dispatched = await _drain_submit(ws)
    
    # The dispatched prompt should be the original question, summary discarded
    assert dispatched["prompt"] == short_question
    assert "Ignored summary" not in dispatched["prompt"]
