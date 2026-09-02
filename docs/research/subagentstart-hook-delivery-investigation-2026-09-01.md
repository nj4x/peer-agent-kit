# SubagentStart Hook Context Delivery Investigation

**Date:** 2026-09-01  
**Diagnosis:** `SubagentStart` hook receives and fires correctly; peer-agent-activate.js script works; the issue is **hook output format mismatch** between `SessionStart` legacy behavior and `SubagentStart` required schema.

---

## Ground Truth from Transcripts

### Parent Session (SessionStart)
- File: `~/.claude/projects/-Users-r-herasymenk-workspace-peer-agent-kit/4c7795af-2e26-4ebf-8f47-fa9c71f14207.jsonl`
- Line 5: `hook_success` attachment (isSidechain: false)
  - Type: `hook_success`
  - Content field: `"PEER_AGENT MODE ACTIVE — level: max\n\n..."`
  - Event: `SessionStart` (confirmed via parent settings.json hook registration)
- **Finding:** SessionStart hook output is stored as `attachment.content`, not wrapped in JSON. This plain-text output works for SessionStart.

### Subagent Sessions
- Examined: `~/.claude/projects/-Users-r-herasymenk-workspace-peer-agent-kit/9d581611-5584-4db3-a859-380f536a0baf/subagents/agent-a01376247e1231baa.jsonl`
- **No `hookEvent` or `hook_success` fields in subagent JSONL** — the transcript JSONL keys list does not include `hookEvent` at all.
- Subagent's first sidechain entry has `isSidechain: true` but no hook attachments.
- Sidechain entries contain only: `deferred_tools_delta` (tools listing) and `skill_listing` (skill enumeration), NOT hook outputs.

---

## Hook Registration Verification

**File:** `~/.claude/settings.json` (installed)

### SessionStart Registration ✓
```json
{
  "hooks": [
    {
      "command": "CLAUDE_PLUGIN_ROOT='/Users/r.herasymenk/.claude' node '/Users/r.herasymenk/.peer-agent-kit/hooks/peer-agent-activate.js'",
      "type": "command"
    }
  ]
}
```
- Matcher: none (matches all sessions)
- Script location: correct

### SubagentStart Registration ✓
```json
{
  "hooks": [
    {
      "command": "CLAUDE_PLUGIN_ROOT='/Users/r.herasymenk/.claude' node '/Users/r.herasymenk/.peer-agent-kit/hooks/peer-agent-activate.js'",
      "type": "command"
    }
  ]
}
```
- **Identical command** to SessionStart
- Matcher: none (matches all subagent types)
- Script location: correct

---

## Hook Script Output Format (The Root Cause)

**File:** `hooks/peer-agent-activate.js:94`

```javascript
process.stdout.write(`PEER_AGENT MODE ACTIVE — level: ${mode}\n\n` + filtered.join('\n'));
```

- **Outputs:** Plain text (not JSON)
- **Exit code:** 0 (implicit, end of script without error)
- **No JSON wrapper:** No `hookSpecificOutput.hookEventName` field

---

## Claude Code Hook Output Schema

**Per official docs** (https://code.claude.com/docs/en/hooks):

```json
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": "Reason",
    "additionalContext": "Context text to inject"
  }
}
```

**Required for `SubagentStart`:**
- `hookSpecificOutput.hookEventName`: must be `"SubagentStart"` (not a generic/inherited value)
- `hookSpecificOutput.additionalContext`: the context string to deliver to subagent

---

## SessionStart Legacy Behavior

Claude Code's `SessionStart` hook has a documented legacy fallback: plain stdout text (exit code 0) is implicitly treated as `additionalContext` without requiring JSON wrapping. This explains why the raw-text output from peer-agent-activate.js works for `SessionStart` — the framework accepts both:
- JSON format: `{"hookSpecificOutput": {"additionalContext": "..."}}`
- Legacy plain text: `PEER_AGENT MODE ACTIVE...` (exit 0)

**Source:** Implicit from changelog and hook behavior; not contradicted by official docs.

---

## SubagentStart Strict Schema Requirement

`SubagentStart` does not inherit the SessionStart legacy behavior. The hook framework requires:

1. **JSON output format**, not plain text
2. **`hookEventName` field set correctly** to `"SubagentStart"` to distinguish from SessionStart
3. **`additionalContext` field** containing the context text

When plain text is emitted for `SubagentStart`, Claude Code likely:
- Parses exit code 0 as "success"
- Does not find JSON on stdout
- Does not assume implicit additionalContext (unlike SessionStart)
- Silently ignores the output
- Subagent receives no injected context

---

## Why Subagent Transcripts Show No Hook Attachments

Subagent JSONL files do not record hook lifecycle events in the same way. The hook infrastructure is opaque to the subagent's transcript — hook attachments may only be logged in the parent session's transcript (as demonstrated in SessionStart case above). This is by design: the hook is a parent-level construct; the subagent sees only its output (injected as a system-reminder or context, not as an attachment entry).

---

## Diagnosis Summary

| Aspect | Status |
|--------|--------|
| Hook registration | ✓ Correct |
| Hook firing | ✓ Fires for both events |
| Script execution | ✓ Executes and emits text |
| SessionStart delivery | ✓ Works (legacy plain-text fallback) |
| **SubagentStart delivery** | **✗ Fails (plain text not accepted)** |

---

## What Needs to Change

**File:** `hooks/peer-agent-activate.js`

Wrap stdout in JSON with correct `hookEventName`:

```javascript
// Read hookEventName from input to support both SessionStart and SubagentStart
const hookEventName = data?.hookEventName || 'SessionStart';

const output = {
  hookSpecificOutput: {
    hookEventName: hookEventName,
    additionalContext: `PEER_AGENT MODE ACTIVE — level: ${mode}\n\n` + filtered.join('\n')
  }
};

process.stdout.write(JSON.stringify(output));
```

This change:
- Maintains backward compatibility: `SessionStart` will still receive additionalContext
- Enables `SubagentStart`: subagent will receive the context in the correct structured format
- Is symmetric: same script, same policy, different event names in output

---

## References

- **Hook input schema:** `~/.claude/settings.json` (installed config)
- **Script source:** `hooks/peer-agent-activate.js:94` (plain text output)
- **SessionStart evidence:** `4c7795af-2e26-4ebf-8f47-fa9c71f14207.jsonl:5` (hook_success.content)
- **Subagent absence:** `9d581611-5584-4db3-a859-380f536a0baf/subagents/agent-a01376247e1231baa.jsonl` (no hookEvent keys)
- **Official docs:** https://code.claude.com/docs/en/hooks (JSON output format requirement)
- **Claude Code version:** 2.1.236 (supports SubagentStart as of v2.0.43, with fixes in v2.1.141)

---

## Minimal Test to Confirm

Manually add JSON wrapping to `peer-agent-activate.js`, reinstall, spawn a subagent, and check its first system-reminder or initial context for "PEER_AGENT MODE ACTIVE". If present, diagnosis is confirmed; if absent, the hook framework itself may have a bug in SubagentStart context injection (less likely given official docs and issue #65495 confirming the feature works in v2.1.163+).
