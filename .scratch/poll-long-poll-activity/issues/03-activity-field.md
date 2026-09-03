---
artifact-type: ticket
ticket-subtype: adr-direct
lineage-rules:
  - "Ticket must reference at least one source ADR"
  - "Spec field is intentionally omitted: this ticket traces directly to an ADR"
---

# 03 — activity field in poll_peer_agent response

**Source ADR**: docs/adr/0085-poll-peer-agent-long-poll-timeout-and-activity.md

## What to build

Add an `activity` field (`"live"` | `"stalled"` | `null`) to every `poll_peer_agent` response, per ADR 0085 decision 3:

Terminal states (`answered`, `failed`):
- `activity` is `"live"` trivially (the task reached a terminal state; the field is populated for uniform response shape).

Non-terminal states (`timed_out`, `pending`):
- Computed from the stall predicate (below).

Never-dispatched case:
- `activity` is `null` only when `record.status == QUEUED` (task was never dispatched).

Stall predicate (for `timed_out` and `pending` states only, i.e. `record.status == DISPATCHED`), reference points pinned:
- Snapshot `tool_uses` at poll-call entry (baseline).
- Evaluate once at the moment the poll returns: at timeout expiry for `timed_out`; immediately for `pending` (e.g., `poll_timeout_seconds=0`).
- **Dispatch timestamp:** `Record` gains a `dispatch_at` field (float, monotonic time) set when `next_dispatchable()` marks the record DISPATCHED. Reference instant for recency: `last_event_at` if set, else `dispatch_at`. This ensures a dispatched task with no hook event yet is judged by how long it has been dispatched, not by its queued-at time.
- **live**: `tool_uses` at evaluation exceeds baseline, OR the reference instant (last_event_at or dispatch_at) is ≤ 30 seconds before the evaluation instant.
- **stalled**: `tool_uses` unchanged from baseline AND the reference instant (last_event_at or dispatch_at) is > 30 seconds before the evaluation instant. A task dispatched more than 30 seconds ago with zero hook events reports `"stalled"`, not `null` — `null` is reserved for `record.status == QUEUED` (never dispatched at all).

Tool-use delta overrides recency: a task that fires a tool 29 seconds into a 180-second poll then goes silent has a delta relative to entry baseline, so it reports `"live"` — progress during this poll counts as life regardless of heartbeat staleness at evaluation. Only a task with no delta and a heartbeat > 30 seconds stale at evaluation reports `"stalled"`. Thresholds are fixed (30s recency, tool_uses delta); no per-call tuning.

## Blocked by

02 — poll-timeout-param

## Status
done

## Checklist
- [x] `Record` gains a `dispatch_at` field (float, monotonic time, default None) — code: queue.py:42
- [x] `next_dispatchable()` sets `record.dispatch_at = time.monotonic()` when marking the record DISPATCHED — code: queue.py:64
- [x] `activity` present on every response shape (`answered`, `failed`, `timed_out`, `pending`) — code: bridge.py:290–300, 302–351
- [x] `answered` and `failed` report `"live"` trivially — code: bridge.py:296, 298
- [x] `null` only when `record.status == QUEUED` (never dispatched) — code: bridge.py:247–269
- [x] Dispatched task with zero hook events reports `"stalled"` (not `null`) once dispatched > 30s ago, using `dispatch_at` as the reference instant when `last_event_at` is unset — code: bridge.py:271–276
- [x] Baseline snapshot at poll entry; predicate evaluated at poll return; reference instant is `last_event_at` if set, else `dispatch_at` — code: bridge.py:324, 342
- [x] Test: ADR worked example — tool fired mid-poll then silence reports `"live"` — test: test_queue.py:test_poll_activity_live_when_tool_fired
- [x] Test: no delta + heartbeat > 30s stale reports `"stalled"` — test: test_queue.py:test_poll_activity_stalled_when_no_delta_and_old_heartbeat
- [x] Test: recency alone (fresh `last_event_at`, no delta) reports `"live"` — test: test_queue.py:test_poll_activity_live_when_heartbeat_recent
- [x] Test: dispatched task, zero events, dispatched > 30s ago reports `"stalled"` (uses `dispatch_at` as reference, not `submitted_at`) — test: test_queue.py:test_poll_activity_stalled_with_dispatch_at_reference
- [x] Test: task still `QUEUED` (never dispatched) reports `null` — test: test_queue.py:test_poll_includes_activity_field
- [x] Full pytest suite passes — 179 passed, 1 skipped
