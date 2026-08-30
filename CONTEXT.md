# CONTEXT.md

Domain terminology and architecture decisions for peer-agent-kit.

## Ubiquitous language

**Bridge**:
The single orchestration object per MCP server process owning the `BridgeQueue`, `InstanceManager`, and `HookServer`. Exposes `ask()` / `submit()` / `poll()` / `close()` methods for the four MCP tools and runs the pump/sweep loop that dispatches queued tasks to the dedicated VS Code window.
_Avoid_: orchestrator, facade, coordinator

**Session** (observability):
One MCP server process lifetime, identified by its start timestamp (`YYYYMMDDTHHMMSS`). Session-scoped events (WS connect/disconnect, sweep runs, instance spawn/exit) go to a global session log at `~/.vscode-agent-bridge/logs/<session-id>.log`, independent of any workspace.
_Avoid_: run, instance (conflicts with `InstanceManager`'s Instance)

**Task Log**:
The per-task log file under `~/.vscode-agent-bridge/<normalized-workspace-dir-name>/<task-id>.log`, recording queue status transitions and hook POSTs for one task. Its events are also mirrored into the current Session's log for a single chronological view.
_Avoid_: task file, record log

**Delegation mode**:
Per-session policy for when and what the local LLM should delegate to the peer agent (cline-sr). Modes (off/lite/full/max) control which work stays local vs. farms to the peer. Mode persists repo-scoped in `.claude/.peer-agent-mode` (with repo) or globally in `~/.claude/.peer-agent-active` (no repo), so each session starts in the mode last set.
_Avoid_: delegation policy, work mode, peer mode

**Open root**:
`InstanceManager._open_root` — the folder actually open in the dedicated VS Code window (the last path passed to `code`). Distinct from `InstanceManager.workspace`, which is caller-facing metadata updated on every `ensure_ready()` call, including sub-workspace short-circuits that leave `_open_root` untouched.
_Avoid_: workspace root, active folder

## Architecture decisions

**Session-scoped VS Code instance** (ADR-0071, ADR-0072, ADR-0075):
Each MCP server process gets its own dedicated VS Code window, keyed by server PID (`~/.vscode-agent-bridge/data-<pid>`), instead of sharing one fixed data dir across concurrent Claude Code sessions. This eliminates the collision where a second session's `BRIDGE_PORT` never reaches the shared window's extension. Each PID-scoped data dir gets its `User/globalStorage/saoudrizwan.claude-dev` symlinked to a canonical shared directory (`~/.vscode-agent-bridge/data/User/globalStorage/saoudrizwan.claude-dev`, ADR-0072) before spawn, so every session shares cline-sr's API keys, memory, and preferences despite having an isolated window. Orphaned `data-<pid>` dirs from dead server processes are swept on `InstanceManager.__init__` via a liveness probe (`os.kill(pid, 0)`), best-effort and non-fatal.

**Sub-workspace dispatch** (ADR-0073):
`InstanceManager.ensure_ready(workspace)` resolves both the requested and currently-open paths with `Path.resolve()` before comparing, eliminating false mismatches from trailing slashes or symlink aliases. If the requested workspace is nested under `_open_root` (`workspace_resolved.is_relative_to(_open_root)`), the manager short-circuits: no `code --reuse-window` call, no window reload, `workspace` metadata updates but `_open_root` does not. Because no reload happens, cline-sr receives no workspace-root-change signal and keeps resolving relative paths against the open root — task prompts targeting a sub-workspace must use absolute paths or paths relative to the open root (see `skills/peer-agent/SKILL.md`).

**Why peer-agent-kit is separate from caveman-kit:**
Each kit solves orthogonal concerns — caveman is terse writing style, peer-agent is work delegation — and should be installable independently. Both kits use the same hook/badge injection machinery, but target different rules. Separating them lets users adopt either, both, or neither without version coupling.

**Why MCP server is bundled, not npm-pinned:**
The vscode-agent-bridge server is long-lived infrastructure (runs for the lifetime of the Claude Code IDE process), and its dependencies matter to reliability. Bundling it as a local directory in the kit lets `install.sh` and `uninstall.sh` manage its full lifecycle without depending on npm registry availability or version resolution at install time. It also simplifies local development — edits to the server take effect after IDE restart, no rebuild cycle.

**Why extension is symlinked, not copied:**
VS Code extensions in `~/.vscode/extensions/` are typically copied; peer-agent-kit uses a symlink to the bundled `extension/` directory. This lets local dev builds take effect immediately after IDE restart without a rebuild-symlink cycle. Uninstall then only removes the symlink, not the source tree, making byte-exact restore trivial. The caveat: if the symlink is accidentally dereferenced or the extension directory moves, the extension disappears until reinstalled.

**Why mode file is in .claude/, not .git/info/exclude:**
The mode file (`.claude/.peer-agent-mode`) lives in a `.claude/` subdirectory instead of `.git/info/exclude` so that repo-scoped state can accumulate in one place as the kit is used alongside other Claude Code features. `.git/info/exclude` is a per-repo hook, not a general state store. The `.claude/` directory is auto-gitignored by Claude Code.

## Coexistence with caveman-kit

Both kits inject into the same `settings.json` hook entries and `statusline.sh` badge sections. They coexist by:

1. **Using distinct markers**: Each hook entry and badge section is wrapped in a comment marker (e.g., `# CAVEMAN_KIT_START` / `# CAVEMAN_KIT_END` for caveman, `# PEER_AGENT_KIT_START` / `# PEER_AGENT_KIT_END` for peer-agent). Uninstall removes only the block matching its own marker, leaving other kits' injections intact.

2. **Preserving post-install edits**: Both `install.sh` and `uninstall.sh` use surgical patching (marker-based removal, not byte-exact restoration), so user edits made after installation survive a subsequent install/uninstall of either kit.

3. **Hook ordering**: SessionStart and UserPromptSubmit hooks from both kits run sequentially in the order they appear in `settings.json` after installation. If both kits are active, caveman's rules fire first (injected first), then peer-agent's rules. For full/max modes, this means caveman compression happens before the peer-agent ruleset is injected — a deliberate ordering to compress first, then delegate the compressed output.

4. **Statusline badges**: Both kits add their own single-line badge to `statusline.sh`. Badges appear as separate lines, one per kit, so a session with both active shows two status lines (e.g., `[caveman: ultra]` and `[peer-agent: full]`).

**Token cost of both kits active**: When both are installed and active, SessionStart adds ~300 tokens for caveman's ruleset and ~500 tokens for peer-agent's per-mode policy. UserPromptSubmit adds no extra tokens (hooks fire, side effects are injected at next response). Post-install, the user can disable either kit via `/caveman off` or `/peer-agent off`, shedding its injection cost.
