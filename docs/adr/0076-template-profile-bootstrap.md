---
artifact-type: adr
lineage-rules:
  - "ADR must reference at least one source SRS item"
source-srs: .data/requirements/peer-agent-kit-SRS-001.md
---

# ADR-0076: Template-Profile Bootstrap for VS Code First-Run Suppression

**Status**: Accepted

**Source SRS**: SRS-PAK-007

## Context

Each bridge session spawns its dedicated VS Code window with a fresh PID-scoped `--user-data-dir` (ADR-0071). A fresh user-data-dir triggers interactive first-run prompts that block automation: the welcome page, the workspace-trust warning, the URI-handler trust dialog ("Allow 'Cline SR' extension to open this URI?") fired by the extension's `vscode://cline-sr.cline-sr/task` dispatch path, and the GitHub Copilot sign-in prompt (the user's shared `~/.vscode/extensions` loads Copilot into the dedicated window). It also starts with default editor appearance: no user theme, keybindings, or pane geometry.

The existing `SEED_SETTINGS` dict in `bridge/instance.py` suppresses part of this (workspace trust, startup editor, tips, walkthroughs, recommendations, update mode, telemetry, settings sync, git auth) but misses the URI-handler trust dialog and Copilot sign-in. Pane geometry (sidebar width/visibility, panel state, editor grid splits) cannot be expressed in `settings.json` at all — VS Code stores it as per-workspace SQLite state under `User/workspaceStorage/<hash>/state.vscdb`, where `<hash>` derives from the workspace path (independent of the user-data-dir). Naively copying live SQLite files risks torn writes; copying from the user's *real* profile is best-effort at best (the delegated workspace may never have been opened there). See `docs/research/vscode-user-dir-preseeding.md` for the underlying VS Code internals research.

## Decision

Two cooperating mechanisms:

**1. Extend `SEED_SETTINGS`** with verified-real keys only (each traced to VS Code source in the research doc; speculative keys such as `chat.experimental.enabled` are excluded):

- `"extensions.confirmedUriHandlerExtensionIds": ["cline-sr.cline-sr"]` — pre-trusts cline-sr's URI handler, suppressing the trust dialog.
- `"github.copilot.enable": {"*": false}` — disables Copilot in the dedicated window (the window exists only for cline-sr), suppressing its sign-in prompt.

**2. Template profile at `~/.vscode-agent-bridge/data/User`** — a canonical, user-configured VS Code profile copied into every fresh session data-dir:

- **Location**: the canonical `~/.vscode-agent-bridge/data/` dir already hosts cline-sr's shared config (ADR-0072) and is already excluded from the orphan sweep (ADR-0071 — no `data-<pid>` suffix). No VS Code process uses it as a live data-dir during delegation, so sessions copy from a quiescent-or-lightly-used source, never contend with each other on it.
- **Configuration**: `install.sh` checks whether `~/.vscode-agent-bridge/data/User/settings.json` exists. This specific file — not the parent directory — is the configured-marker, because ADR-0072's symlink bootstrap already creates `User/globalStorage/saoudrizwan.claude-dev/` as a side effect, making directory existence a false positive. If missing and stdin is a TTY, `install.sh` explains the purpose (one-time window to configure the theme/layout every delegated session will inherit) and asks for confirmation before launching `code --user-data-dir ~/.vscode-agent-bridge/data` with **no folder argument** (the window's job is profile configuration, not a project). Fire-and-forget: the `code` CLI hands off and exits immediately, so the installer prints guidance and continues — it cannot and does not wait for the window to close. If stdin is not a TTY (CI/scripted install), the launch is skipped silently.
- **Propagation**: `InstanceManager` gains a copy helper invoked on fresh spawn (the `not self._alive` branch of `ensure_ready()`), **before** `_seed_settings()`. It copies from the template into the session's `data-<pid>` dir:
  - `User/settings.json`, `User/keybindings.json`, `User/snippets/` — plain copy.
  - `User/workspaceStorage/` — all hash subdirectories. A hash applies only when the session opens the same absolute workspace path that was open in the template; a non-matching hash is inert, not harmful.
  - `User/globalStorage/` contents **except** `saoudrizwan.claude-dev`, which remains ADR-0072's symlink and must never be overwritten by the copy.
  - `User/History/` — skipped (session-specific).
  - Every `*.vscdb` file among the above is snapshotted via SQLite's online backup API (stdlib `sqlite3`, `src_conn.backup(dst_conn)`) instead of a raw file copy. **Deliberate departure from the research doc**: `docs/research/vscode-user-dir-preseeding.md` §7 lists `state.vscdb` under "Avoid copying" and §8 rates copying it "Not recommended" — but both verdicts evaluate *raw binary copy* only (torn pages, lock contention, binary portability). The online backup API is a fourth option the research doc did not evaluate: it produces a transactionally consistent snapshot through SQLite itself, eliminating the torn-page and portability objections. Lock contention remains possible and is handled by the error path below. **No WAL-mode assumption is made**: VS Code's SQLite files may run in rollback-journal mode, where a writer's EXCLUSIVE lock makes `backup()` raise `sqlite3.OperationalError` — exactly when the template window is live and mid-write. **Per-file error handling**: any `sqlite3.Error` from opening or backing up a `.vscdb` file is caught, logged at WARNING with the file path, and that file is skipped; the copy continues with the remaining files. A skipped `.vscdb` degrades one workspace's pane geometry to VS Code defaults — never a spawn failure.
  - If the template is unconfigured (no `User/settings.json`), the copy step is skipped entirely and behavior degrades to today's seed-only path.
  - **Failure policy — deliberate divergence from ADR-0071**: ADR-0071's contract (lines 67-77) makes errors in the `not self._alive` branch fatal, propagating as a spawn failure, because `_create_config_symlink()` and `_seed_settings()` are *prerequisites* — without them the session runs with a blank cline-sr config. The template copy is an *enhancement* over the already-working seed-only path, not a prerequisite: a session without the copied profile is exactly today's functional baseline. The copy helper therefore wraps its whole body (and each per-file step, per the `.vscdb` handling above) in a catch-log-continue policy: any exception (disk full, permission denied, SQLite failure) is caught, logged at WARNING, and the spawn proceeds seed-only. Fatal-propagate applies to prerequisites; best-effort applies to enhancements. `_create_config_symlink()` and `_seed_settings()` retain ADR-0071's fatal semantics unchanged.
- **Merge semantics preserved**: `_seed_settings()` still runs after the copy with `merged = {**SEED_SETTINGS, **existing}` — template-copied settings win over seed defaults on conflicting keys. Deliberate template edits (e.g. re-enabling a suppressed feature) are respected; seed keys fill only the gaps.

## Consequences

- **Pro**: Fresh dedicated windows need no human click before cline-sr can run — URI trust and Copilot sign-in join the already-suppressed first-run prompts.
- **Pro**: Theme, keybindings, snippets, and pane geometry persist across sessions once the user configures the template a single time; no per-session setup.
- **Pro**: No new dependencies — SQLite backup uses stdlib `sqlite3`; the template dir and its sweep exclusion already exist (ADR-0071/0072).
- **Con**: Pane geometry applies only when the session's workspace path exactly matches a path previously opened in the template window (workspace-hash keying). ~~Accepted limitation, not a gap to fix.~~ Closed by ADR-0078 (per-workspace layout seeding from the empty-window state).
- **Con**: One new interactive `install.sh` step. Mitigated: TTY-gated (silent skip in CI), confirmation-prompted, fire-and-forget.
- **Con**: Copied profile is a spawn-time snapshot; template edits made after a session spawns do not propagate to that session. Next fresh spawn picks them up.
- **Con**: The copy is best-effort by design (see Failure policy): a copy error yields a seed-only session with default appearance rather than a visible spawn failure, so a persistently failing copy surfaces only in WARNING logs. Accepted — cosmetic degradation must not block delegation.
- A regression test in `tests/test_instance.py` asserts the two new `SEED_SETTINGS` keys are present, guarding against accidental key drops.

## Related

- **ADR-0071**: Session-scoped VS Code instance (PID-keyed data dir, orphan sweep)
- **ADR-0072**: Shared cline-sr config via symlink (canonical dir this template extends; copy must not clobber the symlink)
- **docs/research/vscode-user-dir-preseeding.md**: VS Code internals research grounding the settings keys and storage-format choices
