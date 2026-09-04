"""Single orchestration object per MCP server process (ADR-0068).

Wraps BridgeQueue, InstanceManager, and HookServer. Exposed via MCPServer's
lifespan context so tool functions and tests depend on one interface instead of
three module globals.
"""

from __future__ import annotations

import asyncio
import os
import time
import urllib.parse
from pathlib import Path
from typing import Literal

from bridge.hookserver import HookServer
from bridge.instance import InstanceManager
from bridge.logsetup import get_logger, set_task_id
from bridge.queue import ANSWERED, BridgeQueue, FAILED, QUEUED, Record

logger = get_logger("bridge")

SWEEP_INTERVAL = 5.0
# Stall predicate recency threshold, in seconds (ADR-0085 decision 3).
ACTIVITY_STALE_THRESHOLD = 30.0

Activity = Literal["live", "stalled"]

# Conservative budget under the ~2000-char OS/VS Code URI lower bound, leaving
# headroom for the URI scheme/path/param overhead (ADR-0077).
# Lowered to 850 encoded chars (ADR-0087) to mitigate MCP client truncation risk:
# observed MCP parameter truncation at ~1090 encoded chars; offloading to brief file
# bypasses the MCP layer entirely. Value chosen to support ADR-0086 summary cap
# (baseline pointer ~220 + separator ~4 + summary 600 = 824 ≤ 850, safety margin ~26).
ENCODED_BRIEF_THRESHOLD = 850
# Signal for oversized-brief investigation, not a hard cap (ADR-0077).
BRIEF_WARN_BYTES = 50 * 1024
# encodeURIComponent()'s unescaped set beyond letters/digits/_.-~, which
# urllib.parse.quote already leaves unescaped by default (ADR-0077 ID-011).
_ENCODE_URI_COMPONENT_SAFE = "!'()*-._~"

# Encoded-length cap for summary prefix (ADR-0086).
SUMMARY_ENCODED_CAP = 600


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


def _encoded_length(text: str) -> int:
    """Length of `text` as encodeURIComponent() would produce it (ADR-0077).

    The URI transport is the extension's `encodeURIComponent(prompt)` call
    (`extension/src/extension.ts`); this must measure the same string.
    """
    return len(urllib.parse.quote(text, safe=_ENCODE_URI_COMPONENT_SAFE))


def _briefs_dir() -> Path:
    return Path.home() / ".vscode-agent-bridge" / "briefs"


def _prepare_dispatch_prompt(record: Record) -> str:
    """Return the prompt to dispatch for `record`, offloading to a brief file
    when the encoded prompt would exceed the URI transport's practical limit
    (ADR-0077). Raises OSError or UnicodeError if the brief file can't be
    written (including a lone-surrogate question that can't be UTF-8
    encoded); the caller treats that as a fatal dispatch prerequisite, not
    best-effort.
    
    When offloading and record.summary is truthy, prepends the summary to the
    pointer prompt (ADR-0086). For inline dispatch (under threshold), summary
    is silently discarded.
    """
    question = record.question
    if _encoded_length(question) <= ENCODED_BRIEF_THRESHOLD:
        # Inline dispatch: summary is silently discarded per ADR-0086
        return question

    briefs_dir = _briefs_dir()
    briefs_dir.mkdir(parents=True, exist_ok=True)
    brief_path = briefs_dir / f"brief-{record.id}.md"
    brief_path.write_text(question, encoding="utf-8")

    size = brief_path.stat().st_size
    logger.info(
        "task %s: brief offloaded to %s (encoded length %d bytes, file %d bytes)",
        record.id, brief_path, _encoded_length(question), size,
    )
    if size > BRIEF_WARN_BYTES:
        logger.warning(
            "brief file %s exceeds %d bytes (%d bytes) — consider a workspace file reference instead",
            brief_path, BRIEF_WARN_BYTES, size,
        )

    # ADR-0086: prepend summary if present and truthy
    if record.summary:
        return f"{record.summary}. Your full task brief is at `{brief_path}` — read it first, then proceed."
    return f"Your full task brief is at `{brief_path}` — read it first, then proceed."


def _validate_summary(summary: str | None) -> str | None:
    """Validate and optionally truncate summary to fit within SUMMARY_ENCODED_CAP encoded chars (ADR-0086).
    
    Returns None if summary is None. Returns unchanged summary if encoded length <= SUMMARY_ENCODED_CAP.
    If over, truncates raw characters from the end until encoded length of 
    summary + " ..." is <= SUMMARY_ENCODED_CAP, then returns summary + " ...".
    """
    if summary is None:
        return None
    
    # Strip whitespace to prevent prompts like "   . Your full task brief..."
    summary = summary.strip()
    if not summary:
        return None
    
    # Check if summary fits within the encoded limit
    if _encoded_length(summary) <= SUMMARY_ENCODED_CAP:
        return summary
    
    # Truncate with ellipsis - need to find the right truncation point
    # The ellipsis " ..." encodes to " ..." (6 encoded chars: %20 for space + 3 dots)
    ellipsis = " ..."
    ellipsis_encoded_len = _encoded_length(ellipsis)
    max_encoded_with_ellipsis = SUMMARY_ENCODED_CAP
    
    # Binary search for the right truncation point
    # Account for ellipsis in the loop bound
    left, right = 0, len(summary)
    while left < right:
        mid = (left + right + 1) // 2
        truncated = summary[:mid] + ellipsis
        if _encoded_length(truncated) <= max_encoded_with_ellipsis:
            left = mid
        else:
            right = mid - 1
    
    return summary[:left] + ellipsis


def _validate(question: str, workspace: str) -> str:
    """Validate question and workspace, returning validated question."""
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
        except Exception:
            logger.exception("instance not ready for task %s", record.id)
            await self._fail_and_retry(record.id, "instance_down", async_timeout)
            return
        try:
            prompt = _prepare_dispatch_prompt(record)
        except (OSError, UnicodeError):
            logger.exception("brief file write failed for task %s", record.id)
            await self._fail_and_retry(record.id, "internal_error", async_timeout)
            return
        try:
            await self.hooks.dispatch(prompt)
        except Exception:
            logger.exception("dispatch of task %s failed", record.id)
            await self._fail_and_retry(record.id, "instance_down", async_timeout)
            return
        logger.info("_pump: exit")
        set_task_id(None)

    async def _fail_and_retry(self, record_id: str, reason: str, async_timeout: float) -> None:
        self.queue.fail(record_id, reason)
        set_task_id(None)
        await self._pump(async_timeout)

    async def submit(self, question: str, workspace: str, summary: str | None = None) -> dict:
        """Submit a question without waiting; returns a pollable handle.
        
        Args:
            question: The task question/prompt.
            workspace: Path to the workspace directory.
            summary: Optional one-line human-readable task summary (ADR-0086).
                     When the prompt is offloaded to a brief file (over the encoded-length
                     threshold), it's prepended to the pointer prompt shown in the foreground.
                     Ignored for inline (non-offloaded) dispatch. Capped at 600 encoded chars,
                     truncated with ' ...' if longer.
        """
        question = _validate(question, workspace)
        validated_summary = _validate_summary(summary)
        record = self.queue.submit(question, workspace, validated_summary)
        set_task_id(record.id)
        await self._pump(_async_timeout())
        return {"handle": record.id, "status": "submitted", "reason": None}

    def _compute_activity(self, record: Record, baseline_tool_uses: int) -> Activity | None:
        """Stall predicate for a dispatched task (ADR-0085 decision 3).

        `baseline_tool_uses` is the `tool_uses` count snapshotted at poll
        entry; a delta against it overrides recency. The reference instant
        for recency is `last_event_at` if a hook has fired, else
        `dispatch_at` — so a dispatched task with zero hook events is judged
        by how long it has been dispatched, not by queue time.
        """
        if record.status == QUEUED:
            return None
        if record.status in (ANSWERED, FAILED):
            return "live"

        if record.tool_uses > baseline_tool_uses:
            return "live"

        reference_instant = record.last_event_at if record.last_event_at is not None else record.dispatch_at
        if reference_instant is not None and time.monotonic() - reference_instant <= ACTIVITY_STALE_THRESHOLD:
            return "live"
        return "stalled"

    def _poll_response(self, status: str, record: Record | None, *, reason: str | None = None, activity: Activity | None = None) -> dict:
        return {
            "status": status,
            "answer": record.answer if record and status == "answered" else None,
            "command": record.command if record and status == "answered" else None,
            "reason": reason,
            "tool_uses": record.tool_uses if record else None,
            "last_event_at": record.last_event_at if record else None,
            "activity": activity,
        }

    def poll(self, handle: str, baseline_tool_uses: int | None = None) -> dict:
        """Report the current state of a submitted question. Never blocks.

        `baseline_tool_uses` anchors the stall predicate for a dispatched
        record; if omitted, the record's current `tool_uses` is used as its
        own baseline (no delta possible — recency alone decides).
        """
        record = self.queue.get(handle)
        if record is None:
            return self._poll_response("failed", None, reason="unknown_handle")

        baseline = baseline_tool_uses if baseline_tool_uses is not None else record.tool_uses
        activity = self._compute_activity(record, baseline)

        if record.status == ANSWERED:
            return self._poll_response("answered", record, activity=activity)
        if record.status == FAILED:
            return self._poll_response("failed", record, reason=record.reason, activity=activity)
        return self._poll_response("pending", record, activity=activity)

    async def poll_async(self, handle: str, poll_timeout_seconds: float | None = None) -> dict:
        """Poll with optional long-poll support.

        Args:
            handle: The record handle to poll.
            poll_timeout_seconds: None (indefinite wait), 0 (immediate snapshot), or positive (bounded wait).

        Returns:
            Dict with status, answer, command, reason, tool_uses, last_event_at, activity.
            On timeout, returns {"status": "timed_out", ...} with the task still pending.
        """
        record = self.queue.get(handle)
        if record is None:
            return self._poll_response("failed", None, reason="unknown_handle")

        if record.status in (ANSWERED, FAILED):
            return self.poll(handle)

        # Snapshot tool_uses at poll entry — the stall predicate's baseline.
        baseline_tool_uses = record.tool_uses

        if poll_timeout_seconds == 0:
            return self.poll(handle, baseline_tool_uses)

        if poll_timeout_seconds is None:
            await record.signal_event.wait()
            return self.poll(handle, baseline_tool_uses)

        try:
            await asyncio.wait_for(record.signal_event.wait(), timeout=poll_timeout_seconds)
            return self.poll(handle, baseline_tool_uses)
        except asyncio.TimeoutError:
            activity = self._compute_activity(record, baseline_tool_uses)
            return self._poll_response("timed_out", record, activity=activity)

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
