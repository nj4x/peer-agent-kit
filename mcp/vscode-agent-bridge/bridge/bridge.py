"""Single orchestration object per MCP server process (ADR-0068).

Wraps BridgeQueue, InstanceManager, and HookServer. Exposed via MCPServer's
lifespan context so tool functions and tests depend on one interface instead of
three module globals.
"""

from __future__ import annotations

import asyncio
import os
from pathlib import Path

from bridge.hookserver import HookServer
from bridge.instance import InstanceManager
from bridge.logsetup import get_logger, set_task_id
from bridge.queue import BridgeQueue

logger = get_logger("bridge")

POLL_INTERVAL = 0.25
SWEEP_INTERVAL = 5.0


def _ask_timeout() -> float:
    return float(os.getenv("BRIDGE_ASK_TIMEOUT", "180"))


def _async_timeout() -> float:
    return float(os.getenv("BRIDGE_ASYNC_TIMEOUT", "1800"))


def _exclude_workspace_rag(workspace: str) -> None:
    """Ensure .workspace_rag/ is excluded from git in the workspace.
    
    This is non-fatal: any errors are logged and swallowed.
    """
    git_path = Path(workspace) / ".git"
    if not git_path.exists():
        return  # Not a git repo, nothing to do
    
    # Handle worktree case: .git is a file pointing elsewhere
    if git_path.is_file():
        # Worktree: .git is a file, try to resolve but don't fail if weird
        try:
            git_content = git_path.read_text().strip()
            # Format: "gitdir: <path>"
            if git_content.startswith("gitdir: "):
                git_path = Path(git_content[8:].strip())
            else:
                git_path = Path(git_content)
        except (OSError, IOError):
            logger.warning("worktree .git file unreadable: %s", workspace)
            return
    
    exclude_file = git_path / "info" / "exclude"
    
    try:
        # Try to create info dir if needed (only for regular repos)
        if git_path.is_dir():
            exclude_file.parent.mkdir(parents=True, exist_ok=True)
        
        # Check if entry already exists
        if exclude_file.exists():
            try:
                content = exclude_file.read_text()
                # Check for existing entry (with or without trailing slash)
                for line in content.splitlines():
                    stripped = line.strip()
                    if stripped == ".workspace_rag/" or stripped == ".workspace_rag":
                        return  # Already excluded, nothing to do
                # File exists but needs new entry - ensure newline at end
                if content and not content.endswith("\n"):
                    content += "\n"
                content += ".workspace_rag/\n"
                exclude_file.write_text(content)
            except (OSError, IOError) as e:
                logger.warning("failed to update git exclude file: %s", e)
        else:
            # Fresh file, just write the entry
            exclude_file.write_text(".workspace_rag/\n")
    except (OSError, IOError) as e:
        logger.warning("failed to exclude .workspace_rag in %s: %s", workspace, e)


def _validate(question: str, workspace: str) -> str:
    question = question.strip()
    if not question:
        raise ValueError("question must not be empty")
    if not Path(workspace).is_dir():
        raise ValueError(f"workspace is not an existing directory: {workspace}")
    _exclude_workspace_rag(workspace)
    return question


class Bridge:
    def __init__(self) -> None:
        self.queue = BridgeQueue()
        self.instance = InstanceManager()
        self.hooks = HookServer(self.queue, self.instance)
        self._sweeper_task: asyncio.Task | None = None

    async def start(self) -> None:
        """Start the hook server and pump/sweep loop."""
        await self.hooks.start()
        self._sweeper_task = asyncio.create_task(self._sweep_loop())

    async def stop(self) -> None:
        """Stop the sweeper and hook server."""
        if self._sweeper_task is not None:
            self._sweeper_task.cancel()
            try:
                await self._sweeper_task
            except asyncio.CancelledError:
                pass
        await self.hooks.stop()

    async def _pump(self, async_timeout: float) -> None:
        """Dispatch the next queued record, if the window is free to take one.

        `set_task_id` writes to the calling asyncio Task's context. The
        sweeper drives this from one long-lived Task (_sweep_loop), so the id
        must be cleared here rather than left to bleed into the next
        iteration's log lines.
        """
        set_task_id(None)
        logger.info("_pump: enter")
        record = self.queue.next_dispatchable()
        if record is None:
            logger.info("_pump: exit (nothing dispatchable)")
            return
        set_task_id(record.id)
        try:
            await self.instance.ensure_ready(record.workspace, self.hooks.port)
            await self.hooks.dispatch(record.question)
        except Exception:
            logger.exception("dispatch of task %s failed", record.id)
            self.queue.fail(record.id, "instance_down")
            set_task_id(None)
            await self._pump(async_timeout)
            return
        logger.info("_pump: exit")
        set_task_id(None)

    async def ask(self, question: str, workspace: str) -> dict:
        """Submit a question and block until answered, failed, or ask-timeout."""
        question = _validate(question, workspace)
        record = self.queue.submit(question, workspace)
        set_task_id(record.id)
        try:
            await self._pump(_async_timeout())

            loop = asyncio.get_running_loop()
            deadline = loop.time() + _ask_timeout()
            while True:
                current = self.queue.get(record.id)
                logger.debug("ask poll heartbeat: status=%s", current.status)
                if current.status == "answered":
                    return {"id": record.id, "status": "answered", "answer": current.answer, "command": current.command, "reason": None}
                if current.status == "failed":
                    return {"id": record.id, "status": "failed", "answer": None, "command": None, "reason": current.reason}
                remaining = deadline - loop.time()
                if remaining <= 0:
                    self.queue.fail(record.id, "timeout")
                    return {"id": record.id, "status": "failed", "answer": None, "command": None, "reason": "timeout"}
                await asyncio.sleep(min(POLL_INTERVAL, remaining))
        finally:
            set_task_id(None)

    async def submit(self, question: str, workspace: str) -> dict:
        """Submit a question without waiting; returns a pollable handle."""
        question = _validate(question, workspace)
        record = self.queue.submit(question, workspace)
        set_task_id(record.id)
        await self._pump(_async_timeout())
        return {"handle": record.id, "status": "submitted", "reason": None}

    def poll(self, handle: str) -> dict:
        """Report the current state of a submitted question. Never blocks."""
        record = self.queue.get(handle)
        if record is None:
            return {"status": "failed", "answer": None, "command": None, "reason": "unknown_handle", "tool_uses": None, "last_event_at": None}
        if record.status == "answered":
            return {"status": "answered", "answer": record.answer, "command": record.command, "reason": None, "tool_uses": record.tool_uses, "last_event_at": record.last_event_at}
        if record.status == "failed":
            return {"status": "failed", "answer": None, "command": None, "reason": record.reason, "tool_uses": record.tool_uses, "last_event_at": record.last_event_at}
        return {"status": "pending", "answer": None, "command": None, "reason": None, "tool_uses": record.tool_uses, "last_event_at": record.last_event_at}

    def close(self) -> dict:
        """Close the dedicated window unless work is in flight or queued."""
        if self.queue.busy():
            return {"status": "busy"}
        self.instance.close()
        return {"status": "closed"}

    async def _sweep_loop(self, async_timeout: float = 1800.0) -> None:
        """Run the expiration sweep at regular intervals."""
        try:
            while True:
                await asyncio.sleep(SWEEP_INTERVAL)
                logger.debug("sweep_expired: run")
                self.queue.sweep_expired(async_timeout)
                await self._pump(async_timeout)
        except asyncio.CancelledError:
            pass

    def get_logs_for_session(self, handle: str | None = None) -> dict:
        """Return file paths and grep hints for logs in current bridge session.

        Args:
            handle: optional task_id to filter logs to a single task.
                    if None, returns references for all tasks + session log.

        Returns dict with keys:
            - session_log: path to ~/.vscode-agent-bridge/logs/vscode-agent-bridge.log
            - tasks: list of dicts, one per task (or per handle if specified).
                     each dict has: {id, grep_hint, status}
            - vscode_exthost_log: path to latest ~/.vscode-agent-bridge/data/logs/*/
                                  or None if dir doesn't exist yet.

        If handle is provided but not found in queue, returns {status: "unknown_handle"}.
        """
        session_log = Path.home() / ".vscode-agent-bridge" / "logs" / "vscode-agent-bridge.log"

        if handle is not None:
            record = self.queue.get(handle)
            if record is None:
                return {"status": "unknown_handle", "handle": handle}
            tasks = [{"id": record.id, "grep_hint": f"task_id={record.id}", "status": record.status}]
        else:
            tasks = [
                {"id": r.id, "grep_hint": f"task_id={r.id}", "status": r.status}
                for r in self.queue.all_records()
            ]

        exthost_log = self._latest_vscode_exthost_dir()

        return {
            "status": "ok",
            "session_log": str(session_log),
            "tasks": tasks,
            "vscode_exthost_log": exthost_log,
        }

    def _latest_vscode_exthost_dir(self) -> str | None:
        """Return path to latest VS Code exthost log dir, or None if not found."""
        logs_dir = Path.home() / ".vscode-agent-bridge" / "data" / "logs"
        if not logs_dir.exists():
            return None
        try:
            dirs = sorted([d for d in logs_dir.iterdir() if d.is_dir()])
            if not dirs:
                return None
            return str(dirs[-1])
        except (OSError, RuntimeError):
            return None
