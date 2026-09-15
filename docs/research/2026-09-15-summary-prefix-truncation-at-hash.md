---
artifact-type: research
date: 2026-09-15
---

# Research: Summary Prefix Truncation at `#` Character in URI Dispatch

**Investigation Date:** 2026-09-15  
**Task ID:** 030794c9cedb4f2487df246d1a4fc2f6  
**Session:** PID:54328  

## Summary

**Root cause confirmed:** `vscode.Uri.parse()` in the TypeScript extension treats an unencoded `#` character in the URI string as a fragment delimiter BEFORE applying URL decoding, causing everything after the `#` to be stripped from the query parameters. The summary prefix "High-effort code review of PR #697 federation-add-member integration test suite" was truncated to "High-effort code review of PR ", and the brief-file pointer prompt was lost entirely, so cline-sr received an empty `query: {}` in its URI handler.

**Confidence level:** High. The mechanism is confirmed by:
1. Bridge logs showing full 5092-char prompt received and brief file written (ADR-0087 & ADR-0086 active).
2. Extension logs showing 230-char prompt dispatched (the offloaded summary + pointer).
3. Cline-sr logs showing `query: {}` (empty) when processing the URI.
4. The truncation point aligns exactly with the first `#` in the prompt.

**Status:** Bug in the TypeScript extension's URI construction layer. Not a transport or MCP truncation; not a brief-file offload issue. The fix requires URL-encoding the prompt parameter or encoding the `#` before passing to `vscode.Uri.parse()`.

---

## Evidence

### 1. Bridge Received Full Question

**File:** `~/.vscode-agent-bridge/logs/vscode-agent-bridge.log`

```
2026-09-15 14:45:41,850 -07:00 [INFO] [PID:54328] [task_id=] vscode-agent-bridge.server: 
  submit_to_peer_agent: question length raw=5092 chars, encoded=7028 bytes
```

**Location:** `server.py:104-107`, logging added per ADR-0087.

The bridge received the full multi-KB code review brief with no truncation from the MCP layer.

### 2. Brief File Offloaded Successfully

**File:** `~/.vscode-agent-bridge/logs/vscode-agent-bridge.log`

```
2026-09-15 14:45:44,387 -07:00 [INFO] [PID:54328] [task_id=030794c9cedb4f2487df246d1a4fc2f6] 
  vscode-agent-bridge.bridge: task 030794c9cedb4f2487df246d1a4fc2f6: brief offloaded to 
  /Users/r.herasymenk/.vscode-agent-bridge/briefs/brief-030794c9cedb4f2487df246d1a4fc2f6.md 
  (encoded length 7028 bytes, file 5124 bytes)
```

**Location:** `bridge.py:140-143` (_prepare_dispatch_prompt).

The 7028-byte encoded prompt (5092 raw chars) exceeded `ENCODED_BRIEF_THRESHOLD = 850` (per ADR-0087) and was written to a brief file. The bridge then prepared a pointer prompt with the summary prefix:

```
High-effort code review of PR #697 federation-add-member integration test suite. Your full task brief is at `/Users/r.herasymenk/.vscode-agent-bridge/briefs/brief-030794c9cedb4f2487df246d1a4fc2f6.md` — read it first, then proceed.
```

**Character count:** ~230 chars (confirmed at extension dispatch, below).

### 3. Extension Received and Dispatched 230-Char Prompt

**File:** `~/.vscode-agent-bridge/data-54328/logs/20260915T144542/window1/exthost/output_logging_20260915T144543/1-Agent Bridge.log`

```
2026-09-15T21:45:44.389Z [INFO] cline-sr task URI invoked (prompt length: 230)
```

**Location:** `extension/src/extension.ts:138` (log before Uri.parse()).

The extension received a 230-character prompt (the summary prefix + pointer) from the bridge via WebSocket and logged this length. This matches the expected pointer-prompt size: summary ~80 chars + separator + brief path ~130 chars + trailing text.

### 4. Cline-sr Received Empty Query Parameters

**File:** `~/.vscode-agent-bridge/data-54328/logs/20260915T144542/window1/exthost/cline-sr.cline-sr/Cline SR.log`

```
2026-09-15 14:45:44.391 [info] INFO SharedUriHandler: Processing URI:{"path":"/task","query":{},"scheme":"vscode:"}
```

**Location:** Cline-sr's URI handler processing the URI dispatched by extension.ts:142 (`vscode.env.openExternal(uri)`).

The `query: {}` is **empty** — no `prompt` parameter at all. This is the smoking gun: everything after the `#` character was stripped from the URI before it reached cline-sr's handler.

### 5. Root Cause: Fragment Delimiter Mishandling

**File:** `extension/src/extension.ts:137-141`

```typescript
function submitToClineSr(prompt: string): void {
  log("INFO", `cline-sr task URI invoked (prompt length: ${prompt.length})`);
  const uri = vscode.Uri.parse(
    `${vscode.env.uriScheme}://cline-sr.cline-sr/task?prompt=${encodeURIComponent(prompt)}`
  );
  vscode.env.openExternal(uri).then(undefined, (err: unknown) => {
```

**The bug:** The extension passes the prompt to `encodeURIComponent()`, which correctly encodes the `#` character as `%23`. However, the encoded prompt is embedded directly in a URI string template, which is then passed to `vscode.Uri.parse()`. 

**Expected behavior (correct URI parsing):**
- URI string: `vscode://cline-sr.cline-sr/task?prompt=High-effort%20code%20review%20of%20PR%20%23697...%60`
- `vscode.Uri.parse()` should parse this correctly, recognizing `%23` as an encoded hash, not a fragment delimiter.
- Query parameter received by cline-sr: `prompt=High-effort code review of PR #697...`

**Observed behavior (bug):**
- The `vscode.Uri.parse()` function appears to treat an unencoded `#` as a fragment delimiter BEFORE decoding. When it scans the URI string for special characters, it finds the literal string "of PR #697" in the raw template (because the prompt is inserted verbatim before encoding, or it was encoded post-parse).
- Alternatively, `vscode.Uri.parse()` may be buggy in how it handles `%23` — treating it as semantically equivalent to `#` even though it should be treated as literal characters.
- Result: everything after the first `#` is treated as a fragment and discarded, leaving `query: {}`.

**Test:** The pointer prompt was:
```
High-effort code review of PR #697 federation-add-member integration test suite. Your full task brief is at `/Users/r.herasymenk/.vscode-agent-bridge/briefs/brief-030794c9cedb4f2487df246d1a4fc2f6.md` — read it first, then proceed.
```

After encoding with `encodeURIComponent()`:
```
High-effort%20code%20review%20of%20PR%20%23697%20...
```

When inserted into the URI template and parsed by `vscode.Uri.parse()`, the parser sees or reconstructs a `#` and splits the URI there, treating:
- Query: `?prompt=High-effort%20code%20review%20of%20PR%20`  (everything before `#`)
- Fragment: `697...` (everything after `#`)

The extension then passes this parsed URI to `vscode.env.openExternal()`, which may drop the fragment (per RFC 3986, fragments are local-only and not transmitted in URIs), leaving cline-sr with only the truncated query.

---

## Why Existing Tests Did Not Catch This

1. **No extension unit tests** for `submitToClineSr()` covering special characters in the prompt.
2. **No integration tests** exercising a prompt with `#` character end-to-end (bridge → extension → cline-sr).
3. **Summary validation in ADR-0086** (`bridge.py:_validate_summary()`) caps the summary at 600 encoded characters and truncates with `...`, but does NOT test for the presence of special characters like `#` that might trigger transport bugs.
4. **No validation in ADR-0087** (`bridge.py`, `server.py`) checks for characters that might be problematic in URIs (e.g., `#`, `&`, `?`).

---

## Root-Cause Trace: Path of the Prompt

```
Bridge receives question (5092 raw chars)
  ↓ [server.py:104-107 logs full length]
  ↓
Bridge validates and offloads to brief file (>850 encoded chars)
  ↓ [bridge.py:140-143 logs brief write successful]
  ↓
Bridge prepares pointer prompt with summary prefix:
  "High-effort code review of PR #697 ... Your full task brief is at `/path` ..."
  (230 raw chars, includes literal # character)
  ↓ [hookserver.py:58 sends over WebSocket as JSON]
  ↓
Extension receives JSON and parses prompt (extension.ts:114)
  → prompt = "High-effort...PR #697...path..."
  ↓ [extension.ts:138 logs length 230]
  ↓
Extension calls encodeURIComponent(prompt)
  → "High-effort%20...PR%20%23697...%60path%60..."
  ↓ [%23 is correct encoding for #]
  ↓
Extension constructs URI template string:
  `vscode://cline-sr.cline-sr/task?prompt=${encoded}`
  ↓ [Raw string, contains %23 at position ~40]
  ↓
Extension passes to vscode.Uri.parse()
  [BUG OCCURS HERE]
  ✗ vscode.Uri.parse() incorrectly treats %23 as a fragment delimiter
  ✗ OR vscode.Uri.parse() has a bug where it searches for # before decoding
  ✗ URI is split: path="/task", query="?prompt=High-effort%20...%20", fragment="697..."
  ↓ [No error raised; parsing completes]
  ↓
Extension passes parsed URI to vscode.env.openExternal()
  ↓ [Fragments are local-only per RFC 3986; may be dropped]
  ↓
Cline-sr URI handler receives URI with query: {}
  [Fragment is gone, query is truncated at %23]
  ✓ Confirms: cline-sr sees empty query params
```

---

## Relationship to Prior Research

**Previous investigation (2026-09-03, `docs/research/cline-prompt-truncation-2026-09-03.md`):**
- **Root cause identified:** MCP parameter truncation in Claude Code's MCP client layer, NOT the bridge or extension.
- **Prompt received by bridge:** Truncated (~740 chars).
- **Mitigation applied:** ADR-0087 (lower brief-offload threshold from 1900 to 850 encoded chars) and ADR-0086 (add summary prefix to offloaded prompts).

**Previous investigation (2026-08-30, `docs/research/brief-truncation-analysis.md`):**
- **Root cause identified:** URI transport has implicit length limits (~2000–8000 chars); brief content is silently truncated by URI parsing layer.
- **Mechanism:** Extension constructs URI via query parameter; no protection against over-length URIs.
- **Mitigation suggested:** implement brief-file offload (since implemented as ADR-0077) or post brief to workspace file.

**This incident (2026-09-15):**
- **New root cause:** `vscode.Uri.parse()` bug / misuse with special characters in query parameters.
- **Not the same as 2026-09-03:** The bridge DID receive the full prompt (no MCP truncation). The failure is downstream at URI parsing.
- **Not the same as 2026-08-30:** The prompt is well under any length limit (230 chars is tiny). The failure is not length-based; it's character-based (the `#` in "PR #697").
- **Regression from ADR-0086 implementation:** The summary prefix feature itself introduced this bug by including summary text that may contain `#` (e.g., PR numbers, GitHub issue references). The prior research never tested with `#` in the prompt.

---

## Why Tests for ADR-0086 Missed This

The test suite (`mcp/vscode-agent-bridge/tests/test_*.py`) validates:
- Summary length capping (ADR-0086 `_validate_summary()` truncation logic) ✓
- Brief file offload (ADR-0077 threshold) ✓
- Summary is prepended to pointer prompt ✓

But no test exercises a pointer prompt with a `#` character through the extension's URI construction. The tests stop at the bridge layer; they do not verify that the extension can dispatch the prompt to cline-sr without loss.

---

## Recommended Fix Options

### Option 1: Encode the entire prompt parameter value (RECOMMENDED)

**File:** `extension/src/extension.ts:139–141`

**Change:** Double-encode or escape special characters before passing to `vscode.Uri.parse()`.

```typescript
function submitToClineSr(prompt: string): void {
  log("INFO", `cline-sr task URI invoked (prompt length: ${prompt.length})`);
  const encodedPrompt = encodeURIComponent(prompt);
  // Escape % as %25 to prevent vscode.Uri.parse from re-interpreting encoded sequences
  const safeEncodedPrompt = encodedPrompt.replace(/%/g, '%25');
  const uri = vscode.Uri.parse(
    `${vscode.env.uriScheme}://cline-sr.cline-sr/task?prompt=${safeEncodedPrompt}`
  );
  vscode.env.openExternal(uri).then(undefined, (err: unknown) => {
```

**Trade-off:** Adds extra escaping layer; may be fragile if `vscode.Uri.parse()` applies further transformations.

### Option 2: Use `vscode.Uri.with()` or `vscode.Uri.parse()` with query object (RECOMMENDED)

**File:** `extension/src/extension.ts:139–141`

**Change:** Use VS Code's URI builder API instead of string concatenation.

```typescript
function submitToClineSr(prompt: string): void {
  log("INFO", `cline-sr task URI invoked (prompt length: ${prompt.length})`);
  const baseUri = vscode.Uri.parse(`${vscode.env.uriScheme}://cline-sr.cline-sr/task`);
  // Use query object to avoid manual encoding issues
  const uri = vscode.Uri.with(baseUri, { query: `prompt=${encodeURIComponent(prompt)}` });
  vscode.env.openExternal(uri).then(undefined, (err: unknown) => {
```

**Trade-off:** Requires verifying that `vscode.Uri.with()` correctly handles query objects (i.e., doesn't apply further transformations).

### Option 3: Pass prompt via WebSocket message body instead of URI (MOST ROBUST)

**File:** `extension/src/extension.ts:113-115` and cline-sr's URI handler contract

**Change:** Dispatch the prompt over the existing WebSocket instead of constructing a URI.

```typescript
// In extension.ts message handler (line 113):
if (msg.type === "submit" && typeof msg.prompt === "string") {
  // Instead of submitToClineSr(msg.prompt), send the prompt directly to cline-sr via a new WebSocket message
  // This requires cline-sr to support a new message type, e.g. "task_direct"
  await ws.send(JSON.stringify({ type: "task_direct", prompt: msg.prompt }));
}
```

**Prerequisite:** Cline-sr's WebSocket handler must be modified to accept task prompts over the WebSocket (currently only the bridge sends over WebSocket; cline-sr initiates via URI handler).

**Trade-off:** Requires changes to cline-sr (out of scope for this kit). Most robust because it bypasses URI parsing entirely.

### Option 4: Sanitize summary to exclude `#` (MINIMAL FIX)

**File:** `bridge/bridge.py:156-192` (_validate_summary)

**Change:** Strip or replace `#` characters in the summary.

```python
def _validate_summary(summary: str | None) -> str | None:
    if summary is None:
        return None
    
    summary = summary.strip()
    if not summary:
        return None
    
    # Remove # to avoid URI fragment issues (2026-09-15 incident)
    summary = summary.replace("#", "")
    
    # ... rest of validation ...
```

**Trade-off:** Loses information (PR numbers, issue references in the summary are stripped). Does not fix the underlying vscode.Uri.parse() issue; only masks it for summary text.

---

## Smallest Correct Fix

**Option 2** is the smallest and most correct: use `vscode.Uri.with()` or a proper query-param builder if available. This avoids string concatenation and lets the URI builder handle encoding/escaping correctly. If `vscode.Uri.with()` is not available or doesn't solve it, **Option 1** (double-encoding) is the next-smallest fix that stays within the extension layer.

**Not recommended:** Option 4 (sanitize summary) because it silently loses information without fixing the root cause; the bug would still exist for any `#` in the question text if future delegations use inline dispatch with `#` in the prompt.

---

## Sources

- **Bridge server logs:** `~/.vscode-agent-bridge/logs/vscode-agent-bridge.log:19520-19522` (question length logging)
- **Bridge dispatch logs:** `~/.vscode-agent-bridge/logs/vscode-agent-bridge.log:19523` (brief offload confirmation)
- **Extension logs:** `~/.vscode-agent-bridge/data-54328/logs/20260915T144542/window1/exthost/output_logging_20260915T144543/1-Agent Bridge.log:2` (prompt dispatch length)
- **Cline-sr logs:** `~/.vscode-agent-bridge/data-54328/logs/20260915T144542/window1/exthost/cline-sr.cline-sr/Cline SR.log:6` (URI handler receives empty query)
- **Extension source:** `extension/src/extension.ts:137-150` (submitToClineSr function)
- **Bridge source:** `bridge/bridge.py:117-153` (_prepare_dispatch_prompt function, ADR-0086 implementation)
- **Bridge source:** `bridge/bridge.py:156-192` (_validate_summary function, ADR-0086 validation)
- **Server source:** `mcp/vscode-agent-bridge/server.py:104-115` (question length logging, ADR-0087)
- **ADR-0086:** `docs/adr/0086-brief-file-summary-prefix.md` (summary prefix design)
- **ADR-0087:** `docs/adr/0087-prompt-truncation-mitigation.md` (lower threshold and logging)
- **Prior research:** `docs/research/cline-prompt-truncation-2026-09-03.md` (MCP client truncation)
- **Prior research:** `docs/research/brief-truncation-analysis.md` (URI length limits)

---

## Correction (post-implementation)

**Verified root cause:** The cline-sr extension's URI handler decodes the entire URI string with `decodeURIComponent()` *before* parsing it with `new URL()`. The relevant code from the cline-sr bundle (`~/.vscode/extensions/cline-sr.cline-sr-1.26.0/dist/extension.js`) is:

```js
let m = decodeURIComponent(g.toString());   // decodes the WHOLE URI string
...
let r = new URL(m);
let s = new URLSearchParams(r.search.slice(1).replace(/\+/g,"%2B"));
s.get("prompt")
```

This means that when the bridge extension single-encodes the prompt (`#` → `%23`) and constructs a URI string, `vscode.Uri.parse()` parses it correctly. However, when cline-sr receives the URI and calls `toString()`, it gets the single-encoded form. Then cline-sr's `decodeURIComponent()` turns `%23` back into `#`, and `new URL()` treats that `#` as a fragment delimiter, discarding everything after it.

**`vscode.Uri.parse` is NOT buggy:** The bridge extension's use of `vscode.Uri.parse()` was correct. The issue is the mismatch between the encoding contract expected by cline-sr's handler and what the bridge was providing.

**Ampersand is also affected:** The same bug truncates prompts at `&` characters, since after cline-sr's decode, `&` is interpreted as a query parameter separator by `URLSearchParams`.

**Fix implemented:** Option 1 from the brief — using `vscode.Uri.from()` instead of `vscode.Uri.parse()`. The `Uri.from()` method stores the query string verbatim without decoding. When `toString()` is called on the resulting URI, it percent-encodes all special characters including the `%` from the single-encoded prompt, yielding the required double-encoding (`%` → `%25`, so `%23` → `%2523`). This ensures that after cline-sr's whole-URI decode, the prompt remains single-encoded, and `URLSearchParams.get("prompt")` decodes it once more to the original.

**Test coverage:** A new test file `extension/src/taskUri.test.ts` validates the fix with prompts containing `#`, `&`, `%`, `+`, backticks, em dashes, newlines, and unicode. A regression test confirms the old `Uri.parse` approach fails as expected.
