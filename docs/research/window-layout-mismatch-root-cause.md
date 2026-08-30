# Window Layout Mismatch: Template Profile Bootstrap Limitation

**Research date**: August 30, 2026  
**Problem**: The dedicated VS Code window spawned by the MCP server (`mcp/vscode-agent-bridge/bridge/instance.py`) does not inherit the pane layout (view container locations, panel maximization state) configured in the template profile, even when `install.sh` prompts the user to configure them.

**Root cause**: A **documented-but-accepted limitation in ADR-0076** — VS Code keys workspace-specific layout state (`User/workspaceStorage/<hash>/state.vscdb`) by a workspace-path hash, and the template profile's layout only applies when the delegated task opens the exact workspace path previously opened in the template window during configuration.

---

## Findings

### 1. How VS Code Stores Window Layout

View container locations (sidebar, panel, secondary sidebar), panel maximization state, and editor grid splits are stored per-workspace in SQLite:

- **Location**: `User/workspaceStorage/<hash>/state.vscdb` (binary SQLite database)
- **Hash derivation**: Computed from the absolute workspace folder path by VS Code's `StorageService` (see [microsoft/vscode/src/vs/platform/storage](https://github.com/microsoft/vscode/tree/main/src/vs/platform/storage))
- **Keying**: The hash is **workspace-path-specific and location-independent**. The same folder path always hashes to the same value, regardless of which `--user-data-dir` or OS user opened it.
- **Consequence**: If the template window configured layout for workspace `/path/to/project-A`, the hash subdir `workspaceStorage/<hash-of-project-A>/` contains that layout state. A delegated session opening `/path/to/project-B` looks for `workspaceStorage/<hash-of-project-B>/`, which does not exist in the template and therefore does not get copied — the session gets VS Code defaults.

**Source**:
- ADR-0076, lines 36–37: "Pane geometry applies only when the session workspace path matches one opened in the template window (VS Code keys it by workspace-path hash) — accepted limitation."
- `mcp/vscode-agent-bridge/bridge/instance.py`, lines 171–174: The copy function does copy all `workspaceStorage/<hash-dir>/` subdirectories, but only the hashes that exist in the template at copy time are included.

### 2. Template Profile Copy Mechanism (ADR-0076 Implementation)

The `_copy_template_profile()` method (instance.py:149–158) is invoked before each fresh spawn:

```python
def _copy_template_profile_unsafe(self) -> None:
    if not (TEMPLATE_USER_DIR / "settings.json").exists():
        return  # template unconfigured: degrade to seed-only path

    dest_user = self._data_dir / "User"

    # Copy settings, keybindings, snippets (settings.json contains no layout keys)
    for name in ("settings.json", "keybindings.json", "snippets"):
        src = TEMPLATE_USER_DIR / name
        if src.exists():
            self._copy_template_entry(src, dest_user / name)

    # Copy workspaceStorage/<hash-dir>/ — but only those that exist in template
    src_workspace_storage = TEMPLATE_USER_DIR / "workspaceStorage"
    if src_workspace_storage.is_dir():
        for hash_dir in src_workspace_storage.iterdir():
            self._copy_template_entry(hash_dir, dest_user / "workspaceStorage" / hash_dir.name)
```

**Key constraint**: Only `workspaceStorage/` subdirectories present in the template are copied. If the template window never opened the delegated workspace path, its layout hash does not exist in the template.

**Source**: `mcp/vscode-agent-bridge/bridge/instance.py:171–174`

### 3. Install.sh Template Configuration Flow

`install.sh` (lines 291–323) offers a one-time configuration prompt:

```bash
echo "This opens a one-time VS Code window where you can set your theme, keybindings,"
echo "and pane layout — every future delegated session inherits it (no project folder"
echo "will be opened; this window is for profile setup only)."
```

The launched window uses:
```bash
code --user-data-dir "$HOME/.vscode-agent-bridge/data" --disable-extension nj4x.vscode-agent-bridge
```

**Critical detail**: No folder argument is passed (line 309). The template window is opened **without any workspace folder**, so the user configures theme/keybindings in a profile-scoped context, not in a workspace context.

**Consequence**: When the user configures pane layout in this window (e.g., moving cline-sr chat to sidebar), it is stored as:
- **Profile-scoped state** in `User/state.vscdb` (PROFILE scope, not WORKSPACE scope), OR
- No workspace-specific state at all (since no folder was opened)

But when a delegated session opens workspace `/path/to/project`, the layout it should inherit is workspace-specific, keyed by the hash of `/path/to/project`. That hash does not exist in the template (the template window never opened `/path/to/project`), so the session gets VS Code defaults.

**Source**: `install.sh:309` (no folder arg); `docs/research/vscode-user-dir-preseeding.md:138–141` (workspace vs. profile-scoped storage).

### 4. Why Settings.json Alone Is Insufficient

Pane layout cannot be expressed in `settings.json`. The following *can* be:

- Theme: `"workbench.colorTheme"`
- Icon theme: `"workbench.iconTheme"`
- Font size: `"editor.fontSize"`

But **not**:

- Sidebar width or visibility per workspace
- Panel height or maximization state
- View container locations (which view lives in which panel/sidebar)
- Editor grid splits and their dimensions

These all live in per-workspace `state.vscdb` under the workspace's hash subdir.

**Source**: `docs/adr/0076-template-profile-bootstrap.md:16` — "Pane geometry (sidebar width/visibility, panel state, editor grid splits) cannot be expressed in `settings.json` at all — VS Code stores it as per-workspace SQLite state under `User/workspaceStorage/<hash>/state.vscdb`."

### 5. Workspace-Hash Computation Is Path-Based

VS Code computes the workspace hash from the folder's absolute path. The algorithm is not fully public, but in practice:

- Hash is deterministic: same absolute path always yields same hash
- Hash is workspace-specific: changing the folder path changes the hash
- Hash is independent of `--user-data-dir`: opening `/path/to/project` in data-dir-A produces the same hash as in data-dir-B

**Source**: [microsoft/vscode/src/vs/workbench/services/storage/common/storageService.ts](https://github.com/microsoft/vscode/blob/main/src/vs/workbench/services/storage/common/storageService.ts) — workspace hash computation via `hash()` on the workspace URI.

### 6. Observed Symptom Explanation

The user observes:
- **Template window** (configured once): cline-sr chat docked in secondary sidebar (beside editor)
- **Dedicated bridge window** (spawned by MCP): cline-sr chat in bottom PANEL (full-width, maximized)

**Explanation**:
1. User configures template window without a folder open — any pane rearrangement is profile-scoped only
2. User closes template window
3. Delegated session spawns, opens `/path/to/delegated/workspace`
4. Spawn copies template profile, including `User/settings.json` and `User/state.vscdb` (PROFILE scope)
5. Copied profile has theme/keybindings but **no workspace-specific layout** for `/path/to/delegated/workspace` (that hash never existed in template)
6. VS Code initializes the session with defaults: cline-sr chat view goes to panel (default), appears maximized (default)
7. If the user later configures cline-sr's layout in the dedicated window and closes it, the next session may remember it — **only if the next session opens the same workspace path**.

### 7. The Accepted Limitation (ADR-0076)

This is not a bug; it is an **intentional, documented limitation**:

> "**Con**: Pane geometry applies only when the session's workspace path exactly matches a path previously opened in the template window (workspace-hash keying). **Accepted limitation, not a gap to fix.**"  
> — ADR-0076, Consequences section

The rationale:
- Copying workspace-specific state across different workspace paths produces inert copies (wrong hash = ignored by VS Code)
- Naively copying the user's live profile risks torn writes and binary portability issues
- Template profile bootstrap is an *enhancement* (nicer first-run) over the already-working seed-only baseline; it is best-effort by design

---

## Candidate Fixes Evaluated

### Fix 1: Pre-populate Workspace-Specific State for All Delegated Paths (Not feasible)

**Idea**: Detect common project paths and pre-populate their workspace-storage hashes in the template.

**Problem**:
- Delegated workspaces are user-specific and not known at install time
- Pre-populating arbitrary paths would create stale/orphaned state
- VS Code does not provide a public API to compute the hash programmatically

**Verdict**: Not feasible.

### Fix 2: Use VS Code's Experimental `--profile` Flag (Limited scope)

**Idea**: Use `code --profile <name>` to create a named profile template that persists across sessions (not PID-keyed data-dirs).

**Problem**:
- This would contradict ADR-0071 (session-scoped PID-keyed data-dir) by introducing shared state
- Multi-session collision gaps (ADR-0075) resurface
- Extension's BRIDGE_PORT env handoff already depends on per-session isolation

**Verdict**: Not compatible with architecture.

### Fix 3: Seed Profile-Scoped Pane Layout Defaults (Partially viable)

**Idea**: Instead of workspace-specific layout, set profile-scoped defaults for panels/sidebars using settings keys.

**Candidates**:
- `"workbench.panel.defaultLocation"`: `"bottom"` | `"right"` | `"left"` (VS Code 1.74+)
- `"workbench.sideBar.location"`: `"left"` | `"right"`

**Limitation**: VS Code lacks configuration keys for:
- Default panel maximization state
- Default locations for specific view containers (e.g., cline-sr chat specifically to sidebar)
- Default sidebar width or per-panel visibility

**Verdict**: Partial fix — can set sidebar/panel location defaults, but not per-view-container or maximization state. Better than nothing; would help the observed symptom partially.

### Fix 4: Programmatic View Movement via Extension (Not recommended)

**Idea**: Add code to the companion extension to move the cline-sr view to the sidebar on activation.

**Implementation**: Use VS Code's Commands API:
```typescript
await vscode.commands.executeCommand('workbench.action.moveViewToSidebar', 'cline-sr.cline-sr');
```

**Problem**:
- Requires the view to already exist; view is created on-demand by cline-sr on first use
- Timing: extension activation ≠ view creation; command may execute too early
- Fragile: relies on undocumented internal command names (may change across VS Code versions)
- Overrides user preference: if user moved the view elsewhere, extension forcefully resets it

**Verdict**: Possible but not recommended — too fragile and overrides user intent.

### Fix 5: Document Workaround + Provide a Reset Script (Recommended pragmatic path)

**Idea**: Keep the architecture as-is (it's sound), but:
1. Document the limitation explicitly in CLAUDE.md
2. Provide a helper script that copies workspace-specific state from the user's real profile into the template for commonly-delegated workspaces

**How it works**:
- After user configures template + opens a delegated workspace in the template window (and arranges pane layout), run a helper
- Helper extracts the workspace-hash from that window's storage and appends it to the template's workspaceStorage/
- Next spawn of the same workspace gets the layout

**Verdict**: Low-risk, respects user intent, leverages existing architecture.

---

## Recommended Fix

**Combination approach** (minimal risk, maximum benefit):

1. **Document the limitation** in `CLAUDE.md` under "Template profile bootstrap":
   - Explain that layout applies only to workspaces previously opened in the template window
   - Suggest: users open their common delegated workspaces in the template (once) to capture layout; next time those workspaces are delegated, they inherit layout

2. **Add profile-scoped defaults** to `SEED_SETTINGS` (instance.py:42–54):
   ```python
   SEED_SETTINGS = {
       ...existing keys...
       "workbench.panel.defaultLocation": "right",  # or "bottom" — user's preference
       "workbench.sideBar.location": "left",
   }
   ```
   This ensures the first session gets reasonable defaults, even if workspace-specific state is missing.

3. **Optional: helper script** for power users:
   - Script to copy workspace-storage hash from user's real profile into the template
   - Document in a separate research note or ADR if adopted

**Rationale**:
- Respects the existing, sound architecture (ADR-0071 session isolation, ADR-0076 bootstrap design)
- Fixes the most common case (users with recurring delegated workspaces) via template reuse
- Improves baseline experience (all sessions) with sensible defaults
- Minimal code change; no new dependencies

---

## Summary

**Root Cause**:
- VS Code keys workspace-specific layout (pane locations, panel state) by a hash derived from the workspace path
- Template profile is configured without a folder open (profile-scoped only)
- Delegated sessions open workspace paths that likely were not opened in the template
- Hash mismatch → layout state not copied → session gets defaults

**Why It Happens**:
- install.sh (line 309) launches template window with no folder argument
- User configures theme/keybindings in profile context, not workspace context
- InstanceManager's copy (instance.py:171–174) correctly copies all template hashes, but template has no hash for delegated paths

**Evidence**:
- ADR-0076 lines 36–37: Limitation is documented and accepted
- instance.py lines 171–174: Copy logic is workspace-hash aware
- install.sh line 309: Template window has no folder argument

**Recommended Fix**:
1. Add documentation to CLAUDE.md explaining the workspace-hash keying
2. Add profile-scoped panel/sidebar location defaults to SEED_SETTINGS
3. (Optional) Provide a helper script for users to capture workspace layout in the template

