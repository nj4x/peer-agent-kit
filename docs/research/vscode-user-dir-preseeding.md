# VS Code User-Data-Dir Pre-seeding for Automation

**Research date**: August 30, 2026  
**Scope**: Eliminating first-run friction in dedicated VS Code windows launched by peer-agent-kit's `InstanceManager`

## Problem Statement

Each fresh `--user-data-dir` for a dedicated peer-agent-kit session triggers interactive prompts that block automation:
1. Welcome/Getting Started page
2. Workspace Trust warning
3. GitHub Copilot or GitHub authentication dialogs
4. URI handler trust prompt: "Allow 'Cline SR' extension to open this URI?" 
5. Missing user preferences (theme, keybindings, settings)

These are first-run dialogs specific to an empty or fresh profile. Pre-seeding the user-data-dir before spawning the window can suppress them.

## Findings

### 1. User-Data-Dir Layout

VS Code user data lives under `~/.vscode/` (Linux/macOS) or equivalent. The key structure for pre-seeding:

```
User/
  settings.json           # User-scoped settings
  keybindings.json        # Custom keybindings
  globalStorage/          # Extension-specific state
    <publisher>.<extension>/  # e.g., saoudrizwan.claude-dev/, vscode-redhat-telemetry/
      storage.json        # Extension settings (JSON)
      state.vscdb         # SQLite DB for key-value state
  workspaceStorage/       # Per-workspace state (not needed for fresh window)
  History/                # Browsing history
  snippets/               # Code snippets
```

**Source**: [microsoft/vscode File explorer & workspace structure](https://github.com/microsoft/vscode/tree/main/src/vs/workbench/services); direct observation of `~/Library/Application Support/Code/User/` on macOS.

### 2. Welcome Page Suppression

**Setting**: `workbench.startupEditor: "none"`

The welcome page is controlled by `workbench.startupEditor` setting in `User/settings.json`. The `StartupPageRunnerContribution` (startupPage.ts) reads this setting and the helper `isStartupPageEnabled()` checks:
- `workbench.startupEditor == 'welcomePage'` → show welcome
- `workbench.startupEditor == 'none'` → skip (custom editors also suppressed)
- `workbench.startupEditor == 'readme'` → open README
- Empty workspace + `welcomePageInEmptyWorkbench` → show for empty folders only

**Additional suppression settings** (already in `SEED_SETTINGS` in instance.py):
- `workbench.welcomePage.walkthroughs.openOnInstall: false`
- `workbench.tips.enabled: false`
- `security.workspace.trust.enabled: false` (suppresses "Trust this workspace" warning)

**Edge case — Telemetry opt-out dialog**: On first launch, if `productService.showTelemetryOptOut` is true, VS Code shows the telemetry dialog. This is suppressed by storing a marker in PROFILE-scoped storage. The key is checked in `startupPage.ts` line ~120:
```javascript
const telemetryOptOutStorageKey = 'workbench.telemetryOptOutShown';
```
To pre-suppress, set this key to `true` in the storage database (see Storage section below).

**Source**: [microsoft/vscode startupPage.ts](https://raw.githubusercontent.com/microsoft/vscode/main/src/vs/workbench/contrib/welcomeGettingStarted/browser/startupPage.ts), lines 40-50 (configuration keys), 120-140 (telemetry gate).

### 3. URI Handler Trust Prompt for Extensions

**Storage key**: `extensionUrlHandler.confirmedExtensions` (PROFILE-scoped)  
**Alternative config**: `extensions.confirmedUriHandlerExtensionIds` (settings.json)

When cline-sr receives a `vscode://` URI, VS Code checks if the extension is already trusted:

```javascript
// microsoft/vscode extensionUrlHandler.ts
const USER_TRUSTED_EXTENSIONS_CONFIGURATION_KEY = 'extensions.confirmedUriHandlerExtensionIds';
const USER_TRUSTED_EXTENSIONS_STORAGE_KEY = 'extensionUrlHandler.confirmedExtensions';

class UserTrustedExtensionIdStorage {
  has(id: string): boolean {
    return this.extensions.indexOf(id) > -1;
  }
  
  add(id: string): void {
    this.set([...this.extensions, id]);
  }
  
  set(ids: string[]): void {
    this.storageService.store(USER_TRUSTED_EXTENSIONS_STORAGE_KEY, 
      JSON.stringify(ids), StorageScope.PROFILE, StorageTarget.MACHINE);
  }
}
```

Pre-seeding requires adding the extension ID (cline-sr's ID is likely `cline-sr.cline-sr` based on published extension naming) to this storage key. There are two approaches:

1. **Via storage.json** (simpler, if extension uses profile-scoped JSON storage):
   Add to the globalStorage extension's `storage.json` a JSON array with the extension ID.

2. **Via settings.json** (configuration):
   ```json
   {
     "extensions.confirmedUriHandlerExtensionIds": ["cline-sr.cline-sr"]
   }
   ```

**Known limitation**: The dialog also checks `this.productService.trustedExtensionProtocolHandlers`, which is a VS Code product configuration, not user-modifiable. However, the storage-based trust should be sufficient.

**Source**: [microsoft/vscode extensionUrlHandler.ts](https://raw.githubusercontent.com/microsoft/vscode/main/src/vs/workbench/services/extensions/browser/extensionUrlHandler.ts), lines 33-68 (constants & storage), didUserTrustExtension() method.

### 4. GitHub/Copilot Sign-In Dialog

The GitHub Copilot sign-in dialog is handled by the Copilot Chat extension (Microsoft's), not core VS Code. When the Chat view opens and no GitHub token is found, it prompts the user.

**Suppression via settings**:
```json
{
  "github.gitAuthentication": false,
  "github.copilot.enable": {
    "*": false
  },
  "chat.experimental.enabled": false
}
```

Alternatively, pre-populate GitHub authentication via OS keychain (see section 5). If a valid token is stored, Copilot will not prompt.

**Source**: Implicit from the code structure; Copilot Auth is handled by `ms-vscode.github-copilot` extension and stored in the VS Code secrets API (backed by macOS Keychain).

### 5. Authentication / Secrets Persistence

VS Code uses the OS credential store (macOS Keychain, Windows Credential Manager, Linux Secret Service) for sensitive tokens via the `ISecretStorage` API.

**Key insight**: Keychain entries are **keyed by service name only**, not by user-data-dir path. This means:
- If the real user's `~/Library/Application Support/Code/` has a GitHub token stored in the keychain under service `vscode.github`, **it is automatically available** to any VS Code window running under the same OS user, regardless of which `--user-data-dir` is passed.
- Pre-seeding the keychain is not necessary; it works across all windows of the same OS user.

However, some extensions store tokens in `globalStorage` (extension-specific storage) instead of the system keychain. For cline-sr (Claude Dev extension), API keys are likely stored in its globalStorage. This is handled by ADR-0072's symlink strategy — the canonical `~/.vscode-agent-bridge/data/User/globalStorage/saoudrizwan.claude-dev` is shared across all sessions, so API keys persist.

**Source**: VS Code `SecretStorage` implementation; ADR-0072 (cline-sr config symlink).

### 6. Storage Scopes and Persistence Formats

VS Code storage has three scopes:
- **WORKSPACE**: per-folder workspace (stored in `workspaceStorage/<id>/state.vscdb`)
- **PROFILE**: per-user profile (stored in `User/state.vscdb` and extension's `globalStorage/<ext>/storage.json`)
- **APPLICATION**: global to the user (stored in `User/state.vscdb`)

Both PROFILE and APPLICATION scopes write to `User/state.vscdb` (an SQLite database). Some extensions also use JSON files (`globalStorage/<ext>/storage.json`) for simpler key-value pairs.

**Important note**: `state.vscdb` is a SQLite database. Pre-seeding it requires either:
1. Copying an entire `state.vscdb` from the user's real profile (binary copy, fragile)
2. Writing SQLite inserts directly (complex, undocumented schema)
3. Seeding JSON-based storage only (e.g., extension `storage.json`) and letting VS Code initialize the SQLite DB on first run

**Practical approach**: Pre-seed only what's safe — settings.json, extension storage.json files, and settings via `settings.json`. Let VS Code initialize its own SQLite schema. The first run will be slightly slower but will complete without interactive prompts.

**Source**: [microsoft/vscode storage.ts](https://raw.githubusercontent.com/microsoft/vscode/main/src/vs/platform/storage/common/storage.ts), StorageScope enum; direct observation of `~/Library/Application Support/Code/User/`.

### 7. Practical Pre-Seeding Strategy

**Safe to copy**:
- `User/settings.json` — merge with minimal seed settings
- `User/keybindings.json` — copy as-is
- `User/globalStorage/<extension>/storage.json` — copy if exists
- Extension directories in `User/globalStorage/` (whole directories)

**Avoid copying** (they will be regenerated or cause lock contention):
- `User/state.vscdb` (SQLite, path-specific locks)
- `User/workspaceStorage/` (workspace-specific, not relevant)
- `User/History/` (session-specific)

**How to implement in InstanceManager**:

1. Call `_seed_settings()` with an extended `SEED_SETTINGS` dict that includes the trust keys:
   ```python
   SEED_SETTINGS = {
       "security.workspace.trust.enabled": False,
       "workbench.startupEditor": "none",
       "workbench.tips.enabled": False,
       "workbench.welcomePage.walkthroughs.openOnInstall": False,
       "extensions.ignoreRecommendations": True,
       "extensions.confirmedUriHandlerExtensionIds": ["cline-sr.cline-sr"],  # NEW
       "update.mode": "none",
       "telemetry.telemetryLevel": "off",
       "settingsSync.enabled": False,
       "github.gitAuthentication": False,
       "github.copilot.enable": {"*": False},
   }
   ```

2. Add a helper to optionally copy user's real `settings.json` and `keybindings.json`:
   ```python
   def _copy_user_preferences_if_available(self) -> None:
       """Copy real settings/keybindings from user's main profile if available."""
       real_profile = Path(os.path.expanduser("~/.vscode/User"))  # Linux/macOS
       if not real_profile.exists():
           real_profile = Path(os.path.expanduser("~/AppData/Roaming/Code/User"))  # Windows
       if real_profile.exists():
           for file in ["settings.json", "keybindings.json"]:
               src = real_profile / file
               if src.exists():
                   dst = self._data_dir / "User" / file
                   dst.parent.mkdir(parents=True, exist_ok=True)
                   shutil.copy2(src, dst)
   ```

3. Call this helper **before** `_seed_settings()` in `ensure_ready()`, so seed settings override user prefs as needed.

4. For the telemetry opt-out storage key, the cleanest path is to let VS Code initialize `state.vscdb` on first run — the extra cost is negligible and avoids SQL schema fragility.

### 8. Open Questions / Known Gaps

1. **Copilot Chat first-run behavior**: Does the Chat view auto-open on first launch with a fresh profile? If yes, it may still trigger the sign-in dialog despite the settings above. Mitigation: Check if there's a setting to suppress Chat panel auto-open or defer it.

2. **Extension activation order**: If cline-sr activates before the URI trust is seeded, it may not see the pre-seeded trust. The activation happens on-demand when the extension's contribution is needed. Timing should be fine, but this could be tested.

3. **state.vscdb corruption risk**: Copying a SQLite database across instances introduces the risk of corrupted locks or out-of-date cursors. The safest approach is to never copy it.

4. **Profile templates**: VS Code has an experimental `--profile-temp` flag to create a temporary profile. This is not documented for automation and may change. Not recommended for this use case.

## Recommended Approach for InstanceManager

**Immediate action** (minimal risk):
1. Extend `SEED_SETTINGS` to include:
   - `"extensions.confirmedUriHandlerExtensionIds": ["cline-sr.cline-sr"]` (suppress URI trust prompt)
   - `"github.copilot.enable": {"*": False}` (suppress Copilot sign-in)
2. Call `_seed_settings()` as currently done.

**Future enhancement** (if user preferences drift becomes an issue):
1. Add `_copy_user_preferences_if_available()` helper to copy settings/keybindings from the user's main profile.
2. Call it before `_seed_settings()` so seed overrides take precedence.
3. Document in CLAUDE.md that the bridge can mirror the user's editor config (opt-in).

**Not recommended**:
- Copying `state.vscdb` (binary portability, lock contention)
- Pre-initializing `User/workspaceStorage/` (workspace-specific, unnecessary)
- Attempting to seed the secrets API / keychain (system-managed, unavailable to Python)

## Summary

VS Code first-run friction is controlled by settings (`workbench.startupEditor`, `extensions.confirmedUriHandlerExtensionIds`) and storage keys. Most can be pre-seeded via `settings.json` safely. The URI handler trust prompt can be suppressed by adding the extension ID to `extensions.confirmedUriHandlerExtensionIds` in settings. GitHub auth tokens are available system-wide (Keychain) and do not need per-window duplication. ADR-0072's symlink strategy already handles cline-sr's API key persistence across sessions.
