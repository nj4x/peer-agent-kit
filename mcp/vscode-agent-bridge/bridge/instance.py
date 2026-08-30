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
import sqlite3
from pathlib import Path

from bridge.logsetup import get_logger

logger = get_logger("instance")

SPAWN_TIMEOUT = 30.0

# Canonical shared cline-sr config dir, symlinked into every PID-scoped
# session's globalStorage before spawn (ADR-0072).
CANONICAL_CONFIG_DIR = Path(
    os.path.expanduser("~/.vscode-agent-bridge/data/User/globalStorage/saoudrizwan.claude-dev")
)

# User's once-configured canonical VS Code profile, copied into every fresh
# session data-dir on spawn (ADR-0076). `settings.json` existing under here
# is the configured-marker (see install.sh).
TEMPLATE_USER_DIR = Path(os.path.expanduser("~/.vscode-agent-bridge/data/User"))

# ADR-0072's symlink target — must never be clobbered by the template copy.
_TEMPLATE_COPY_EXCLUDED_GLOBAL_STORAGE = "saoudrizwan.claude-dev"

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
    "extensions.confirmedUriHandlerExtensionIds": ["cline-sr.cline-sr"],
    "github.copilot.enable": {"*": False},
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

    def _copy_template_profile(self) -> None:
        """Copy the user's configured profile into this session's data-dir (ADR-0076).

        Enhancement over the seed-only path, not a prerequisite: any failure
        degrades to today's functional baseline rather than failing spawn.
        """
        try:
            self._copy_template_profile_unsafe()
        except Exception as exc:  # noqa: BLE001 - best-effort per ADR-0076 Failure policy
            logger.warning("template profile copy failed, continuing seed-only: %s", exc)

    def _copy_template_profile_unsafe(self) -> None:
        if not (TEMPLATE_USER_DIR / "settings.json").exists():
            return  # template unconfigured: degrade to seed-only path

        dest_user = self._data_dir / "User"

        for name in ("settings.json", "keybindings.json", "snippets"):
            src = TEMPLATE_USER_DIR / name
            if src.exists():
                self._copy_template_entry(src, dest_user / name)

        src_workspace_storage = TEMPLATE_USER_DIR / "workspaceStorage"
        if src_workspace_storage.is_dir():
            for hash_dir in src_workspace_storage.iterdir():
                self._copy_template_entry(hash_dir, dest_user / "workspaceStorage" / hash_dir.name)

        src_global_storage = TEMPLATE_USER_DIR / "globalStorage"
        if src_global_storage.is_dir():
            for entry in src_global_storage.iterdir():
                if entry.name == _TEMPLATE_COPY_EXCLUDED_GLOBAL_STORAGE:
                    continue  # stays an ADR-0072 symlink, never overwritten
                try:
                    if entry.resolve() == CANONICAL_CONFIG_DIR.resolve():
                        continue  # reject symlinks resolving to canonical-config
                except (OSError, RuntimeError):
                    pass  # unresolvable: let copy error handler catch it
                self._copy_template_entry(entry, dest_user / "globalStorage" / entry.name)

        # User/History/ is intentionally skipped: session-specific.

    def _copy_template_entry(self, src: Path, dst: Path) -> None:
        if src.is_symlink():
            return  # skip symlinks; only copy real files and follow dirs (not symlink-to-dir)
        if src.is_dir():
            dst.mkdir(parents=True, exist_ok=True)
            for child in src.iterdir():
                self._copy_template_entry(child, dst / child.name)
        elif src.suffix == ".vscdb":
            self._backup_sqlite_file(src, dst)
        elif src.name.startswith(src.stem + ".vscdb"):
            return  # skip .vscdb sidecars (-wal, -shm, -journal); only snapshot via backup API
        else:
            dst.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(src, dst)

    def _backup_sqlite_file(self, src: Path, dst: Path) -> None:
        """Snapshot a `.vscdb` file via SQLite's online backup API.

        A raw copy risks torn pages; the online backup API produces a
        transactionally consistent snapshot even if the template window is
        live and mid-write. Rollback-journal mode means a writer's EXCLUSIVE
        lock can still raise OperationalError — caught here, per-file, so one
        locked file doesn't abort the rest of the copy (ADR-0076).
        """
        dst.parent.mkdir(parents=True, exist_ok=True)
        src_conn = None
        dst_conn = None
        try:
            src_conn = sqlite3.connect(str(src))
            dst_conn = sqlite3.connect(str(dst))
            src_conn.backup(dst_conn)
        except sqlite3.Error as exc:
            logger.warning("template profile copy: skipping %s (sqlite backup failed): %s", src, exc)
            try:
                if dst_conn is not None:
                    dst_conn.close()
                    dst_conn = None
                dst.unlink(missing_ok=True)  # no partial/empty snapshot left behind
            except Exception as cleanup_exc:  # noqa: BLE001
                logger.warning(
                    "template profile copy: cleanup failed for %s, continuing: %s", dst, cleanup_exc
                )
        finally:
            if dst_conn is not None:
                try:
                    dst_conn.close()
                except Exception:  # noqa: BLE001
                    pass  # best effort, don't interrupt finally chain
            if src_conn is not None:
                try:
                    src_conn.close()
                except Exception:  # noqa: BLE001
                    pass  # best effort, don't interrupt finally chain

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
            self._copy_template_profile()
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
