# ADR-0004: Peer-agent mode flag precedence, and absolute `off`

**Date:** 2026-09-12

**Status:** Accepted

**Note:** This decision was made when the peer-agent mode-tracking mechanism was first built, and has been cited from code comments ever since (`hooks/peer-agent-mode-tracker.js:47,63`, `hooks/peer-agent-config.js:30,35-36,58,75`, `hooks/peer-agent-activate.js:34-35`, `lib/statusline-patch.js:18`) — but the ADR file itself was never written. This backfills it, alongside a real fix to the `off` semantics found while debugging a stuck statusline badge. Numbered `0004` to match the citations rather than the next free number in the `0068+` sequence used elsewhere in this repo.

## Context

peer-agent-kit tracks an active delegation mode (`off`/`lite`/`full`/`max`) in a flag file, read by `hooks/peer-agent-mode-tracker.js` (UserPromptSubmit hook), `hooks/peer-agent-activate.js` (SessionStart/SubagentStart hook), and the statusline badge injected by `lib/statusline-patch.js`. Two scopes exist:

- **Repo-scoped**: `<repo>/.claude/.peer-agent-mode`, used only when the repo has (or gets) a `.claude/` directory.
- **Global**: `~/.claude/.peer-agent-active` (or `$CLAUDE_CONFIG_DIR/.peer-agent-active`).

**Decision 6 (unchanged):** when reading the active mode, repo flag wins if present, else global flag, else the install-time built-in default (`getDefaultMode()`). A bare `.claude/` directory with no flag file inside it must not shadow the global flag — this stops a repo merely *having* a `.claude/` dir from silently resetting the user's personal default.

**The bug this ADR also fixes:** `off` was implemented by *deleting* the flag file at whichever scope was in play (`clearFlag()`), not by writing a value. Deleting the repo-scoped file doesn't mean off — per decision 6 it means "no local override," so the next hook invocation falls through to the global flag. If the global flag holds a stale non-off value, `off` only silences the single turn it was issued on, then reverts. This was confirmed by direct testing: piping a realistic slash-command envelope (`<command-name>/peer-agent</command-name><command-args>off</command-args>` plus the full expanded skill body, matching what Claude Code actually sends) into `peer-agent-mode-tracker.js` correctly deleted the repo-scoped file, but left an untouched, untraceable global flag (`max`) to resurface on the very next turn — reproducing a report of the statusline staying stuck at `[CLINE:MAX]` after `/peer-agent off`.

## Decision

`off` becomes an **absolute** state, not a scope-revert. It is written the same way as `lite`/`full`/`max` — an explicit value at whichever scope `resolveFlagPath()` currently targets — rather than deleted. `hooks/peer-agent-parse.js`'s `{action: 'clear'}` and `hooks/peer-agent-config.js`'s `clearFlag()` collapse into the same `{action: 'set', mode: 'off'}` / `safeWriteFlag(flagPath, 'off')` path already used for the other three modes. `VALID_MODES` in `hooks/peer-agent-config.js` includes `'off'` as a legal stored, whitelisted value.

Decision 6's three-tier read precedence (repo → global → built-in default) is unchanged — only what a repo-scoped `off` *means* changes: it now always wins locally, exactly like a repo-scoped `lite`/`full`/`max` already did.

As a one-time cleanup alongside this fix, the stale global flag found during debugging (`~/.claude/.peer-agent-active`, containing `max`, untraceable provenance, mtime predating the session that surfaced this bug) is cleared. This is incidental hygiene, not part of the design change.

## Consequences

**Positive:**
- `/peer-agent off` now behaves the way every user will assume it does: off until explicitly changed again, regardless of what any other scope's flag says.
- All four mode values (`off`/`lite`/`full`/`max`) now go through one write path instead of two (set vs. delete), removing an asymmetry that was easy to miss and hard to debug.

**Negative:**
- Removes the previously-implicit ability to "clear my local override and revert to whatever the global default is" as an operation distinct from setting a value. There is no longer a way to say "inherit from global" at repo scope once a repo-scoped flag exists — every explicit `/peer-agent <mode>` command, including `off`, now sets a durable local value that must be explicitly changed to move off of.
- Existing installations with a repo-scoped flag *absent* (meaning "inherit" under the old model) keep inheriting until the first `/peer-agent <mode>` command in that repo — no migration needed, since absence was never distinguishable from "explicitly not set" in the old model either.
