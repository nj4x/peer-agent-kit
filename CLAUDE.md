# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Installer kit that wires the `peer-agent` Claude Code skill and the `vscode-agent-bridge` MCP server into an existing Claude Code configuration, letting Claude Code delegate tasks to cline-sr running in a dedicated VS Code window. Read `CONTEXT.md` first — it defines the ubiquitous language (Bridge, Session, Task Log, Delegation mode) and records the architecture decisions; use those terms exactly and avoid the listed synonyms.

## Commands

### MCP server (Python, `mcp/vscode-agent-bridge/`)

```sh
cd mcp/vscode-agent-bridge
uv venv .venv
uv pip install -e ".[dev]"
.venv/bin/pytest                          # full suite
.venv/bin/pytest tests/test_queue.py      # one file
.venv/bin/pytest tests/test_queue.py -k test_name   # one test
```

pytest is configured with `asyncio_mode = "auto"` — async test functions need no decorator.

### Extension (TypeScript, `extension/`)

```sh
cd extension
npm install
npm run compile        # tsc build to out/
npm run watch          # tsc --watch
npm run install-dev    # symlink into ~/.vscode/extensions/
```

### Kit install / uninstall

```sh
./install.sh                 # registers MCP server, injects hooks + statusline badge, symlinks extension
./install.sh --no-extension  # skip extension install
./uninstall.sh               # surgical marker-based removal
```

Changes to `~/.claude.json` take effect only after Claude Code / IDE restart.

## Architecture

Three cooperating parts plus installer plumbing:

1. **MCP server** (`mcp/vscode-agent-bridge/`) — Python, exposes `ask_peer_agent` / `submit_to_peer_agent` / `poll_peer_agent` / `close_peer_agent`. `server.py` holds the tool contract; `bridge/` holds the components: `bridge.py` (the Bridge — single orchestration object owning the pump/sweep loop), `queue.py` (BridgeQueue — task queue and status transitions), `instance.py` (InstanceManager — spawns/tracks the dedicated VS Code window, sets `BRIDGE_PORT` in its environment), `hookserver.py` (HookServer — HTTP endpoint receiving lifecycle events from cline-sr's hook scripts), `logsetup.py` (Session log + per-task Task Logs under `~/.vscode-agent-bridge/`).

2. **Companion extension** (`extension/`) — runs in every VS Code window; installs the five cline-sr hook script templates (`extension/hooks/`: TaskStart, PreToolUse, PostToolUse, TaskComplete, TaskCancel) into `~/Documents/Cline/Hooks/` idempotently (sha256 match skip, marker-identified rewrite, never overwrites foreign scripts). Only in the dedicated bridge window (`BRIDGE_PORT` set): holds the liveness WebSocket to the MCP server (socket close = instance down), and submits tasks via cline-sr's URI handler. Hook scripts POST their stdin JSON to the HookServer using `$BRIDGE_PORT`.

3. **Skill + hooks** (`skills/peer-agent/`, `hooks/`) — `SKILL.md` defines the per-mode delegation policies (off/lite/full/max) and the `/peer-agent` command. `hooks/` are Node scripts injected into Claude Code's `settings.json`: `peer-agent-activate.js` (SessionStart — injects the active mode's ruleset), `peer-agent-mode-tracker.js` (UserPromptSubmit), with `peer-agent-config.js` / `peer-agent-parse.js` shared helpers. Mode persists repo-scoped in `<repo>/.claude/.peer-agent-mode` when the repo has a `.claude/` directory, else globally in `~/.claude/.peer-agent-active`.

4. **Installer plumbing** (`install.sh`, `uninstall.sh`, `lib/`) — `lib/*-patch.js` / `lib/*-unpatch.js` are Node helpers for surgical marker-based edits to `settings.json`, `statusline.sh`, and `~/.claude.json`. Uninstall removes only blocks matching this kit's markers (`# PEER_AGENT-KIT BEGIN/END`, hook entries referencing the kit's script names) — never byte-exact restore — so post-install user edits and other kits' injections (caveman-kit uses the same machinery with its own markers) survive in any install/uninstall order.

Event flow for one delegated task: MCP tool call → Bridge enqueues → pump dispatches over the extension's WebSocket → extension opens cline-sr URI → cline-sr hook scripts POST lifecycle events (start, tool use, complete/cancel) to HookServer → Bridge resolves the task; `poll_peer_agent` reads queue state at any point.

## Agent skills

### Issue tracker

Issues live as GitHub issues. Use the `gh` CLI for all operations. See `docs/agents/issue-tracker.md`.

### Triage labels

Five canonical triage roles mapped to GitHub label strings. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context repo. Before exploring, read `CONTEXT.md`, `docs/adr/`, and any docs in `.data/`. See `docs/agents/domain.md`.

## Conventions

- Bundled, not fetched: the MCP server and extension live in this repo and are symlinked/registered in place, so local edits take effect after IDE restart with no rebuild-reinstall cycle (extension TypeScript still needs `npm run compile`).
- Design docs: `docs/adr/` (numbered ADRs), `docs/research/`, `docs/diagrams/` (PlantUML). ADR 0068 covers the orchestration module, 0069 observability, 0070 hook event correlation.
