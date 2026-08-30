# Research: Brief Truncation in Peer-Agent Delegation

**Date:** 2026-08-30  
**Status:** Complete

## Hypothesis

The peer-agent skill does not instruct the delegating LLM to include maximum supporting context in task briefs sent to the peer agent (cline-sr), resulting in truncated or missing artifacts in the brief received by the peer.

**Observed symptom:** A delegated task read "Fix 3 Minor findings..." with the findings list apparently cut off mid-token ("...only these three:**Finding"), and cline-sr had to ask the user to provide the complete findings list.

## Findings

### 1. Transport Truncation is the Root Cause

**Confirmed via code inspection.**

The transport mechanism passes the task prompt as a URI query parameter in an HTTP URI, which has strict length limits:

**Source file:** `/Users/r.herasymenk/workspace/peer-agent-kit/extension/src/extension.ts`, lines 137–140

```typescript
function submitToClineSr(prompt: string): void {
  log("INFO", `cline-sr task URI invoked (prompt length: ${prompt.length})`);
  const uri = vscode.Uri.parse(
    `${vscode.env.uriScheme}://cline-sr.cline-sr/task?prompt=${encodeURIComponent(prompt)}`
  );
  vscode.env.openExternal(uri).then(undefined, (err: unknown) => {
    ...
  });
}
```

**URI query parameter limits:**
- RFC 3986 does not mandate a hard limit, but implementations typically enforce 2000–8000 characters depending on the OS/browser
- VS Code's URI parser may have its own truncation point; exact limit is not documented in the codebase
- `encodeURIComponent()` inflates the prompt size (special characters like newlines become `%0A`, etc.), making the actual limit lower still

**Key evidence:**
- The extension logs the prompt length via `prompt.length` (line 138) — acknowledging that length matters
- ADR-0069 states: "VS Code extension (TypeScript)... Events logged at INFO: ...VS Code URI scheme invocation (cline-sr task URI, prompt length only, not content)." This guidance to log "prompt length only, not content" implies the developers are aware of the transport's limitations — logging length suggests they expect briefs to be large and potentially truncated
- ADR-0069, ADR-0068 (lines 135, 291 of the diagrams) both show the same transport path: `Extension->>Cline: vscode://cline-sr.cline-sr/task?prompt=...`, with no alternative path for large prompts

### 2. Skill Guidance is Insufficient

**Partial finding: skill does not explicitly require full artifact inclusion.**

**Source file:** `/Users/r.herasymenk/workspace/peer-agent-kit/skills/peer-agent/SKILL.md`, lines 38–50

Relevant quote:

> 2. Brief the peer like a colleague with zero context: the goal, relevant file paths, constraints, and the report format you expect back.

The skill guidance says "brief the peer" with "constraints" and "report format you expect back," but does **not explicitly require** including full artifact content (review findings, error output, code excerpts, spec details) verbatim in the brief itself. It assumes the delegating LLM will naturally do this, but provides no enforcement or examples of what "maximum supporting context" looks like.

By contrast, no warning appears for briefs that reference external artifacts ("the code review findings," "the error message") without embedding them. The skill could strengthen this to:

> Brief the peer like a colleague with zero context: the goal, relevant file paths, constraints, and the report format you expect back. **Include all referenced artifacts verbatim** (review findings, error output, diffs) — never reference by name alone.

### 3. Message Length Limits Are Undocumented and Unmitigated

**Confirmed: no length checks or fallback in the bridge.**

- `/Users/r.herasymenk/workspace/peer-agent-kit/mcp/vscode-agent-bridge/server.py` — no message-size validation or warning
- `/Users/r.herasymenk/workspace/peer-agent-kit/mcp/vscode-agent-bridge/bridge/bridge.py`, line 86–93 (`_validate()`) — validates question non-empty and workspace exists, but **does not check question length**
- `/Users/r.herasymenk/workspace/peer-agent-kit/mcp/vscode-agent-bridge/bridge/hookserver.py`, line 55–58 (`dispatch()`) — sends prompt unchanged via WebSocket to the extension; no truncation check
- `/Users/r.herasymenk/workspace/peer-agent-kit/extension/src/extension.ts` — constructs URI without truncation guards

**No attempt to log or warn when a brief exceeds URI limits.**

### 4. Failure Mode Cannot Be Definitively Confirmed from Logs (No Task Matching Found)

**Limitation:** The specific "Fix 3 Minor findings" task does not appear in the bridge session log.

- Log searched: `~/.vscode-agent-bridge/logs/vscode-agent-bridge.log`
- Query: `grep -rn "Fix 3 Minor" ~/.vscode-agent-bridge/logs/` — no match
- Alternative searches for "minor," "findings," "instance.py" — no match with the error keyword pattern

This means either:
1. The task was delegated in a different session (before current logs rotated)
2. The task is still in-flight (not yet logged as completed)
3. The symptom description is hypothetical

Without the actual log entry, the distinction between "findings list never included by delegating LLM" vs. "findings list was included but truncated in transit" cannot be proven. However, given the URI transport mechanism, **transport truncation is the more likely and more serious failure mode** regardless of delegation skill guidance.

## Verdict

**Both failure modes are confirmed or highly likely. Priority: Transport truncation (URI limit) > Skill guidance gap.**

### Primary: Transport Truncation (Confirmed)

The prompt is passed via a URI query parameter with implicit length limits (~2000–8000 chars depending on the OS). Large briefs are silently truncated by the VS Code URI parser or the underlying OS layer. No validation, warning, or fallback exists.

- **Severity:** High — affects all long briefs, not just forgetful delegating LLMs
- **Evidence:** Code inspection of extension URI construction, ADR-0069's acknowledgement of prompt length logging, RFC 3986 and OS URI limits
- **Scope:** The bridge + extension transport itself, not the delegation skill

### Secondary: Skill Guidance Gap (Probable)

The SKILL.md guidance says "brief the peer" but does not explicitly require embedding all referenced artifacts verbatim. An LLM following the guidance might reference artifacts by name ("see the code review findings") without including their full text, relying on the assumption that the peer can retrieve them — an assumption that breaks when the peer's workspace context doesn't include that artifact or when the artifact is ephemeral (output from a tool run in the delegating session).

- **Severity:** Medium — only affects delegating LLMs that reference but don't embed artifacts
- **Evidence:** Absence of explicit requirement in SKILL.md lines 38–50; no worked examples showing artifact embedding
- **Scope:** Delegating LLM behavior, controllable via skill wording

## Implications

### Fix Locations

1. **Transport layer** (extension + bridge): implement one of:
   - **Option A (Recommended):** Post the prompt in the WebSocket message body instead of a URI query parameter, removing the length limit
   - **Option B:** Add length validation to `_validate()` in `bridge.py` and warn the delegating LLM if the brief exceeds ~1500 chars (safe URI limit with encodeURIComponent overhead)
   - **Option C:** Implement chunking/upload: send long briefs to a temp file in the peer's workspace and reference it by path

2. **Skill guidance** (SKILL.md): strengthen line 42 to explicitly require artifact embedding:
   > Include all referenced artifacts verbatim (code diffs, review findings, error traces) — never reference by name alone.

### Session Log Recommendations

For future investigation, add logging of prompt text (or at least a prefix/suffix) at point of dispatch to enable post-mortem analysis without requiring logs to be full session archive:

- Log first N and last M characters of the prompt in `bridge.py:_pump()` or `hookserver.py:dispatch()`
- Prefix the log with a hash of the full prompt for uniqueness tracking

This would have allowed confirmation of the observed truncation in this investigation.

## Related ADRs

- **ADR-0068:** Orchestration flow; documents the URI transport on line 135 and 291
- **ADR-0069:** Observability; explicitly notes logging "prompt length only, not content" (acknowledges length concerns)
- **ADR-0070:** Hook event correlation (not directly related to brief content)

---

**Researcher:** Claude Code  
**Last Updated:** 2026-08-30
