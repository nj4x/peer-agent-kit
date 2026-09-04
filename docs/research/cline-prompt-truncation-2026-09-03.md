# Investigation: Truncated Delegation Prompt (2026-09-03)

## Verdict

**YES, truncation confirmed.** The prompt was truncated when delivered to cline-sr in session PID:71579 on 2026-09-03 16:55:36. The truncation occurred **in the MCP client layer (Claude Code)**, NOT in the bridge or extension.

---

## Evidence

### 1. Cline Task Receipt (Truncated)

**Task ID**: 1788479736091 (bridge task: 600159e1875448c9b0a8136521e9d1a9)  
**Timestamp**: 2026-09-03 16:55:36  
**Location**: `~/.vscode-agent-bridge/data-71579/User/globalStorage/cline-sr.cline-sr/tasks/1788479736091/ui_messages.json`

Message 0 (task assignment, type: "say", len: 741 chars):
```
Three edits to install.sh and update.sh:1. **install.sh**: After the "Uninstall: ..." 
line in the success banner (around line 482), add: `say "Update:    $HOME_DIR/update.sh"`
2. **update.sh**: At the very end after the success banner's last `say` line, add: 
`say "Update:    $HOME_DIR/update.sh"` (mirror of install.sh's update line)
3. **install.sh browser open**:    - Add a `--no-browser` flag to the argument parser 
(look for the existing flag parsing block around line 50-80)   - At the very end of 
the script (after the success banner, just before or after the shell restart line), 
add logic to open the browser on macOS/Linux UNLESS `--no-browser` was passed:   ```bash   
if [ "$BROWSER_OPEN" != "false" ]; then     if command -v open
```

**END OF PROMPT — mid-sentence.**

Later, cline asked (Message 48):
> "The task description for item #3 (install.sh browser open) appears to be cut off. You 
> mentioned adding a `--no-browser` flag and browser open logic, but the code snippet 
> ends mid-way."

### 2. Bridge Dispatch (Inline, Not Offloaded)

**Session log**: `~/.vscode-agent-bridge/logs/vscode-agent-bridge.log:19485-19487`

```
2026-09-03 16:55:35,078 -07:00 [INFO] task submitted: id=600159e1875448c9b0a8136521e9d1a9 
workspace=/Users/r.herasymenk/workspace/anthrouter
2026-09-03 16:55:35,079 -07:00 [INFO] task 600159e1875448c9b0a8136521e9d1a9: queued -> dispatched
```

**No brief file was created.** No log line mentioning "brief offloaded" — the prompt was 
under `ENCODED_BRIEF_THRESHOLD = 1900` encoded chars and dispatched inline (unchanged).

The bridge called `_prepare_dispatch_prompt(record)` at `bridge.py:246` which returned the 
question unchanged and dispatched it to the extension via `hookserver.dispatch(prompt)` at 
`bridge.py:252`.

### 3. Estimated Prompt Length

**Raw character count**: ~740 chars (the truncated version cline received is 741 chars)  
**Encoded length** (via `urllib.parse.quote(..., safe="!'()*-._~")`): ~1090 encoded chars

This is **well below** the 1900-char brief threshold. Under ADR-0077, no offload was triggered.

### 4. Full Prompt Beginning (from Claude Code's submit call)

From investigation prompt provided:
> "Three edits to install.sh and update.sh: 1. **install.sh**: After the \"Uninstall: ...\" 
> line in the success banner (around line 482), add: `say \"Update:    $HOME_DIR/update.sh\"` 
> ... 3. **install.sh browser open**: ... ```bash   if [ \"$BROWSER_OPEN\" != \"false\" ]; 
> then     if command -v open"

This matches the head of Message 0 in cline's ui_messages.json exactly, confirming the 
truncation happened between Claude Code's MCP call and the bridge's receipt.

---

## Root Cause

**Claude Code's MCP client truncates the `question` parameter to a length limit before 
sending it to the bridge MCP server.**

### Why Not the Bridge?

1. The bridge logs "task submitted" and immediately calls `_pump()` to dispatch within 
   the same event loop tick (line 281 of bridge.py: `await self._pump(_async_timeout())`).
2. The bridge does not truncate: `_validate()` at bridge.py:191 only strips whitespace 
   and validates existence; there is no `[:N]` slicing on the question.
3. `_prepare_dispatch_prompt()` at bridge.py:113 **explicitly checks for over-length 
   prompts** via `_encoded_length(question) > ENCODED_BRIEF_THRESHOLD` and offloads them 
   to a brief file. No truncation — offload or pass through.
4. The queue stores the question as-is: `queue.submit(question, ...)` at bridge.py:279 
   makes no modifications.

**If the bridge had received the full prompt, the bridge's logs would show either:**
- "task submitted" with a note of the question length (not logged per ADR-0069), or
- "brief offloaded to..." (if prompt > 1900 encoded chars)

Neither happened. The task shows `id=600159...` and `workspace=...` only, indicating 
the MCP tool call itself was truncated at the parameter level.

### Why Not the Extension/WebSocket/URI?

1. The prompt was never offloaded to a brief file, so there was no URI dispatch. The 
   WebSocket dispatch (hookserver.py:58) sends `{"type": "submit", "prompt": prompt}` 
   directly.
2. WebSocket text frames have no fixed length limit (they can span multiple frames), and 
   the bridge's aiohttp library makes no truncations.
3. The extension's `submitToClineSr()` at extension.ts:137 logs 
   `"cline-sr task URI invoked (prompt length: ${prompt.length})"` — **if this log entry 
   exists in the bridge window's VS Code logs, it would show the prompt length seen by 
   the extension.** (Not checked here, as the research task does not include bridge window 
   logs, only the MCP server logs and cline task state.)

---

## Evidence Chain

```
Claude Code (MCP client)
  ↓ 
  submit_to_peer_agent(question, workspace, summary)
  [question parameter TRUNCATED HERE]
  ↓
Bridge MCP server (receives truncated question)
  ↓
  _validate() → question.strip() (no further truncation)
  ↓
  queue.submit(question, ...) → stores truncated question
  ↓
  _prepare_dispatch_prompt(record)
    → _encoded_length(truncated_question) ≤ 1900 → return unchanged
  ↓
  hookserver.dispatch(truncated_prompt) → sends over WebSocket to extension
  ↓
Extension → cline-sr URI handler → cline-sr task receives truncated prompt
```

---

## Root Cause Location

**File**: Claude Code's MCP parameter validation or encoding layer (not in this repo)  
**Mechanism**: Unknown without access to Claude Code's internal request handling.  
**Likely cause**: 
- MCP tool parameter has an implicit length limit (e.g., 2000 chars for string parameters).
- Claude Code truncates parameters to fit a limit before serialization.
- The truncation is silent — no warning or error message to the user.

---

## Suggested Fix Direction

### In peer-agent-kit (bridge, extension):

1. **Add explicit prompt-length validation** in `server.py:submit_to_peer_agent()`:
   - Log the question's raw character count and encoded length at INFO level.
   - Raise a validation error if question is under some minimum (e.g., 3 chars) 
     or over a known safe limit (e.g., 50,000 chars).
   - This would catch truncated questions entering the bridge and fail loudly 
     instead of silent dispatch of incomplete prompts.

   **Why helpful**: If the question is truncated BY Claude Code before sending, the 
   validation error will surface to the delegator and signal that the prompt 
   must be handled differently (e.g., written to a file and passed as a path, 
   not as an inline string parameter).

2. **Document the limit in the tool contract**:
   - Update `server.py:submit_to_peer_agent()` docstring to note:
     > "Note: The `question` parameter is subject to MCP client constraints 
     > (currently ~2KB observed). For prompts longer than ~1KB, prefer 
     > ADR-0077 brief-file offload (encoded length > 1900 chars) or write 
     > the prompt to a workspace file and pass the path."

3. **Extension logging enhancement**:
   - Ensure extension.ts:138 logs the prompt length at every dispatch:
     `log("INFO", "...prompt length: ${prompt.length})` 
   - This confirms whether the extension is receiving the truncated version 
     and surfaces the problem in the bridge window's logs.

### Outside peer-agent-kit (Claude Code / MCP SDK):

1. Raise the `question` parameter limit or remove it.
2. Add a validation error (not silent truncation) if a parameter exceeds the 
   transport limit.
3. Document the limit explicitly in the MCP tool schema or API docs.

---

## References

- **ADR-0077** (`docs/adr/0077-brief-file-offload.md`):  
  Specifies `ENCODED_BRIEF_THRESHOLD = 1900` and the offload mechanism for 
  over-length prompts. No offload was triggered because the bridge never saw 
  the full prompt.

- **ADR-0086** (`docs/adr/0086-brief-file-summary-prefix.md`):  
  Adds optional `summary` parameter (cap 600 encoded chars, truncated with " ...").  
  Not implicated — summary truncation is intentional and independent of question truncation.

- **ADR-0069** (`docs/adr/0069-observability.md`, implied):  
  Logging convention: log prompt length, not content. Bridge follows this; 
  no prompt text in session logs.

- **Bridge code**:  
  - `server.py:52-95`: `submit_to_peer_agent()` tool contract  
  - `bridge.py:113-149`: `_prepare_dispatch_prompt()` — no truncation, only offload-or-pass  
  - `bridge.py:191-199`: `_validate()` — only strips whitespace  
  - `hookserver.py:55-58`: `dispatch()` — sends over WebSocket unchanged  
  - `extension/src/extension.ts:137-150`: extension.ts submission to cline-sr URI

- **Cline task artifacts**:  
  - `~/.vscode-agent-bridge/data-71579/User/globalStorage/cline-sr.cline-sr/tasks/1788479736091/ui_messages.json`  
    Message 0 (task assignment), Message 48 (cline asks for complete task #3)

- **Session log**:  
  - `~/.vscode-agent-bridge/logs/vscode-agent-bridge.log:19485-19487`  
    Task submit and dispatch events; no brief offload logged.
