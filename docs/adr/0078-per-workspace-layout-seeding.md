---
artifact-type: adr
lineage-rules:
  - "ADR must reference at least one source SRS item"
source-srs: .data/requirements/peer-agent-kit-SRS-001.md
---

# ADR-0078: Per-Workspace Layout Seeding from the Template's Empty-Window State

**Status**: Accepted

**Source SRS**: SRS-PAK-007

## Context

ADR-0076 copies the template profile into every fresh session data-dir, but accepted a limitation: pane geometry applies only when the session's workspace path exactly matches a path previously opened in the template window. VS Code keys workspace-scoped layout (panel position, panel/sidebar size, maximize state, editor grid) under `User/workspaceStorage/<hash>/state.vscdb`, where `<hash>` is `md5(fsPath + birthtime-ms)` of the workspace folder (`createSingleFolderWorkspaceId`, vscode `workspaces.ts`). A delegated task's folder that the template never opened resolves to a hash with no stored state, so the window falls back to VS Code default layout.

Two facts sharpen the problem:

1. **View dock position is profile-scoped, not workspace-scoped.** The `views.customizations` key (which container a view lives in — sidebar vs panel) sits in `User/globalStorage/state.vscdb` and applies to all windows. ADR-0076's globalStorage copy already carries it; a window showing the cline-sr view in the "wrong" container reflects the template's own stored customization, not a copy gap.
2. **`--reuse-window` folder switches full-reload the workbench** (microsoft/vscode#35109, #108575), re-reading the incoming folder's workspaceStorage. The live pane arrangement does not survive a folder switch, so seeding only the first-opened folder is not enough — every unseen folder needs its own storage dir before its open.

The template window is launched with no folder argument (ADR-0076), so the layout the user arranges there lands in an *empty-window* workspaceStorage dir (numeric-ID name, no `workspace.json`) — copied into each session data-dir at session start, but never consulted by VS Code for folder windows.

## Decision

`InstanceManager` seeds workspace-scoped layout per open, in `ensure_ready()`, immediately before the `code` CLI spawn/reuse call (and not on the ADR-0073 sub-workspace shortcut, which triggers no reload):

- **Hash computation** (`_workspace_storage_id`): mirrors VS Code — `md5(fsPath + String(ctime))`; ctime is birthtime-ms on macOS/Windows, inode on Linux. Node rounds fractional ms half-up (`dateFromMs` adds 0.5 before Date truncation), so the Python port does `trunc(ms + 0.5)`, not plain truncation — verified against six real VS Code-created workspaceStorage dirs. A wrong hash is inert: VS Code creates its own dir and the folder gets default layout, the pre-ADR baseline.
- **Skip-if-seeded**: if `workspaceStorage/<hash>/` already exists in the session data-dir (copied from the template at session start, or seeded earlier this session), it stands untouched. Layout captured once per folder; mid-session template edits do not retro-apply.
- **Seed source**: the most-recently-modified empty-window dir (no `workspace.json`) in the session's own workspaceStorage — i.e. the template layout as snapshotted at session start, consistent with ADR-0076's spawn-time-snapshot semantics.
- **Seed content**: whole `state.vscdb` cloned via the SQLite online backup API (same helper as ADR-0076), plus a `workspace.json` naming the folder URI. Whole-file clone accepted deliberately: non-layout keys cloned along with layout (history entries, mementos) reference paths VS Code re-validates on open; dangling references are ignored.
- **Failure policy**: best-effort, same rationale as ADR-0076 — seeding is an enhancement over the default-layout baseline, never a spawn blocker. Any failure is caught, logged at WARNING, and the open proceeds. A dest dir left without `state.vscdb` after a failed backup is removed so the skip-if-seeded check cannot lock out a future attempt.

## Consequences

- **Pro**: The pane layout the user arranges in the template window reaches every delegated folder, including paths the template never opened — closes ADR-0076's accepted limitation.
- **Pro**: No new dependencies; reuses ADR-0076's SQLite backup helper and the already-copied empty-window snapshot.
- **Con**: The hash formula is a private VS Code implementation detail (`workspaces.ts`); a VS Code change silently degrades seeding to the default-layout baseline. Detectable by orphaned seeded dirs next to VS Code-created ones for the same folder.
- **Con**: Whole-file clone copies non-layout workspace state (history, mementos) from the empty window into folder storage. Accepted: stale entries are inert.
- **Con**: A folder first opened *before* the user arranges the template keeps its earlier-seeded layout for the session (skip-if-seeded). A fresh session picks up the new arrangement.

## Related

- **ADR-0076**: Template-profile bootstrap — session-start snapshot this ADR extends per-folder
- **ADR-0073**: Sub-workspace reuse — its shortcut path performs no reload, hence no seed
- **docs/research/window-layout-mismatch-root-cause.md**: root-cause analysis (workspace-hash keying, profile vs workspace scope)
