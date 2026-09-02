# Cross-Kit Parity Research: SubagentStart Hook Registration

**Research Date:** 2026-09-01  
**Question:** Does caveman-kit have SubagentStart hook registration for mode injection to subagents?  
**Status:** Complete

---

## Executive Summary

**caveman-kit is missing SubagentStart hook registration.**

peer-agent-kit registers its activation script under both SessionStart (parent session) and SubagentStart (subagent spawn) to ensure subagents receive identical mode ruleset injection. caveman-kit currently registers only under SessionStart and UserPromptSubmit, leaving subagents without caveman mode rules.

The fix is straightforward and safe: add 3 lines to caveman-kit's `lib/settings-patch.js` and 1 line to `lib/settings-unpatch.js` to register caveman-activate.js under SubagentStart using the existing marker-based installer machinery.

---

## Inventory: Hook Events by Repository

### peer-agent-kit (v3e19e18 — current main)

**Registered hook events:**

| Event | Script | File | Lines |
|-------|--------|------|-------|
| SessionStart | peer-agent-activate.js | lib/settings-patch.js | 36 |
| SubagentStart | peer-agent-activate.js | lib/settings-patch.js | 38 |
| UserPromptSubmit | peer-agent-mode-tracker.js | lib/settings-patch.js | 37 |

**Unpatch logic:**

- `lib/settings-unpatch.js:58` removes SubagentStart entries by marker
- Single marker couples SessionStart + SubagentStart removal symmetrically

**Installer comments:**

- `install.sh:5` — docs header mentions "SessionStart, SubagentStart, UserPromptSubmit"
- `uninstall.sh:6` — docs header mentions both hooks for peer-agent-activate.js

---

### caveman-kit (current main)

**Registered hook events:**

| Event | Script | File | Lines |
|-------|--------|------|-------|
| SessionStart | caveman-activate.js | lib/settings-patch.js | 36 |
| UserPromptSubmit | caveman-mode-tracker.js | lib/settings-patch.js | 37 |

**Unpatch logic:**

- `lib/settings-unpatch.js:57` removes only SessionStart and UserPromptSubmit
- **No SubagentStart removal** (no corresponding unpatch line)

**Installer comments:**

- `install.sh:5` — docs header says "injects (SessionStart, UserPromptSubmit)" only
- `README.md:6` — says "inject two hook entries (SessionStart, UserPromptSubmit)"
- No mention of SubagentStart anywhere in caveman-kit

---

## Structural Delta

### settings-patch.js Diff

**peer-agent-kit** (`lib/settings-patch.js:38`):
```javascript
const addedSubagent = inject('SubagentStart', activateCmd, 'peer-agent-activate.js');
```

**caveman-kit** — missing this line entirely.

**Console output comparison:**

peer-agent-kit prints 3 lines:
```
SessionStart hook: added
SubagentStart hook: added
UserPromptSubmit hook: added
```

caveman-kit prints 2 lines:
```
SessionStart hook: added
UserPromptSubmit hook: added
```

### settings-unpatch.js Diff

**peer-agent-kit** (`lib/settings-unpatch.js:58`):
```javascript
const removedSubagent = removeHooks('SubagentStart', ACTIVATE_MARKER);
```

**caveman-kit** — missing this line entirely.

**Console output comparison:**

peer-agent-kit:
```
SessionStart hook: removed X entry(s)
SubagentStart hook: removed Y entry(s)
UserPromptSubmit hook: removed Z entry(s)
```

caveman-kit:
```
SessionStart hook: removed X entry(s)
UserPromptSubmit hook: removed Z entry(s)
```

---

## Hook Script Compatibility

**Key finding:** Neither activate script checks which event fired (SessionStart vs SubagentStart). Both scripts are **event-agnostic** from the perspective of the hook input.

**peer-agent-activate.js** (lines 1–2, 14–23):
```javascript
// peer-agent-kit — SessionStart hook.
// ...
let cwd = null;
try {
  if (!process.stdin.isTTY) {
    const raw = fs.readFileSync(0, 'utf8');
    if (raw) {
      const data = JSON.parse(raw);
      if (data && typeof data.cwd === 'string') cwd = data.cwd;
```

**caveman-activate.js** (identical lines 1–2, 14–23):
```javascript
// caveman-kit — SessionStart hook.
// ...
let cwd = null;
try {
  if (!process.stdin.isTTY) {
    const raw = fs.readFileSync(0, 'utf8');
    if (raw) {
      const data = JSON.parse(raw);
      if (data && typeof data.cwd === 'string') cwd = data.cwd;
```

Both scripts read `cwd` from stdin JSON (a field present in both SessionStart and SubagentStart hook input — see Claude Code docs below), resolve the flag file, and inject the ruleset. Neither script branches on `hook_event_name`, so **both activate scripts will work identically for SubagentStart without modification.**

---

## Official Claude Code Hook Documentation

**Source:** https://code.claude.com/docs/en/hooks.md#subagentstart

**SubagentStart event contract:**

- **Definition:** Fires when a subagent is spawned, once per subagent creation in the agentic loop
- **Input JSON:** Receives `session_id`, `prompt_id`, `transcript_path`, `cwd`, `hook_event_name` ("SubagentStart"), `agent_id`, `agent_type`
- **Output format:** Standard decision model, accepts `hookSpecificOutput` with `additionalContext` field (same as SessionStart and UserPromptSubmit)
- **Timeout:** 5000ms async
- **Blocking:** Not listed in the "exit 2 blocks" table — cannot veto subagent creation, only inform via additionalContext

**Verification:** SubagentStart is a real, supported hook event as of Claude Code v2.0.43 (changelog), with fixes in v2.1.141. Both kits' activate scripts emit hook output in the correct format (JSON with `hookSpecificOutput` field containing `additionalContext`).

---

## ADR-0079 Context (peer-agent-kit)

**From** `/Users/r.herasymenk/workspace/peer-agent-kit/docs/adr/0079-peer-agent-delegation-trigger.md`:

> **Research findings** (finding #5): "Subagents run in separate sessions and need explicit injection. Research (#23) confirmed subagents spawn as fresh sessions (separate JSONL files). SessionStart hook runs in the parent session only, so subagents never receive injected policy. Issue #24 decided: subagents should receive identical injection via the SubagentStart hook, which Claude Code added in v2.0.43 and fixed in v2.1.141."

> **Decision**: "Unified injection approach: SessionStart + SubagentStart, no explicit opt-in layer. Subagents receive identical mode policy injection at SubagentStart."

> **Implementation** (finding #69): "Issue #24: Subagent mode inheritance via SubagentStart hook (closed, implemented)."

This was the rationale for peer-agent-kit's SubagentStart registration in commit 3e19e18.

---

## Should caveman-kit Have It?

**Yes, for consistency and functional correctness.**

**Rationale:**

1. **Mode persistence across delegation:** Caveman mode is a response-style ruleset (instruction to compress output, drop filler). Like peer-agent mode, it should apply consistently to subagents spawned during a session.

2. **Subagent as separate session:** By the same research (#23) that motivated peer-agent-kit's SubagentStart, subagents run as separate Claude Code sessions with their own JSONL transcripts. They do not inherit SessionStart hooks from the parent. Without SubagentStart registration, a subagent will spawn with no caveman mode rules injected, even if the parent session had explicitly set `/caveman full`.

3. **User expectation:** If a user sets `/caveman full` (repo-scoped or global) and then delegates work to a subagent, they would expect the subagent's output to also follow caveman style (compressed, no filler). Injecting identical mode rules at SubagentStart satisfies that expectation.

4. **No breaking changes:** The caveman-activate.js script already works with SubagentStart input (reads cwd, resolves flag, emits ruleset). Adding the hook registration in the installer requires only ~3 lines of code and does not modify the hook script itself.

5. **Symmetry with peer-agent-kit:** Both kits use identical installer machinery (marker-based patch/unpatch). Keeping them in parity reduces cognitive load and makes future cross-kit maintenance easier.

---

## Concrete Changes Required

### caveman-kit: lib/settings-patch.js

**After line 37, add:**

```javascript
const addedSubagent = inject('SubagentStart', activateCmd, 'caveman-activate.js');
```

**After line 42, add console output:**

```javascript
console.log(`SubagentStart hook: ${addedSubagent ? 'added' : 'already present'}`);
```

(Reorder console logs: SessionStart, SubagentStart, UserPromptSubmit for consistency with peer-agent-kit.)

### caveman-kit: lib/settings-unpatch.js

**After line 57, add:**

```javascript
const removedSubagent = removeHooks('SubagentStart', ACTIVATE_MARKER);
```

**After line 68, add console output:**

```javascript
console.log(`SubagentStart hook: removed ${removedSubagent} entry(s)`);
```

### caveman-kit: install.sh

**Line 5:** Update docstring from "SessionStart, UserPromptSubmit" to "SessionStart, SubagentStart, UserPromptSubmit"

### caveman-kit: uninstall.sh

**Line 4:** Update docstring to mention both SessionStart and SubagentStart under peer-agent-activate.js removal

### caveman-kit: README.md

**Line 6:** Update from "SessionStart, UserPromptSubmit" to "SessionStart, SubagentStart, UserPromptSubmit"

---

## Files Verified

| Path | Purpose | Finding |
|------|---------|---------|
| /Users/r.herasymenk/workspace/peer-agent-kit/lib/settings-patch.js | Inject hooks | SubagentStart: ✓ present (line 38) |
| /Users/r.herasymenk/workspace/peer-agent-kit/lib/settings-unpatch.js | Remove hooks | SubagentStart: ✓ present (line 58) |
| /Users/r.herasymenk/workspace/caveman-kit/lib/settings-patch.js | Inject hooks | SubagentStart: ✗ missing |
| /Users/r.herasymenk/workspace/caveman-kit/lib/settings-unpatch.js | Remove hooks | SubagentStart: ✗ missing |
| /Users/r.herasymenk/workspace/peer-agent-kit/hooks/peer-agent-activate.js | Hook script | Event-agnostic; works for both SessionStart and SubagentStart |
| /Users/r.herasymenk/workspace/caveman-kit/hooks/caveman-activate.js | Hook script | Event-agnostic; works for both SessionStart and SubagentStart |
| /Users/r.herasymenk/workspace/peer-agent-kit/docs/adr/0079-peer-agent-delegation-trigger.md | Decision record | SubagentStart registration justified and implemented |

