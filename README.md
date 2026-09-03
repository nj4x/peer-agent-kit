# peer-agent-kit

Installer kit that wires the `peer-agent` Claude Code skill and `vscode-agent-bridge` MCP server into an existing Claude Code configuration.

`install.sh` registers the vscode-agent-bridge MCP server in `~/.claude.json`, installs the VS Code extension into `~/.vscode/extensions/`, and injects hook entries (`SessionStart`, `SubagentStart`, `UserPromptSubmit`) and a statusline badge into the Claude Code configuration. The MCP server exposes `submit_to_peer_agent` / `poll_peer_agent` / `close_peer_agent` tools. Everything it touches is backed up, so `uninstall.sh` can restore the original configuration exactly.

## Quick Install

One-liner installation (requires `git` and `curl`):

```bash
curl -fsSL https://raw.githubusercontent.com/nj4x/peer-agent-kit/main/bootstrap.sh | bash
```

The `peer-agent` skill is installed automatically. To skip that and manage it yourself:

```bash
curl -fsSL https://raw.githubusercontent.com/nj4x/peer-agent-kit/main/bootstrap.sh | bash -s -- --no-install-skill
```

Environment overrides:
- `PEER_AGENT_KIT_GIT_REPO` — Git repo URL (default: `https://github.com/nj4x/peer-agent-kit.git`)
- `PEER_AGENT_KIT_INSTALL_DIR` — Installation directory (default: `$HOME/.local/share/peer-agent-kit`)

## Manual Install

```bash
./install.sh                    # installs kit, registers MCP server, builds and symlinks extension, installs peer-agent skill
./install.sh --no-extension     # skips extension install
./install.sh --no-install-skill # skips the peer-agent skill install (bring your own)
```

To update:

```bash
~/.local/share/peer-agent-kit/update.sh   # quick-install path
./update.sh                               # manual-clone path
```

To revert:

```bash
~/.local/share/peer-agent-kit/uninstall.sh
```

Or if you cloned the repo manually:

```bash
./uninstall.sh
```

## Prerequisites

- `node` on `PATH`
- `git` and `curl` (for bootstrap one-liner)
- `~/.vscode/` directory (VS Code must be installed; extension install skipped with a warning if absent)

The `peer-agent` skill and `vscode-agent-bridge` MCP server are bundled; `install.sh` places them in `$CLAUDE_CONFIG_DIR/skills/peer-agent/` and registers the server in `~/.claude.json`.

## Per-repository mode

The delegation mode is repo-scoped when the repository root contains a `.claude/` directory: `/peer-agent <mode>` then reads and writes `<repo>/.claude/.peer-agent-mode` (auto-added to `.git/info/exclude`, so it stays local to your clone). Without a repo or `.claude/` directory, the global `~/.claude/.peer-agent-active` file is used. The repo file is also the persisted default for that repo — a new session starts in whatever mode was last set there.

## Modes

| Mode | Behavior |
|------|----------|
| `off` | No delegation — all work runs locally |
| `lite` | Delegate only simplest deterministic tasks; LLM designs/plans, peer executes pre-planned work |
| `full` (default) | LLM designs/plans/critiques; peer executes plans, validates reports, runs straightforward skill-based tasks |
| `max` | Delegate almost everything (token-economy mode); local: conversation/judgement, mode changes, verification of delegated work |

See [`SKILL.md`](skills/peer-agent/SKILL.md) for per-mode policies and worked examples.

## Layout

- `install.sh` / `uninstall.sh` — entry points
- `bootstrap.sh` — curl-installation bootstrap script
- `hooks/` — hook scripts injected into Claude Code configuration
- `lib/` — patch helpers shared by the hooks and installer
- `skills/peer-agent/` — the peer-agent skill (bundled)
- `mcp/vscode-agent-bridge/` — the MCP server (bundled)
- `extension/` — the VS Code extension source
- `docs/` — architecture and design decisions
- `tests/` — bats-core test suite
- `CONTEXT.md` — domain terminology and ubiquitous language

## Coexistence with caveman-kit

peer-agent-kit and caveman-kit can be installed together. Both kits inject hooks and statusline badges using distinct markers, so they compose additively: injections are concatenated, not conflicting, and uninstall order does not matter. Post-install user edits to settings and statusline survive both installs and uninstalls.

## Hazards and mitigations

**MCP server restart required after installation** — Changes to `~/.claude.json` take effect only when Claude Code restarts. Close and reopen your IDE.

**Bridge down fallback** — If the vscode-agent-bridge MCP server is unavailable (crashed, not started), the session will warn once and fall back to local execution for that task. The warning appears only once per session, not per task.

**Rollback on failure** — If installation fails at any point, a trap-based rollback automatically invokes `uninstall.sh` to clean up partial changes. The only escape is manual `rm -rf ~/.peer-agent-kit ~/.local/share/peer-agent-kit` if both install and rollback fail.
