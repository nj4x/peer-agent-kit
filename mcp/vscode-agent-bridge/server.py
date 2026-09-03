"""vscode-agent-bridge MCP server — submit_to_peer_agent / poll_peer_agent / close_peer_agent.

Delegates a task to cline-sr (a separate VS Code process) via a persistent
dedicated window. Submission rides a WebSocket the companion extension
holds open; lifecycle (start, tool use, completion, cancel) arrives over
HTTP from cline-sr's hook scripts, which inherit BRIDGE_PORT from this
server's own spawn of `code`.

Environment variables:
    BRIDGE_ASYNC_TIMEOUT: seconds before an unanswered submitted request expires (default: 1800)
    BRIDGE_POLL_TIMEOUT: default timeout for `poll_peer_agent` long-poll (default: None = indefinite)
"""

from __future__ import annotations

import os
from contextlib import asynccontextmanager

from mcp.server.mcpserver.server import MCPServer
from mcp.server.mcpserver.context import Context

from bridge.bridge import Bridge
from bridge.logsetup import get_logger, setup_logging

setup_logging()
logger = get_logger("server")


@asynccontextmanager
async def lifespan(_server: MCPServer):
    bridge = Bridge()
    await bridge.start()
    try:
        yield bridge
    finally:
        await bridge.stop()


mcp = MCPServer("vscode-agent-bridge", lifespan=lifespan)


def _bridge(ctx: Context) -> Bridge:
    bridge = ctx.request_context.lifespan_context
    if not isinstance(bridge, Bridge):
        raise RuntimeError(f"lifespan_context not a Bridge: {type(bridge)}")
    return bridge


@mcp.tool()
async def submit_to_peer_agent(question: str, workspace: str, ctx: Context) -> dict:
    """Ask cline-sr a question without waiting for the answer.

    Reaches a dedicated VS Code window running cline-sr. It works as a
    delegate, not a sandbox: `workspace` (required, an existing directory) is
    the live working tree it reads and edits — uncommitted work included — so
    its edits land in your tree and show up in `git diff`. Never delegate
    a workspace holding production credentials: reads inside it are
    unconstrained.

    This variant returns at once, so use it for work measured in minutes: collect
    the answer later with `poll_peer_agent`. Submit several questions before
    polling any — each waits its turn behind whatever is already in flight.

    Returns {handle, status, reason}. `status` is always "submitted"; keep
    the `handle` to poll. A request nobody answers within 30 minutes expires,
    and polling it then reports failed with reason timeout.
    """
    return await _bridge(ctx).submit(question, workspace)


def _poll_timeout_default() -> float | None:
    """Return the default poll timeout from BRIDGE_POLL_TIMEOUT env var, or None if not set."""
    val = os.getenv("BRIDGE_POLL_TIMEOUT")
    if val is not None:
        try:
            return float(val)
        except ValueError:
            raise ValueError(f"BRIDGE_POLL_TIMEOUT must be a number, got: {val}")
    return None


@mcp.tool()
async def poll_peer_agent(handle: str, ctx: Context, poll_timeout_seconds: float | None = None) -> dict:
    """Check whether cline-sr has answered a submitted question.

    This call blocks until the task reaches a terminal state or the timeout expires.

    `handle` is what `submit_to_peer_agent` returned.

    The `poll_timeout_seconds` parameter controls waiting behavior:
        - 0: immediate snapshot, never blocks, returns "pending" if still in-flight
        - positive: bounded wait, returns "timed_out" if the timeout expires
        - None (default): indefinite wait until terminal state (bounded in practice by the
          30-minute request expiry which returns failed/reason=timeout); default can be
          overridden via BRIDGE_POLL_TIMEOUT environment variable

    Returns {status, answer, command, reason, tool_uses, last_event_at, activity}.
    `status` is "pending" (still queued or being worked on — `tool_uses` and
    `last_event_at`, sourced from cline-sr's tool-use hooks, distinguish
    actively working from hung), "answered", "failed", or "timed_out".
    On failure `reason` is timeout, instance_down, cancelled, unknown_handle,
    or internal_error.
    `activity` is "live" | "stalled" | null: "live" means the peer is actively
    working (tool fired this poll or heartbeat within 30s), "stalled" means no
    progress and heartbeat > 30s old (or dispatch > 30s with no events), null
    means the task was never dispatched.
    """
    timeout = poll_timeout_seconds if poll_timeout_seconds is not None else _poll_timeout_default()
    if timeout is not None and timeout < 0:
        raise ValueError("poll_timeout_seconds must be non-negative")
    return await _bridge(ctx).poll_async(handle, timeout)


@mcp.tool()
async def close_peer_agent(ctx: Context) -> dict:
    """Close the dedicated cline-sr window and terminate the bridge session.

    Refuses if a task is in flight or queued. Caller must poll to completion
    before closing. Returns {status: "closed"} on success or {status: "busy"}
    if the queue is not empty.
    """
    return _bridge(ctx).close()


@mcp.tool()
async def get_logs_for_session(ctx: Context, handle: str | None = None) -> dict:
    """Get file paths and grep hints for logs related to current bridge session, tasks, and VS Code.

    Returns references to all logs generated in the current bridge process lifetime,
    allowing you to inspect what happened during task execution.

    Args:
        handle: optional task_id to filter to a single task's logs.
                if None, returns references for all tasks in the current session.

    Returns dict with keys:
        - status: "ok" or "unknown_handle"
        - session_log: path to ~/.vscode-agent-bridge/logs/vscode-agent-bridge.log
                       grep with "task_id=<task_id>" to filter to a single task
        - tasks: list of {id, grep_hint, status} for each task (or just the specified handle)
        - vscode_exthost_log: path to latest ~/.vscode-agent-bridge/data/logs/<timestamp>/,
                              or null if VS Code has not been spawned yet

    Example:
        Get all logs in the session:
            result = await get_logs_for_session()
            # result["session_log"] = "~/.vscode-agent-bridge/logs/vscode-agent-bridge.log"
            # result["tasks"][0] = {id: "abc-123", grep_hint: "task_id=abc-123", status: "answered"}
            # Run: rg "task_id=abc-123" ~/.vscode-agent-bridge/logs/vscode-agent-bridge.log

        Get logs for a single task:
            result = await get_logs_for_session(handle="abc-123")
    """
    return _bridge(ctx).get_logs_for_session(handle)


def main() -> None:
    mcp.run()


if __name__ == "__main__":
    main()
