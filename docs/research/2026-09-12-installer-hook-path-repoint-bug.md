# Bug: Installer Does Not Repoint Hook Paths on Reinstall to Different Location

**Status:** Real installer bug — verified against source  
**Severity:** High — users reinstalling to a different location get stale hook paths  
**Reproduced:** Yes, confirmed in source code and logic flow

---

## Summary Verdict

**This is a genuine installer idempotency bug**, not user error or working-as-designed.

When `install.sh` runs a second time to a **different target directory**, hook paths in `settings.json` remain pointing at the old location because:

1. `settings-patch.js` checks if hooks are "already injected" by searching command strings for marker text (`peer-agent-activate.js`, `peer-agent-mode-tracker.js`)
2. If markers are found, it skips the entire entry and returns false (already present)
3. It **never examines or updates the path** embedded in those commands
4. Therefore, stale paths survive intact across reinstall to a new location

The workaround requires manual `settings.json` editing or running `uninstall.sh` before reinstalling.

---

## Install Model: Multiple Directory Confusion

`install.sh` defines three separate directory variables for different purposes, creating ambiguity:

| Variable | Purpose | Value | Defined at | Notes |
|----------|---------|-------|------------|-------|
| `KIT_DIR` | Source/dev repo | `$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)` | Line 16 | Where install.sh itself lives |
| `KIT_HOME` | Runtime installation target | `$HOME/.peer-agent-kit` | Line 18 | Always fixed; manifest + hooks stored here |
| `INSTALL_DIR` | Curl-install source dir | `${PEER_AGENT_KIT_INSTALL_DIR:-$HOME/.local/share/peer-agent-kit}` | Line 26 | Used only for uninstall message + rollback |

**What the code does:**

1. `bootstrap.sh` clones/pulls to `$INSTALL_DIR` (default: `~/.local/share/peer-agent-kit`)
2. Runs `$INSTALL_DIR/install.sh`
3. `install.sh` **always installs runtime artifacts to `$KIT_HOME = ~/.peer-agent-kit`**, regardless of where `install.sh` itself was invoked from
4. Runtime hooks are copied from `$KIT_DIR/hooks/` to `$KIT_HOME/hooks/` (line 309)
5. `settings.json` hook commands are patched to reference `$KIT_HOME/hooks/` (line 315)

**Documentation claim vs. actual behavior:**

- README.md line 36 states uninstall path: `~/.local/share/peer-agent-kit/uninstall.sh`
- README.md line 43 states uninstall path: `./uninstall.sh`
- **Actual behavior:** Runtime hooks always copied to `~/.peer-agent-kit/hooks/`, not `~/.local/share/peer-agent-kit/hooks/`
- **Consequence:** The documented uninstall paths in README are misleading — the actual uninstall script that matches the installed state lives at `~/.peer-agent-kit` (via manifest), not at the curl-install dir

---

## Where Hook Paths Are Constructed

**File:** `/Users/r.herasymenk/workspace/peer-agent-kit/lib/settings-patch.js`  
**Lines:** 17–18, 36–38

```javascript
const activateCmd = `CLAUDE_PLUGIN_ROOT='${pluginRoot}' node '${hooksDir}/peer-agent-activate.js'`;
const trackerCmd = `CLAUDE_PLUGIN_ROOT='${pluginRoot}' node '${hooksDir}/peer-agent-mode-tracker.js'`;

function alreadyInjected(event, marker) {
  const arr = settings.hooks[event];
  if (!Array.isArray(arr)) return false;
  return arr.some(entry =>
    Array.isArray(entry.hooks) &&
    entry.hooks.some(h => typeof h.command === 'string' && h.command.includes(marker))
  );
}

function inject(event, command, marker) {
  if (!Array.isArray(settings.hooks[event])) settings.hooks[event] = [];
  if (alreadyInjected(event, marker)) return false;  // ← KEY DECISION: silently skip if marker found
  settings.hooks[event].push({ hooks: [{ type: 'command', command }] });
  return true;
}

const addedStart = inject('SessionStart', activateCmd, 'peer-agent-activate.js');
const addedSubmit = inject('UserPromptSubmit', trackerCmd, 'peer-agent-mode-tracker.js');
const addedSubagent = inject('SubagentStart', activateCmd, 'peer-agent-activate.js');
```

**How it's called from install.sh (line 315):**

```bash
node "$KIT_DIR/lib/settings-patch.js" "$SETTINGS" "$KIT_HOME/hooks" "$PLUGIN_ROOT"
```

`$KIT_HOME/hooks` is passed as the `hooksDir` argument. On first install, this builds commands like:

```
CLAUDE_PLUGIN_ROOT='...' node '~/.peer-agent-kit/hooks/peer-agent-activate.js'
```

---

## Idempotency Bug: Repoint Detection Missing

**The bug:** When `install.sh` runs again:

1. **First run (to `~/.peer-agent-kit`):**
   - settings.json is patched with: `node '~/.peer-agent-kit/hooks/peer-agent-activate.js'`
   - Marker check `alreadyInjected(event, 'peer-agent-activate.js')` returns true (marker is in the command)
   - `inject()` returns false (already present)

2. **Second run (same location or different):**
   - `$KIT_HOME/hooks` still resolves to `~/.peer-agent-kit/hooks`
   - `alreadyInjected()` checks if `'peer-agent-activate.js'` appears in any command
   - Previous command from run 1 still contains that marker → returns true
   - `inject()` returns false → **command is never rebuilt or updated**
   - Hook paths in settings.json remain unchanged

3. **If user had manually installed to `~/workspace/peer-agent-kit/` first, then official install to `~/.peer-agent-kit/`:**
   - User's manual settings.json has: `node '~/workspace/peer-agent-kit/hooks/peer-agent-activate.js'`
   - `alreadyInjected()` finds `'peer-agent-activate.js'` in that old command → returns true
   - `inject()` skips; old path is never replaced with new path

**Root cause:** `alreadyInjected()` is a binary check (present/not-present), not a path validator. It has no logic to detect or fix stale paths.

---

## Contrast: Uninstall Removes Without Path Validation

**File:** `/Users/r.herasymenk/workspace/peer-agent-kit/lib/settings-unpatch.js`  
**Lines:** 32–55

```javascript
function removeHooks(event, marker) {
  const arr = settings.hooks[event];
  if (!Array.isArray(arr)) return 0;
  
  const originalLength = arr.length;
  const filtered = arr.filter(entry => {
    // Keep entries that don't contain our marker
    if (!Array.isArray(entry.hooks)) return true;
    return !entry.hooks.some(h => 
      typeof h.command === 'string' && h.command.includes(marker)
    );
  });
  
  const removed = originalLength - filtered.length;
  
  // Clean up empty arrays
  if (filtered.length === 0) {
    delete settings.hooks[event];
  } else {
    settings.hooks[event] = filtered;
  }
  
  return removed;
}
```

Uninstall correctly removes by marker regardless of the path embedded in the command. But install's check is one-directional: it detects presence but not what's inside.

---

## Install.sh Manifest Consistency Issues

**File:** `/Users/r.herasymenk/workspace/peer-agent-kit/install.sh`  
**Lines:** 252–457 (manifest writes throughout)

The manifest records the actual paths installed:

```json
{
  "installedAt": "...",
  "claudeDir": "...",
  "settingsBackup": "~/.peer-agent-kit/backup/settings.json.bak",
  "statuslineBackup": "...",
  "mcpConfigBackup": "...",
  "mcpPriorEntry": "...",
  "pluginRoot": "...",
  "skillInstalledByKit": true/false,
  "skillBackup": "...",
  "kitSha": "...",
  "completed": true
}
```

The manifest correctly notes `settingsBackup` as living under `$KIT_HOME` (not `$INSTALL_DIR`). But there is **no record of which directory the hooks are actually at**, and `settings-patch.js` receives that path as a transient argument, never stored for validation on re-run.

---

## MCP Registration Path Handling (Comparison)

For contrast: **MCP registration correctly handles repointing** (file: `lib/mcp-patch.js`, lines 42–47):

```javascript
const existing = config.mcpServers[serverName];
if (existing && JSON.stringify(existing) !== JSON.stringify(newEntry)) {
  console.log(`vscode-agent-bridge entry already exists, repointing to ${serverDir}`);
}

config.mcpServers[serverName] = newEntry;
```

MCP patch **compares the full entry JSON** and overwrites if different, achieving idempotent repointing. Settings patch should do the same.

---

## Documentation vs. Implementation Gap

**README.md expectations (user-facing):**
- Line 36: "The `peer-agent` skill and `vscode-agent-bridge` MCP server are bundled; `install.sh` places them in `$CLAUDE_CONFIG_DIR/skills/peer-agent/` and registers the server in `~/.claude.json`."
- Implied: Runtime always goes to a consistent location

**Actual behavior:**
- Hooks always go to `~/.peer-agent-kit/hooks`
- Skill goes to `$CLAUDE_CONFIG_DIR/skills/peer-agent`
- MCP registration in `~/.claude.json` points to `$KIT_DIR/mcp/vscode-agent-bridge` (the source dir where install.sh was invoked from, **not** a runtime copy)
- This creates a mix: skill is copied, MCP runs from source, hooks run from `~/.peer-agent-kit`

---

## Observed Failure Case

User had:
1. **Manual install from source:** `~/workspace/peer-agent-kit/` → settings.json hooked to `~/workspace/peer-agent-kit/hooks/`
2. **Official curl install:** `bootstrap.sh` → `~/.local/share/peer-agent-kit/` → ran install.sh
3. **Expected outcome:** settings.json hooks repointed to `~/.peer-agent-kit/hooks/` (the official install target)
4. **Actual outcome:** hooks still pointed at `~/workspace/peer-agent-kit/hooks/` because marker was found in old command and entry was skipped

User's workaround: Manually edited settings.json to point at new location.

---

## Recommendation: Fix Required

### Minimal Fix (Safest)

Modify `lib/settings-patch.js` to detect stale paths and always rebuild/replace hook entries if the path differs:

**File:** `lib/settings-patch.js`  
**Lines:** 20–34 (replace `alreadyInjected()` logic)

Change from marker-presence check to marker + path validation:

```javascript
function alreadyInjectedAtPath(event, marker, expectedPath) {
  const arr = settings.hooks[event];
  if (!Array.isArray(arr)) return false;
  return arr.some(entry =>
    Array.isArray(entry.hooks) &&
    entry.hooks.some(h => 
      typeof h.command === 'string' && 
      h.command.includes(marker) &&
      h.command.includes(expectedPath)  // ← NEW: validate the path is current
    )
  );
}

function inject(event, command, marker, expectedPath) {
  if (!Array.isArray(settings.hooks[event])) settings.hooks[event] = [];
  if (alreadyInjectedAtPath(event, marker, expectedPath)) return false;  // ← Updated call
  
  // If marker exists but path is stale, remove it before adding new
  if (alreadyInjected(event, marker)) {
    settings.hooks[event] = settings.hooks[event].filter(entry => 
      !(Array.isArray(entry.hooks) && entry.hooks.some(h => 
        typeof h.command === 'string' && h.command.includes(marker)
      ))
    );
  }
  
  settings.hooks[event].push({ hooks: [{ type: 'command', command }] });
  return true;
}
```

Then update inject calls to pass `expectedPath`:

```javascript
const hooksPath = path.resolve(hooksDir);
const addedStart = inject('SessionStart', activateCmd, 'peer-agent-activate.js', hooksPath);
const addedSubmit = inject('UserPromptSubmit', trackerCmd, 'peer-agent-mode-tracker.js', hooksPath);
const addedSubagent = inject('SubagentStart', activateCmd, 'peer-agent-activate.js', hooksPath);
```

**Impact:** Re-running install.sh to the same or different target location will now detect stale paths and repoint them. Existing user edits to other hooks are preserved.

### Alternative: Marker-Based Removal + Re-add (Higher Risk)

Unconditionally remove and re-add on every run (like uninstall + install):
- Simpler logic, but removes user customizations more aggressively
- Not recommended unless path collisions are common

### Store Path in Manifest (Future Hardening)

Record installed hook path in manifest alongside skill and MCP entries, so future runs can validate:

```json
{
  "hooksPath": "~/.peer-agent-kit/hooks",
  ...
}
```

Then validate before skipping on re-run.

---

## Files Involved

- **Source:** `/Users/r.herasymenk/workspace/peer-agent-kit/lib/settings-patch.js` (lines 20–34)
- **Called by:** `/Users/r.herasymenk/workspace/peer-agent-kit/install.sh` (line 315)
- **Uninstall (works correctly):** `/Users/r.herasymenk/workspace/peer-agent-kit/lib/settings-unpatch.js` (lines 32–55)
- **MCP patch (for contrast):** `/Users/r.herasymenk/workspace/peer-agent-kit/lib/mcp-patch.js` (lines 42–47)

---

## Related ADRs / Docs

- CONTEXT.md — records ubiquitous language but does not document the multi-directory design
- README.md — implies hooks/skill/MCP all go to consistent runtime location, but they don't
- ADR-0081 — mentions manifest.kitSha tracking, but no mention of hooks path validation

---

## Test Case for Fix Validation

```bash
# First install to default (~/.peer-agent-kit)
./install.sh --no-install-skill

# Verify hooks in settings.json point to ~/.peer-agent-kit/hooks
grep "peer-agent-activate.js" ~/.claude/settings.json | head -1

# Edit settings.json to point hooks to a fake old location
sed -i "" 's|peer-agent-kit/hooks|workspace/old-kit/hooks|g' ~/.claude/settings.json

# Re-run install.sh
./install.sh --no-install-skill

# Check: hooks should now point back to ~/.peer-agent-kit/hooks (fixed by patch)
grep "peer-agent-activate.js" ~/.claude/settings.json | head -1
# Expected: ~/.peer-agent-kit/hooks (repointed)
# Current (buggy): workspace/old-kit/hooks (stale, unchanged)
```
