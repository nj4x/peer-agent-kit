---
artifact-type: adr
lineage-rules: exempt
title: poll_peer_agent long-poll timeout and task activity observability
status: accepted
date: 2026-09-02
authors: Roman Herasymenko
---

# ADR 0085: poll_peer_agent Long-Poll Timeout and Task Activity Observability

**Status:** Accepted  
**Date:** 2026-09-02  
**Context:** Callers of `submit_to_peer_agent` must poll `poll_peer_agent` in a loop, managing their own timeout and retry logic. `ask_peer_agent` provides a single blocking call, but its 180-second ceiling is baked in and its implementation duplicates polling logic.

## Decision

1. **Remove `ask_peer_agent` tool** — eliminate redundancy and consolidate polling into a single path. This is an explicit decision made during the grilling interview: the alternative of keeping `ask_peer_agent` as a thin convenience wrapper (delegating internally to submit + poll) was presented and rejected. The breaking change is deliberately accepted; see Consequences.

2. **Add `poll_timeout_seconds` parameter to `poll_peer_agent`**:
   - Parameter is optional; default is `None` (wait until the task reaches a terminal state — see the lifecycle guarantee below).
   - Internally uses `asyncio.Event` per task (added to `Record` dataclass) for efficient signaling, not sleep loops.
   - Env var `BRIDGE_POLL_TIMEOUT` sets a fleet-wide default (renamed from `BRIDGE_ASK_TIMEOUT`).
   - **Lifecycle guarantee for indefinite waits:** every path that takes a task out of the pending/in-flight state must signal the task's `asyncio.Event`. This covers all three terminal transitions:
     1. `BridgeQueue.complete()` (normal answer),
     2. `BridgeQueue.cancel()` (explicit cancel, and instance-down: the liveness WebSocket close detected by the InstanceManager cancels all in-flight tasks via `cancel()`),
     3. **request expiry** — the 30-minute expiry is a distinct lifecycle exit and must also signal the event. The existing sweep loop (`bridge.py:264-273`) is the enforcement point: when the sweep marks a task expired, it signals the event, and the blocked poll returns `failed` with reason `timeout` (matching the existing expiry semantics on re-poll).
   - With expiry wired into the event, an indefinite poll is bounded by the 30-minute expiry even when the VS Code instance dies abruptly without a detectable socket close: the sweep acts as the watchdog of last resort. No caller-side maximum is required.

3. **Add `activity` field to `poll_peer_agent` response**:
   - Values: `"live"` | `"stalled"` | `null`.
   - Emitted on **every** response where activity data exists — not only on `timed_out`:
     - `answered` / `cancelled`: `"live"` trivially (the task reached a terminal state; the field is populated for uniform response shape).
     - `timed_out` (poll timeout expired) and `pending` (immediate poll with `poll_timeout_seconds=0`): computed from the stall predicate below.
     - `null` only when the task was never dispatched (`last_event_at` is `None` and `tool_uses` is 0 — no hook event ever arrived).
   - **Stall predicate — reference point pinned:** both inputs are anchored to the same two instants. `tool_uses` is snapshotted at poll-call entry (the baseline); the predicate is evaluated once, at the moment the poll returns (timeout expiry for `timed_out`, immediately for `pending`). "Recency" means `last_event_at` measured against the evaluation instant, not against poll start.
     - **live:** `tool_uses` at evaluation exceeds the entry baseline, OR `last_event_at` is ≤ 30 seconds before the evaluation instant.
     - **stalled:** `tool_uses` unchanged from baseline AND `last_event_at` is > 30 seconds before the evaluation instant (or `None` after dispatch).
   - Combined logic: activity (tool increment) overrides recency; both conditions must indicate stall to emit `"stalled"`. Worked example: a task that fires a tool 29 seconds into a 180-second poll and then goes silent has a `tool_uses` delta relative to the entry baseline, so it reports `"live"` — progress during this poll counts as life regardless of how stale the heartbeat is at expiry. Only a task with no delta and a heartbeat older than 30 seconds at evaluation reports `"stalled"`.

4. **Update SKILL.md** with migration example: `submit_to_peer_agent` + `poll_peer_agent(poll_timeout_seconds=180)` replaces `ask_peer_agent`.

## Rationale

- **Unified polling model:** One entry point (`poll_peer_agent`) handles all wait scenarios. Callers compose their own semantics (fire-and-forget via immediate poll, blocking via timeout, loop-and-retry).
- **Observability for long operations:** `activity` field distinguishes hung peers from slow-but-working ones. Humans and automation can decide: retry stalled tasks, tolerate live tasks, or escalate to operator.
- **Efficient signaling:** `asyncio.Event` avoids the 250ms sleep-loop polling that `ask_peer_agent` used; wakes immediately when a task completes.
- **Env var hygiene:** Rename `BRIDGE_ASK_TIMEOUT` → `BRIDGE_POLL_TIMEOUT` clarifies that the timeout now applies to the general poll operation, not a deprecated single tool.
- **Activity logic pragmatism:** Activity (tool_uses delta) is the strongest signal of live work; if the peer fired a tool this poll, it's alive even if that tool took a while to start. Recency (last_event_at) is a backstop for truly silent peers. 30-second staleness window matches human expectations (timeout at seconds scale, not milliseconds).

## Consequences

- **Breaking change:** Callers still invoking `ask_peer_agent` will error. Migration path is clear (compose submit+poll with explicit `poll_timeout_seconds`), documented in SKILL.md. This breaking change was an explicit decision during the grilling interview; see Decision item 1.
- **Queue internals:** `Record` gains an `asyncio.Event` field. `BridgeQueue.complete()`, `BridgeQueue.cancel()`, and **the sweep loop's expiry handler** (`bridge.py:264-273`) must all signal it. Lock-free safety already exists (queue is single-threaded at the async layer).
- **Expiry observability:** The sweep loop detects task expiry (request age ≥ 30 minutes) and must invoke a signal-then-fail pattern on the asyncio.Event before marking the record failed. This ensures an indefinite `poll_peer_agent()` call returns even when the instance dies silently: the sweep wakes the blocked poll, and the poll observes `status == 'failed'` with `reason == 'timeout'`.
- **No opt-out for stalled detection:** Staleness thresholds (30s recency, tool_uses delta) are fixed; operators cannot tune per-call. If future use cases demand it, thresholds can be moved to env vars or per-call params.
- **Backward compatibility:** Old configs with `BRIDGE_ASK_TIMEOUT` will not work; must rename to `BRIDGE_POLL_TIMEOUT`. This is acceptable because the kit is not externally versioned (personal installer, not a published library).
- **Living docs update:** SKILL.md, README.md, e2e-diagram.md updated to remove `ask_peer_agent` examples and show blocking-poll idiom. ADRs and research docs left as-is (historical record).
