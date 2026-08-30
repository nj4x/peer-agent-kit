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
from pathlib import Path

from bridge.logsetup import get_logger

logger = get_logger("instance")

SPAWN_TIMEOUT = 30.0

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
        self._alive = False
        self._connected = asyncio.Event()
        self._proc: asyncio.subprocess.Process | None = None
        self._pid = os.getpid()
        self._data_dir = Path(os.path.expanduser(f"~/.vscode-agent-bridge/data-{self._pid}"))

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
        """Spawn or reuse the dedicated window so `workspace` is open in it."""
        if self._alive and self.workspace == workspace:
            return

        self._connected.clear()
        args = [self._code_bin, "--user-data-dir", str(self._data_dir)]
        if self._alive:
            args.append("--reuse-window")
        args.append(workspace)

        self._seed_settings()
        env = {**os.environ, "BRIDGE_PORT": str(port)}
        self._proc = await asyncio.create_subprocess_exec(*args, env=env)
        logger.info(
            "VS Code spawn: pid=%d workspace=%s port=%d data_dir=%s",
            self._proc.pid,
            workspace,
            port,
            self._data_dir,
        )
        await self._proc.wait()  # the `code` CLI hands off and exits at once (design/70)
        logger.info("`code` CLI exited: code=%s", self._proc.returncode)

        try:
            await asyncio.wait_for(self._connected.wait(), timeout=SPAWN_TIMEOUT)
        except asyncio.TimeoutError as exc:
            raise InstanceUnreachable(f"extension did not connect within {SPAWN_TIMEOUT}s") from exc
        self.workspace = workspace
