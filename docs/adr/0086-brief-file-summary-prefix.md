---
artifact-type: adr
lineage-rules:
  - "ADR must reference at least one source SRS item"
source-srs: .data/requirements/peer-agent-kit-SRS-001.md
---

# ADR-0086: Brief-File Summary Prefix for Delegated Tasks

**Status**: Accepted

**Source SRS**: SRS-PAK-008 (brief delivery integrity)

## Context

ADR-0077 established brief-file offload to solve URI truncation: when an encoded delegation prompt exceeds ~1900 chars, the bridge writes it to `~/.vscode-agent-bridge/briefs/brief-<task-id>.md` and dispatches a pointer prompt:

> "Your full task brief is at `/Users/<user>/.vscode-agent-bridge/briefs/brief-<task-id>.md` — read it first, then proceed."

This pointer is generic and task-agnostic. A human orchestrator (Claude Code or an agent) sees cline-sr start work with no visible context about what task is being attempted — the summary exists only in the written brief file, not in the foreground. This hampers observability: a watcher cannot scan the task queue or session logs and understand task intent at a glance.

## Decision

When `submit_to_peer_agent()` is called with an optional `summary` parameter, and the prompt is subsequently offloaded to a brief file, the bridge prefixes the summary to the pointer prompt:

```
"<summary>. Your full task brief is at `<path>` — read it first, then proceed."
```

**Inline dispatch (no offload)**: when the prompt's encoded length is at or under `ENCODED_BRIEF_THRESHOLD` and the prompt is dispatched inline (ADR-0077's unchanged path), the `summary` parameter is accepted but has no effect on the dispatched text — the full prompt is already visible in the foreground, so no prefix is added and the summary is discarded after validation.

**Tool contract change**: add optional `summary: str | None = None` parameter to `submit_to_peer_agent(question, workspace, summary=None)` in `server.py:50`.

**Validation** (all limits in **encoded** units, measured with `urllib.parse.quote` — the same metric as `ENCODED_BRIEF_THRESHOLD`, per ADR-0077; raw character counts are not commensurate with the threshold because encoding expands spaces and punctuation 3× and non-ASCII up to 9×):
- The summary's encoded length must not exceed **600 encoded characters**. Derivation: the pointer prompt's measured encoded baseline (fixed text + absolute brief path + `%20` expansion) is ~1100 encoded chars; the threshold is 1900; the 800-char headroom is capped at 600 to keep a ≥200-char margin for path-length variance (longer usernames, deeper home directories).
- If the summary exceeds the cap, truncate raw characters from the end until the encoded length of `summary + " ..."` is ≤ 600, with ` ...` appended to signal incompleteness. Truncation trims raw characters but the acceptance check is always on the encoded result.
- If `summary` is `None`, the offloaded prompt shows only the pointer (today's ADR-0077 behavior), with no change.

**Implementation site**: `bridge.py:_prepare_dispatch_prompt()` — when offloading is triggered and a summary is present, prepend it; validation happens alongside the existing question validation at the Bridge submission boundary (`bridge.py:_validate_summary()`, called from `Bridge.submit()` — the same layer where `_validate()` already checks question/workspace).

## Consequences

- **Pro**: task intent is visible in session logs, task queue, and cline-sr's task UI preview — a human observer can scan without opening the brief file.
- **Pro**: summary is optional; existing callers with no summary continue unchanged.
- **Pro**: the cap is stated in the same encoded units as the threshold, so the safety margin is arithmetic, not estimation: ~1100 encoded baseline + ≤600 encoded summary ≤ 1700 encoded chars, ≥200 under the 1900 threshold — the merged pointer prompt cannot re-trigger the truncation bug ADR-0077 fixed, regardless of how densely the summary encodes.
- **Con**: callers must explicitly pass `summary` — a convention-only approach (extracting first line from `question`) would be automatic but silent/fragile; explicit is better.
- **Con**: the encoded cap bites at fewer raw characters for space-dense or non-ASCII summaries (a CJK summary hits 600 encoded at ~66 raw chars); truncation is signalled (`...`), but the task's actual intent is still only in the brief file.
- **Con**: a summary passed with a short prompt (inline dispatch) is silently discarded — accepted, since the full prompt is already foreground-visible in that path and the discard rule is declared in the contract.
- **Implementation note**: add a unit test asserting `baseline_encoded_length + 600 <= ENCODED_BRIEF_THRESHOLD` under the current pointer-prompt text and constants, so a future edit to the pointer-prompt text or the threshold fails loud instead of silently invalidating the headroom math.

## Related

- **ADR-0077**: brief-file offload, establishes the pointer-prompt mechanism this ADR extends.
- **ADR-0068**: orchestration flow and `submit_to_peer_agent` tool contract.
- **ADR-0069**: observability and logging conventions.
