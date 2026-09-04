---
artifact-type: adr
lineage-rules:
  - "ADR must reference at least one source SRS item"
source-srs: .data/requirements/peer-agent-kit-SRS-001.md
---

# ADR-0087: Prompt Truncation Mitigation via Threshold Reduction & Length Observability

**Status**: Accepted

**Source SRS**: SRS-PAK-006 (delivery reliability)

**Related findings**: `docs/research/cline-prompt-truncation-2026-09-03.md`

## Context

Investigation into a delegation truncation incident (2026-09-03, Session PID:71579) revealed that delegation prompts can be silently truncated by Claude Code's MCP client layer before reaching the bridge. A multi-paragraph task prompt (~1090 encoded chars, 741 raw chars) was truncated mid-sentence at the MCP parameter boundary. The bridge and extension code introduce no truncation; the cutoff occurs in Claude Code's MCP transport layer, upstream of the bridge's receipt.

**Root cause**: Claude Code's MCP client imposes an undocumented length limit on string parameters (observed at ~1090–2000 encoded chars range, exact limit unknown). When exceeded, the client truncates silently with no error message to the delegator.

**Incident impact**: cline-sr received an incomplete task description, flagged it as truncated in its own task UI (Message 48: "The task description ... appears to be cut off"), and could not complete the work without asking the delegator to re-submit.

**Why this matters**: brief-file offload (ADR-0077) was designed to solve URI length limits downstream; it does not protect against MCP parameter truncation upstream. Prompts in the 1000–1900 encoded char range (typical for multi-paragraph delegations) are vulnerable.

## Decision

Mitigate truncation risk via two complementary changes:

### 1. Lower Brief-File Offload Threshold (ADR-0077 adjustment)

**Change**: `ENCODED_BRIEF_THRESHOLD` in `bridge/bridge.py` from **1900 encoded chars → 850 encoded chars**.

**Rationale**: Offloading to a brief file (`~/.vscode-agent-bridge/briefs/brief-<id>.md`) bypasses the MCP parameter layer entirely — the prompt is written to disk, and only a short pointer prompt (~200 chars) is sent over MCP. At 850 encoded chars, prompts are offloaded earlier, reducing the probability of hitting the MCP truncation limit for typical multi-paragraph tasks while maintaining the ADR-0086 summary headroom (pointer ~224 + summary ≤600 = ~824 ≤ 850, ~26-char safety margin).

**Trade-off**: slightly increased disk I/O and overhead for brief-file I/O (negligible for task-queue throughput; observability benefit exceeds cost). Prompts ≥850 encoded chars that previously dispatched inline now write a brief file, which is the intended behavior for long prompts — the threshold change only affects the boundary.

**Conversion example**: 850 encoded chars ≈ 580–700 raw chars (varies by character set; ASCII is ~100% overhead from URL encoding, spaces/punctuation ~3×, non-ASCII up to ~9×). A typical task description ("Rename foo to bar across *.ts, update references in package.json, and add tests") is ~400 raw chars (stays inline); a multi-step task with code examples often exceeds 550 raw chars (offloaded).

### 2. Add Question-Length Logging & Truncation Warning

**Change**: In `server.py`, add length logging and early-warning at `submit_to_peer_agent()` tool entry:

- Log the received question's **raw character count** and **encoded byte count** (URL-encoded via `urllib.parse.quote(..., safe="!'()*-._~")`) at INFO level when the tool is called.
- Emit a WARNING log if the raw character count is below **100 characters**, flagging a possible truncation (context: legitimate short prompts like "Run the tests" are rarely below 50 chars; below 100 is suspiciously incomplete).
- The warning message directs the observer to check the MCP session logs for confirmation.

**Rationale**: Length logging provides observability for future truncation incidents; early warning surfaces the problem immediately rather than discovering it in cline-sr's task state. The 100-char threshold is empirical (the observed truncated prompt was 741 raw chars, far above; anything under 100 is a valid warning signal without false positives on real short tasks).

**Implementation**:
```python
# In server.py: submit_to_peer_agent() tool function
raw_len = len(question)
encoded_len = _encoded_length(question)
logger.info("submit_to_peer_agent: question length raw=%d chars, encoded=%d bytes", raw_len, encoded_len)

if raw_len < SUSPICIOUSLY_SHORT_QUESTION_CHARS:  # 100
    logger.warning(
        "question is suspiciously short (%d chars, < %d threshold) — "
        "possible truncation by MCP client. Check the logs for the full prompt.",
        raw_len, SUSPICIOUSLY_SHORT_QUESTION_CHARS
    )
```

## Consequences

**Pro: Truncation prevention**
- Typical multi-paragraph delegations (550–1500 raw chars) now trigger offload, avoiding the MCP truncation zone entirely.
- The threshold change is a one-time safety adjustment; it does not require upstream (Claude Code) changes.

**Pro: Observability**
- Future truncation incidents surface immediately in the bridge logs (warning) rather than as silent incomplete task state.
- Session logs become auditable: a sequence of submitted questions and their lengths is logged, enabling post-mortem analysis.

**Pro: No impact on short tasks**
- Prompts under 800 encoded chars continue inline dispatch; the brief-file offload is transparent to callers.
- Callers do not need to change delegation code; the mitigation is automatic.

**Con: Slightly increased disk I/O**
- Prompts previously inline (800–1900 encoded chars) now write a brief file. For typical task queues, this is negligible (a few hundred bytes/task, milliseconds per write).
- The latency trade-off is acceptable for improved reliability.

**Con: MCP truncation is not fully understood**
- The exact limit in Claude Code's MCP client is unknown (observed range: ~1090–2000 encoded chars).
- The truncation is still not *prevented*, only *avoided* by offloading earlier. A delegator passing a prompt >800 encoded chars still depends on Claude Code not truncating it during *transmission* of the brief-file pointer (though at ~200 chars, this is much less likely).
- If Claude Code's limit is, for example, 150 chars (highly unlikely but hypothetical), even the pointer would truncate. This ADR mitigates the common case but does not eliminate the risk entirely.

**Con: Extension logging may need verification**
- The extension receives the prompt over the WebSocket and should log its length. This ADR does not add extension logging; future work (not this ADR) could add extension-side confirmation.

## Implementation Details

### Files changed:

1. **`bridge/bridge.py`** (line ~32):
   - Change `ENCODED_BRIEF_THRESHOLD = 1900` → `ENCODED_BRIEF_THRESHOLD = 850`
   - Add comment referencing ADR-0087 and the truncation incident, with headroom math justification.

2. **`server.py`** (lines ~16–40, ~90–105):
   - Add import: `import urllib.parse`
   - Add constant: `SUSPICIOUSLY_SHORT_QUESTION_CHARS = 100`
   - Add helper function: `_encoded_length(text: str) -> int` (same metric as ADR-0077)
   - Add logging block in `submit_to_peer_agent()` tool function:
     - Log question length (raw + encoded)
     - Warn if raw < 100 chars

### Testing:

- Unit tests: verify that questions < 100 raw chars trigger a WARNING log (mock logger).
- Unit tests: verify that questions ≥ 800 encoded chars dispatch offloaded (brief file exists).
- Manual: submit a multi-paragraph prompt (~600 raw chars) and confirm it triggers brief-file offload in the bridge logs (previously would have been inline).
- Manual: submit a short prompt (~50 raw chars) and confirm no warning is logged (only INFO).
- Manual: submit a prompt that previously truncated and confirm it now offloads safely.

### Backward compatibility:

- **Callers**: existing callers of `submit_to_peer_agent()` need no code change; the tool signature is unchanged.
- **Thresholds**: the constant `ENCODED_BRIEF_THRESHOLD` is only used internally by the bridge; no external API changes.
- **Observability**: new logs are additive (INFO + WARNING); existing log parsing is unaffected.

## Related

- **ADR-0077**: brief-file offload mechanism, establishes the pointer-prompt design and the initial 1900-char threshold. This ADR lowers the threshold to extend the offload's protective scope.
- **ADR-0086**: brief-file summary prefix. The summary cap (600 encoded chars) remains unchanged; offload now happens more often (at 800 instead of 1900), increasing the utility of the summary parameter.
- **ADR-0068**: orchestration flow and tool contract.
- **ADR-0069**: observability and logging conventions. Length logging follows the convention: log metrics, not content.
- **`docs/research/cline-prompt-truncation-2026-09-03.md`**: detailed investigation and evidence for the root cause.
