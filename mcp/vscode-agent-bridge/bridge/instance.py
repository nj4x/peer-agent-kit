"""Dedicated VS Code instance lifecycle (design/70, ADR-0071).

One persistent window per MCP server process, at a PID-scoped
``~/.vscode-agent-bridge/data-<pid>``, spawned by this process. Liveness is
not the `code` CLI's exit status — that process hands
off to the real Electron main process and exits immediately regardless of
outcome — it is the companion extension's WebSocket connection, tracked via
``mark_connected``/``mark_disconnected`` from the hook server.
"""

from __future__ import annotations

import asyncio
import json
import os
import shutil
from pathlib import Path

from bridge.logsetup import get_logger

logger = get_logger("instance")

SPAWN_TIMEOUT = 30.0

# Canonical shared cline-sr config dir, symlinked into every PID-scoped
# session's globalStorage before spawn (ADR-0072).
CANONICAL_CONFIG_DIR = Path(
    os.path.expanduser("~/.vscode-agent-bridge/data/User/globalStorage/saoudrizwan.claude-dev")
)

# Suppress every first-run interactive prompt so a fresh dedicated window
# needs no human click before cline-sr can run (task/77).
SEED_SETTINGS = {
    "security.workspace.trust.enabled": False,
    "workbench.startupEditor": "none",
    "workbench.tips.enabled": False,
    "workbench.welcomePage.walkthroughs.openOnInstall": False,
    "extensions.ignoreRecommendations": True,
    "update.mode": "none",
    "telemetry.telemetryLevel": "off",
    "settingsSync.enabled": False,
    "github.gitAuthentication": False,
}


class InstanceUnreachable(RuntimeError):
    """The dedicated window did not come up (or reconnect) in time."""


class InstanceManager:
    def __init__(self, code_bin: str = "code") -> None:
        self._code_bin = code_bin
        self.workspace: str | None = None
        self._open_root: Path | None = None  # Actual folder open in VS Code (ADR-0073)
        self._alive = False
        self._connected = asyncio.Event()
        self._proc: asyncio.subprocess.Process | None = None
        self._pid = os.getpid()
        self._data_dir = Path(os.path.expanduser(f"~/.vscode-agent-bridge/data-{self._pid}"))
        self._sweep_orphaned_data_dirs()

    @property
    def alive(self) -> bool:
        return self._alive

    def mark_connected(self) -> None:
        self._alive = True
        self._connected.set()

    def mark_disconnected(self) -> None:
        self._alive = False
        self._connected.clear()

    def close(self) -> None:
        if self._proc is not None and self._proc.returncode is None:
            self._proc.terminate()
        self._alive = False

    def _sweep_orphaned_data_dirs(self) -> None:
        """Best-effort removal of dead servers' data-<pid> dirs (ADR-0071).

        Never raises: cleanup is best-effort, not a liveness precondition.
        """
        parent = self._data_dir.parent
        try:
            entries = list(parent.iterdir())
        except OSError:
            return
        for entry in entries:
            if not entry.name.startswith("data-"):
                continue  # excludes the canonical "data" dir (no trailing pid)
            suffix = entry.name[len("data-") :]
            try:
                pid = int(suffix)
            except ValueError:
                continue  # non-integer suffix: not a session dir, skip
            if pid == self._pid:
                continue  # never sweep our own dir
            try:
                os.kill(pid, 0)
            except ProcessLookupError:
                pass  # dead: fall through to sweep
            except OverflowError as exc:
                # pid outside pid_t range: treat as dead, but log per ticket's
                # error policy ("unexpected os.kill exceptions, including OverflowError")
                logger.warning("orphan data-dir sweep: os.kill(%d) out of range: %s", pid, exc)
            except PermissionError:
                continue  # alive under another user: keep
            except OSError as exc:
                logger.warning("orphan data-dir sweep: os.kill(%d, %s) failed: %s", pid, entry, exc)
                continue
            else:
                continue  # alive: keep
            try:
                shutil.rmtree(entry)
            except OSError as exc:
                logger.warning("orphan data-dir sweep: failed to remove %s: %s", entry, exc)

    def _create_config_symlink(self) -> None:
        """Symlink this session's globalStorage to canonical cline-sr config (ADR-0072)."""
        tgt = CANONICAL_CONFIG_DIR
        tgt.mkdir(parents=True, exist_ok=True)  # bootstrap: target must exist on fresh install
        src = self._data_dir / "User" / "globalStorage" / "saoudrizwan.claude-dev"
        if src.is_symlink():
            if src.resolve() == tgt.resolve():
                return  # already wired (idempotent re-entry)
            raise RuntimeError(
                f"{src} is a symlink to {os.readlink(src)}, expected {tgt}; remove the stale link"
            )
        if src.exists():
            raise RuntimeError(
                f"{src} exists as a real directory, expected symlink; "
                "remove or migrate it before delegating"
            )
        src.parent.mkdir(parents=True, exist_ok=True)
        src.symlink_to(tgt)

    def _seed_settings(self) -> None:
        settings_path = self._data_dir / "User" / "settings.json"
        settings_path.parent.mkdir(parents=True, exist_ok=True)
        existing: dict = {}
        if settings_path.exists():
            try:
                existing = json.loads(settings_path.read_text())
            except (json.JSONDecodeError, OSError):
                return  # unreadable user file — leave it untouched
        merged = {**SEED_SETTINGS, **existing}
        if merged != existing:
            settings_path.write_text(json.dumps(merged, indent=2) + "\n")

    async def ensure_ready(self, workspace: str, port: int) -> None:
        """Spawn or reuse the dedicated window so `workspace` is open in it.

        Uses path normalization and sub-workspace containment check (ADR-0073):
        - Normalizes the requested workspace via Path.resolve() (self._open_root is
          already resolved when it was previously set)
        - Skips window reload if requested workspace is nested under open root
        - Updates self._open_root only on spawn/reuse-window, not on sub-workspace shortcut
        """
        workspace_resolved = Path(workspace).resolve()

        # Sub-workspace check: if new workspace is nested in open root, skip window reload.
        # self._open_root tracks the actual VS Code folder (the last path passed to `code`);
        # self.workspace is caller-facing metadata and is updated independently.
        if self._alive and self._open_root and workspace_resolved.is_relative_to(self._open_root):
            self.workspace = str(workspace_resolved)  # update metadata only; _open_root unchanged
            return

        # Different workspace: open in reused window (or spawn if not alive)
        # (Note: is_relative_to also returns True for exact equality, so no separate
        # exact-match guard is needed — the branch above already handles it.)
        self._connected.clear()
        args = [self._code_bin, "--user-data-dir", str(self._data_dir)]
        if self._alive:
            args.append("--reuse-window")
        args.append(str(workspace_resolved))

        if not self._alive:
            self._create_config_symlink()
            self._seed_settings()
        env = {**os.environ, "BRIDGE_PORT": str(port)}
        self._proc = await asyncio.create_subprocess_exec(*args, env=env)
        logger.info(
            "VS Code spawn: pid=%d workspace=%s port=%d data_dir=%s",
            self._proc.pid,
            workspace_resolved,
            port,
            self._data_dir,
        )
        await self._proc.wait()  # the `code` CLI hands off and exits at once (design/70)
        logger.info("`code` CLI exited: code=%s", self._proc.returncode)

        try:
            await asyncio.wait_for(self._connected.wait(), timeout=SPAWN_TIMEOUT)
        except asyncio.TimeoutError as exc:
            raise InstanceUnreachable(f"extension did not connect within {SPAWN_TIMEOUT}s") from exc
        self.workspace = str(workspace_resolved)
        self._open_root = workspace_resolved  # record actual VS Code folder for future containment checks
