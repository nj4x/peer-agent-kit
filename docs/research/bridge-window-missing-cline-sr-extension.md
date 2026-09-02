# Bridge Window Missing cline-sr Extension

## Symptom

Bridge MCP server spawns dedicated VS Code window for workspace (e.g., `/Users/r.herasymenk/workspace/group-management`) but that window lacks the required `cline-sr` extension (ID: `saoudrizwan.cline-sr`), breaking delegation. Tasks fail with `instance_down` or hang indefinitely. Window fails to connect to bridge's HookServer despite companion extension being present and active.

## Root Cause

Commit `a85cacb` (2026-09-02, "fix(bridge): isolate extensions per bridge window to prevent profile conflicts") introduced per-window extension isolation via `--extensions-dir` flag, but **only seeds the companion bridge extension** into the isolated extensions directory — cline-sr (third-party marketplace extension) is not copied/symlinked into the isolated dir.

**Evidence:**

1. **Spawn command** (`mcp/vscode-agent-bridge/bridge/instance.py:413`):
   ```python
   args = [self._code_bin, "--user-data-dir", str(self._data_dir), 
           "--extensions-dir", str(self._data_dir / "extensions")]
   ```
   Each bridge window uses isolated `data-<pid>/extensions` dir, not global `~/.vscode/extensions`.

2. **Seeding logic** (`mcp/vscode-agent-bridge/bridge/instance.py:362-389`, `_seed_extensions_dir()`):
   - Looks for `saoudrizwan.cline-sr*` in `~/.vscode/extensions` (line 376)
   - If found, copies **only** that extension into isolated dir (line 387)
   - If **not** found, creates empty extensions dir and returns (line 381)
   - No other extensions from global profile are copied/symlinked

   Comment line 367: "Seed only the companion bridge extension; all others inherit user-configured extensions via symlink into main dir (symlink approach safer for future use)."
   
   This comment documents future intent but current implementation does **not** symlink user extensions; it only seeds companion extension and leaves the isolated dir barren.

3. **Companion extension ID mismatch**:
   - Code searches for: `"saoudrizwan.cline-sr"` (line 376)
   - Global `~/.vscode/extensions` contains: `cline-sr.cline-sr-1.25.1` (publisher: `saoudrizwan`, extension name in dir: `cline-sr`)
   - Both refer to same extension; search succeeds

4. **Live state**:
   - `~/.vscode/extensions/`: Contains 28 extensions including `cline-sr.cline-sr-1.25.1` (installed, active)
   - `~/.vscode-agent-bridge/data-*/extensions/`: Exist but **empty** or contain only companion bridge extension
   - Bridge windows launched subsequently lack cline-sr; hook scripts have nowhere to POST task lifecycle events

## Timeline

**Before a85cacb**: Bridge windows used global `--user-data-dir ~/.vscode-agent-bridge/data` (shared across all sessions) and global `--extensions-dir ~/.vscode/extensions` (inherited all installed extensions including cline-sr). **Problem**: PlantUML and other extensions conflicted across multiple windows, crashing extension host on teardown.

**a85cacb introduced** (2026-09-02 11:44:00 UTC):
- Per-window isolation: `data-<pid>` data-dir + `data-<pid>/extensions` extensions-dir
- Companion extension copy into isolated dir
- **Oversight**: No mechanism to provision cline-sr (third-party extension) into isolated dir

**Consequence**: Subsequent bridge windows lack cline-sr; tasks timeout with `instance_down`.

## Extension Install Paths

| Entity | Path | Responsibility |
|--------|------|-----------------|
| **Companion (vscode-agent-bridge)** | `~/.vscode/extensions/nj4x.vscode-agent-bridge-0.1.0` (symlink to repo `extension/`) | Symlinked by `install.sh` / `extension/npm run install-dev` |
| **cline-sr (third-party)** | `~/.vscode/extensions/cline-sr.cline-sr-1.25.1` | Installed by user via VS Code Marketplace (manual or automatic) |
| **Bridge window (companion)** | `data-<pid>/extensions/nj4x.vscode-agent-bridge-0.1.0` | **Copied** by `_seed_extensions_dir()` |
| **Bridge window (cline-sr)** | `data-<pid>/extensions/cline-sr.cline-sr-*` | **Missing** — not seeded by bridge code |

`install.sh` targets only companion extension (via `extension/npm run install-dev`); no logic seeds cline-sr into isolated directories (those directories did not exist before a85cacb).

## Fix Options

### Option A: Symlink User Extensions Directory (Future-Proof)

Symlink `~/.vscode/extensions` into each bridge window's isolated extensions dir (e.g., `data-<pid>/extensions/user-extensions → ~/.vscode/extensions`). VS Code's extension discovery searches multiple dirs, so symlinks work.

**Pros:**
- User's entire extension suite available in bridge window (not just cline-sr)
- Future marketplace extensions automatically included
- Minimal code change: one `symlink_to()` call in `_seed_extensions_dir()`

**Cons:**
- Defeats isolation's original goal (prevent extension conflicts from crashing windows)
- Returns to shared global state; PlantUML / similar conflicts resurface
- Symlink can break if user moves extensions dir or deletes extensions

### Option B: Copy cline-sr + Selective User Extensions

Extend `_seed_extensions_dir()` to copy both companion extension and a curated list (cline-sr, Python, etc.), excluding known-conflicting extensions (PlantUML, Copilot).

**Pros:**
- Isolates known-bad extensions while allowing essential ones (cline-sr, language servers)
- Keeps PlantUML out of bridge window; conflicts don't resurface
- Fully self-contained bridge window (no external references)

**Cons:**
- Maintains a hardcoded blocklist / allowlist; brittle when extension ecosystem changes
- New extensions require code changes
- Duplicates extensions on disk (data-<pid>/extensions/), higher storage footprint

### Option C: Install cline-sr On-Demand (Best UX)

Detect missing cline-sr at bridge window startup; invoke `code --install-extension saoudrizwan.cline-sr` into isolated extensions dir if absent.

**Pros:**
- Automatic, user-transparent
- Single source of truth: user's chosen extensions
- Scales to future extensions without code edits

**Cons:**
- Requires marketplace network access at spawn time (may fail if offline or registry slow)
- `code --install-extension` command takes 10-30s per extension (serial delay)
- Adds error handling for install failures (already logged as best-effort)

### Option D: Pre-Populate Shared Bridge Extensions Directory (Current Pattern)

Create a canonical `~/.vscode-agent-bridge/shared-extensions/` directory containing cline-sr (and future required extensions), seeded once at `install.sh` time (or lazily on first bridge spawn). Symlink all bridge windows' isolated extensions dirs to it.

**Pros:**
- Zero-copy: all bridge windows share one cline-sr installation
- Scales to multiple extensions
- Does not burden user's main `~/.vscode/extensions/`

**Cons:**
- Requires download/copy logic at install time (or dynamic fallback)
- Still a shared resource — if seeded extensions conflict with each other, all bridge windows fail
- Complex cleanup on uninstall

## Recommendation

**Option C (On-Demand Install)** balances automation, scalability, and user transparency.

1. At end of `_seed_extensions_dir()`, after companion extension is seeded, check if cline-sr is present in isolated dir.
2. If absent, invoke `code --install-extension saoudrizwan.cline-sr --extensions-dir <isolated-dir>` (non-blocking, best-effort).
3. Log at INFO if installed, WARNING if install fails; continue (spawn does not fail).
4. On next delegation, window will have cline-sr available.

**Rationale:**
- Cline-sr is the **single required extension** for bridge delegation; no others are critical to bridge function.
- Solves the immediate symptom (missing cline-sr) without reintroducing PlantUML conflicts.
- User experience: first delegation after install triggers cline-sr download (one-time, ~20s wait), subsequent delegations instant.
- If install fails (network, registry), warning logs point to manual fallback (user installs cline-sr in main profile; copy to isolated dir manually).

**Alternative if network latency is concern**: 
- Hybrid: offer Option A (symlink user extensions) as opt-in `--shared-extensions` flag, defaulting to Option C (on-demand install). Users with stable, conflict-free extension suites opt into faster bridge startup; others use on-demand install.

## Files Affected

- `mcp/vscode-agent-bridge/bridge/instance.py`: `_seed_extensions_dir()` method (lines 362–389)
  - Add cline-sr detection in isolated dir
  - Add fallback install logic
- Logs: `~/.vscode-agent-bridge/logs/<session>.log` (install attempt / success / failure)
- Documentation: Update ADR-0071 or create ADR-0085 to clarify extension seeding for third-party extensions
