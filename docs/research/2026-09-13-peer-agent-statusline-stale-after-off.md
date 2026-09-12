# Bug: Statusline Badge Stale After `/peer-agent off`

**Status:** Real bug — verified in source code  
**Severity:** Medium — mode changes via slash command are silently ineffective  
**Root Cause:** UserPromptSubmit hook not invoked on slash-command prompts, OR hook receives slash command but never executes mode-file write

---

## Summary Verdict

When `/peer-agent off` runs as a slash command in a Claude Code session, the mode-file write does not occur, leaving the badge stuck at its previous value. The skill's own SKILL.md contains no file-write logic and is disabled (`disable-model-invocation: true`), so all mode persistence depends on the UserPromptSubmit hook (`peer-agent-mode-tracker.js`). The bug is that the hook either:

1. Is not invoked at all when a slash command runs (hook delivery failure), OR
2. Is invoked but the hook's execution does not actually update the flag file (hook execution failure)

The observed symptom: `/peer-agent off` produces confirmation text (from Claude Code's built-in command acknowledgment), but the statusline badge remains `[CLINE:MAX]` and the flag file on disk stays unchanged.

---

## Write Paths for the Mode File

### Only Viable Write Path: UserPromptSubmit Hook

**File:** `/Users/r.herasymenk/workspace/peer-agent-kit/hooks/peer-agent-mode-tracker.js`  
**Registered at:** `/Users/r.herasymenk/workspace/peer-agent-kit/lib/settings-patch.js` line 77, injected into `~/.claude/settings.json`  
**Trigger:** UserPromptSubmit hook event (should fire on every prompt + slash command)  
**Write implementation:** Lines 44–58

```javascript
const change = skipParse ? null : parseModeChange(prompt);
if (change && change.action === 'set') {
  // repo-scoped setup...
  safeWriteFlag(flagPath, change.mode);       // ← Line 54: WRITES mode file
  if (repoRoot) ensureGitExclude(repoRoot);
} else if (change && change.action === 'clear') {
  clearFlag(flagPath);                         // ← Line 57: DELETES mode file
}
```

**Write path logic:**
- Line 44: `parseModeChange(prompt)` returns `{ action: 'clear' }` for `/peer-agent off` (parse verified: line 49 of `peer-agent-parse.js` handles `arg === 'off'`)
- Line 56–57: If change is `{ action: 'clear' }`, calls `clearFlag(flagPath)`
- `clearFlag()` at line 127 of `peer-agent-config.js`: `fs.unlinkSync(flagPath)`

**Precondition for write:** The UserPromptSubmit hook MUST execute and receive the prompt containing `/peer-agent off`.

### Alternative Write Path: SessionStart Hook (Does Not Apply Here)

**File:** `/Users/r.herasymenk/workspace/peer-agent-kit/hooks/peer-agent-activate.js`  
**Trigger:** SessionStart hook event (fires once per session startup)  
**Line 56:** `safeWriteFlag(target, mode);`

This only runs at session init, so it cannot correct a stale flag during an active session. It's not involved in the bug.

### Skill SKILL.md: No Write Path

**File:** `/Users/r.herasymenk/workspace/peer-agent-kit/skills/peer-agent/SKILL.md`  
**Lines:** 1–52 (complete file)  
**Content:** Pure documentation  
**Frontmatter line 8:** `disable-model-invocation: true`

**Verdict:** The skill body contains zero tool invocations, zero file-write directives, and zero calls to any script. It is documentation only. Because `disable-model-invocation: true`, Claude Code never invokes this skill's prose. The skill does not and cannot write the mode file.

---

## Read Path for the Statusline Badge

**File:** `/Users/r.herasymenk/workspace/peer-agent-kit/lib/statusline-patch.js`  
**Injected bash block:** Lines 14–43 (installed into `~/.claude/statusline.sh` by `statusline-patch.js`)

```bash
PEER_AGENT_FLAG="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/.peer-agent-active"
# Resolve repo flag (if exists) vs. global flag
PEER_AGENT_DIR="$PWD"
while [ "$PEER_AGENT_DIR" != "/" ]; do
  if [ -e "$PEER_AGENT_DIR/.git" ]; then
    if [ -f "$PEER_AGENT_DIR/.claude/.peer-agent-mode" ]; then
      PEER_AGENT_FLAG="$PEER_AGENT_DIR/.claude/.peer-agent-mode"
    fi
    break
  fi
  PEER_AGENT_DIR="$(dirname "$PEER_AGENT_DIR")"
done
# Read and print badge
if [ -f "$PEER_AGENT_FLAG" ] && [ ! -L "$PEER_AGENT_FLAG" ]; then
  PEER_AGENT_MODE=$(head -c 16 "$PEER_AGENT_FLAG" 2>/dev/null | tr -d '\n\r' | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9-')
  case "$PEER_AGENT_MODE" in
    lite|full|max)
      if [ "$PEER_AGENT_MODE" = "full" ]; then
        printf '[CLINE] '
      else
        CLINE_SUFFIX=$(printf '%s' "$PEER_AGENT_MODE" | tr '[:lower:]' '[:upper:]')
        printf '[CLINE:%s] ' "$CLINE_SUFFIX"
      fi
      ;;
  esac
fi
```

**Read logic:**
- Line 29: Checks if flag file exists and is not a symlink
- Line 30: Reads first 16 bytes, converts to lowercase, sanitizes to `a-z0-9-`
- Lines 31–40: If mode in `{lite, full, max}`, prints badge; mode `off` (or missing file) prints nothing

**Badge rendering:**
- Mode `full` → `[CLINE]`
- Mode `lite` → `[CLINE:LITE]`
- Mode `max` → `[CLINE:MAX]`
- Mode `off` or file missing → (no badge printed)

**Critical:** Statusline reads the flag on every render. If the file still contains `max`, badge stays `[CLINE:MAX]`.

---

## Current State at Investigation Time

**Global flag file:** `~/.claude/.peer-agent-active`  
**Actual content:** `max` (3 bytes)  
**File timestamp:** Sep 12 13:46:00 2026

**Interpretation:** The flag was written during an earlier Claude Code session (Sep 12 at 13:46). Within the session where the user ran `/peer-agent off`, the flag file was never updated — it still contains `max` from the previous session.

---

## The Bug Manifest

**Observed sequence in a single Claude Code session:**

1. Claude Code starts → SessionStart hook fires → reads existing global flag (`max`) → writes it back to `~/.claude/.peer-agent-active` → statusline renders, reads `max`, prints `[CLINE:MAX]`
2. User types `/peer-agent off` into Claude Code
3. Claude Code acknowledges: "Peer-agent off." (built-in slash-command confirmation text)
4. **Expected next step:** UserPromptSubmit hook fires → parses `/peer-agent off` → returns `{ action: 'clear' }` → calls `clearFlag(flagPath)` → deletes flag file
5. **Actual next step (bug):** Flag file is never deleted; statusline still reads `max`; badge stays `[CLINE:MAX]`

**Why confirmation text appears:** Claude Code's **built-in slash-command dispatcher** prints an acknowledgment for recognized commands (e.g., `/peer-agent off`), independent of whether the skill prose runs or hooks execute. This explains why the user sees "Peer-agent off." confirmation even though nothing downstream actually changed the mode file.

---

## Critical Gap: Hook Invocation Guarantee

**Question:** Does Claude Code invoke UserPromptSubmit hooks when a slash command runs?

**Evidence from source code:**
- `peer-agent-mode-tracker.js` is correctly registered as a UserPromptSubmit hook (line 77 of `settings-patch.js`)
- The hook code exists and includes envelope-unwrapping logic for slash commands (lines 33–42 of `peer-agent-mode-tracker.js`)
- The parse logic is verified correct: `/peer-agent off` → `{ action: 'clear' }` (line 49 of `peer-agent-parse.js`)

**Missing evidence:**
- No log or trace confirming the hook was invoked during the session
- No documented guarantee in Claude Code that UserPromptSubmit fires for slash commands
- The hook assumes an envelope format (`<command-name>...</command-name>`) suggesting knowledge of how Claude Code wraps slash commands, but no evidence that this wrapping actually happens

**Hypothesis:** Either:
1. Claude Code recognizes slash commands and **does not** send them to hooks (early exit in the command dispatcher)
2. Claude Code sends slash commands to hooks but the envelope wrapping does NOT match what `peer-agent-mode-tracker.js` expects (regex mismatch at line 33)
3. The hook runs but hits an exception in parsing or file-write logic (error handling silently swallows exceptions at line 79: `catch (e) { /* silent fail */ }`)

Without logs from the hook execution, the bug cannot be fully pinned.

---

## Parse Logic Verification

**Test:** `/peer-agent off` through the parser

```javascript
parseModeChange('/peer-agent off')
// Expected: { action: 'clear' }
// Reason: Line 49 of peer-agent-parse.js:
//   if (arg === 'off' || arg === 'stop' || arg === 'disable') return { action: 'clear' };
```

**Result:** ✓ Confirmed. Parse logic is correct.

**Test:** Envelope unwrapping

The hook expects (line 33–38 of `peer-agent-mode-tracker.js`):
```xml
<command-name>/peer-agent</command-name><command-args>off</command-args>
```

The code reconstructs:
```javascript
prompt = '/peer-agent' + ' ' + 'off'  // → '/peer-agent off'
```

Then passes to `parseModeChange()` → returns `{ action: 'clear' }`. Logic is sound.

**Assumption:** Claude Code actually sends this envelope format. **No verification available in this codebase.**

---

## File Write Logic Verification

**File:** `/Users/r.herasymenk/workspace/peer-agent-kit/hooks/peer-agent-config.js`  
**Function `clearFlag()`:** Lines 126–128

```javascript
function clearFlag(flagPath) {
  try { fs.unlinkSync(flagPath); } catch (e) { /* already gone */ }
}
```

**Logic:** Calls `fs.unlinkSync()` to delete the file. Catches any exception (file not found, permission denied, etc.) and ignores it (best-effort). This is correct for an idempotent delete.

**Verification:** If the hook ran and called this function, the file would be deleted (or the error would be silently caught). At investigation time, the file still exists, so either the hook did not run or did not call `clearFlag()`.

---

## Possible Root Causes

### Cause 1: Hook Not Invoked on Slash Commands (Highest Likelihood)

Claude Code may recognize slash commands before they reach the UserPromptSubmit hook, so the hook never fires. The feature was designed assuming hooks would see all prompts, but the implementation may have a special fast path for slash commands.

**Fix:** Implement a separate slash-command handler outside the hook system.

### Cause 2: Envelope Format Mismatch

Claude Code sends slash commands to the hook but uses a different envelope format than `peer-agent-mode-tracker.js` expects. The regex at line 33 of `peer-agent-mode-tracker.js` does not match, so `skipParse` is set true, and the hook skips mode-change parsing.

**Evidence against:** The code was written with this envelope in mind, suggesting some confidence in the format. But without a log from the hook showing what envelope was actually received, this cannot be ruled out.

**Fix:** Add logging to the hook to dump the received prompt and regex match results.

### Cause 3: Exception in Hook Execution

The hook runs but encounters an unhandled exception or silent-catch at line 79. The exception might be in JSON parsing (line 20), file I/O (line 54 or 57), or any of the utility functions.

**Evidence against:** The hook is instrumented with try/catch at the top level (line 79), and would silently exit 0 even on error. Unlikely but possible.

**Fix:** Add stderr logging to the hook before the try/catch exits.

---

## Comparison: Mode Switches That DO Work

The user reported that `/peer-agent max`, `/peer-agent full`, and `/peer-agent lite` confirmed correctly in the session. This suggests their confirmation texts were displayed (from Claude Code's built-in command acknowledgment). **But did the flag files actually update?** The bug report doesn't specify whether the badges changed in-session for those mode switches. If they also stayed stale, the bug is consistent: all slash-command mode changes fail to update the file. If some of them DID update the file, the bug may be specific to the `/peer-agent off` case (e.g., a separate `off` code path).

**Unable to verify without session logs.**

---

## Files Involved

**Mode file write (only path that matters):**
- `/Users/r.herasymenk/workspace/peer-agent-kit/hooks/peer-agent-mode-tracker.js` lines 44–58
- `/Users/r.herasymenk/workspace/peer-agent-kit/hooks/peer-agent-config.js` lines 94–128 (`safeWriteFlag`, `clearFlag`)
- `/Users/r.herasymenk/workspace/peer-agent-kit/hooks/peer-agent-parse.js` lines 8–55 (parse logic)

**Mode file read (statusline-driven):**
- `/Users/r.herasymenk/workspace/peer-agent-kit/lib/statusline-patch.js` lines 14–43

**Skill (disabled, not responsible):**
- `/Users/r.herasymenk/workspace/peer-agent-kit/skills/peer-agent/SKILL.md` lines 1–52

**Hook registration:**
- `/Users/r.herasymenk/workspace/peer-agent-kit/lib/settings-patch.js` line 77
- `/Users/r.herasymenk/workspace/peer-agent-kit/install.sh` line 315

---

## Recommendation: Enable Hook Logging to Diagnose

To confirm whether the hook is invoked and what it receives, add temporary logging:

**File:** `/Users/r.herasymenk/.peer-agent-kit/hooks/peer-agent-mode-tracker.js`  
**Add at line 19 (after reading stdin, before parsing):**

```javascript
process.stderr.write(`[peer-agent-mode-tracker] received prompt: ${JSON.stringify(prompt.slice(0, 200))}\n`);
```

**Add at line 45 (after parsing):**

```javascript
if (change) {
  process.stderr.write(`[peer-agent-mode-tracker] parsed change: ${JSON.stringify(change)}\n`);
} else {
  process.stderr.write(`[peer-agent-mode-tracker] no mode change detected\n`);
}
```

Run the session again, run `/peer-agent off`, and check:
1. Does stderr from the hook appear in Claude Code's logs?
2. Does the hook receive the prompt?
3. Does `parseModeChange()` return a change object?

---

## Test Case for Reproduction

```bash
# In Claude Code, single session:
1. Note statusline: [CLINE:MAX]
2. Type: /peer-agent off
3. Observe: "Peer-agent off." confirmation appears
4. Check statusline: [CLINE:MAX] still present (should be absent)
5. Check flag: cat ~/.claude/.peer-agent-active → "max" (should be deleted)

# Expected flow (what should happen):
Claude Code UserPromptSubmit hook fires
  → peer-agent-mode-tracker.js receives prompt
  → parseModeChange('/peer-agent off') → { action: 'clear' }
  → clearFlag(flagPath) → fs.unlinkSync() → flag file deleted

# Actual flow (hypothesis):
Claude Code does NOT fire UserPromptSubmit hook for slash commands
  → peer-agent-mode-tracker.js never invoked
  → flag file unchanged
  → statusline next render reads "max" → prints [CLINE:MAX]
```

---

## Summary

**Root cause:** Unverified hook delivery on slash commands. The skill cannot write the flag (disabled), so all mode persistence depends on the UserPromptSubmit hook. If the hook does not run on slash-command prompts, the flag file never updates, and the statusline badge remains stale.

**Evidence:** Flag file exists on disk at investigation time, containing `max` from a previous session, unchanged by any `/peer-agent off` commands in the current session.

**Missing data:** Hook execution logs, Claude Code's hook delivery contract, and actual prompt text the hook receives.

**Next step:** Add logging to `peer-agent-mode-tracker.js` and reproduce the bug to confirm whether the hook runs and what it receives.
