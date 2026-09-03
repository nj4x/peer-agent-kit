---
artifact-type: ticket
ticket-subtype: adr-direct
lineage-rules:
  - "Ticket must reference at least one source ADR"
  - "Spec field is intentionally omitted: this ticket traces directly to an ADR"
---

# 01 — Queue event signaling for terminal transitions

**Source ADR**: docs/adr/0085-poll-peer-agent-long-poll-timeout-and-activity.md

## What to build

Add an `asyncio.Event` field to the `Record` dataclass in `mcp/vscode-agent-bridge/bridge/queue.py`. Every path that takes a task out of the pending/in-flight state must signal the event (ADR 0085 lifecycle guarantee). Three signal points cover all terminal transitions:

1. `BridgeQueue.complete()` (queue.py:99) — normal answer.
2. `BridgeQueue.cancel()` (queue.py:148) — cline-sr TaskCancel; sets `status=FAILED, reason=cancelled` directly, without going through `fail()`, so it needs its own signal. **Signal placement is critical:** `cancel()` has three non-terminal early-return guard paths that must NOT signal — (a) no task in flight (queue.py:150), (b) pre-bind teardown of the previous cline task (queue.py:153), (c) cline taskId mismatch (queue.py:161). Signaling at any guard would leave the `asyncio.Event` permanently set for a still-DISPATCHED record, breaking indefinite-poll semantics. Signal only at the terminal transition (queue.py:167, after `record.status = FAILED`).
3. `BridgeQueue.fail()` (queue.py:172) — the common exit for every other failure path: sweep expiry (`sweep_expired()`, queue.py:195, reason `timeout` — watchdog of last resort when the VS Code instance dies without a detectable socket close), WebSocket-disconnect instance-down (`fail_in_flight()`, queue.py:188, invoked from hookserver.py:76, reason `instance_down`), and any internal-error path. Signal the event inside `fail()` before returning; do not put the signal in the callers (`_sweep_loop` in bridge.py or hookserver.py) — signaling at the common exit guarantees no future caller of `fail()` can forget it.

No public API change in this slice; the event is internal plumbing consumed by ticket 02.

## Blocked by

none

## Status
done

## Checklist
- [x] `Record` gains an `asyncio.Event` field named `signal_event` — code: queue.py:41
- [x] `complete()` signals the event before returning — code: queue.py:128
- [x] `cancel()` signals the event ONLY at the terminal-transition return (after `record.status = FAILED`), not at the three non-terminal early-return guards (no in-flight task; pre-bind teardown; cline taskId mismatch) — code: queue.py:170-172; tests: test_cancel_no_in_flight_event_not_set, test_cancel_pre_bind_event_not_set, test_cancel_id_mismatch_event_not_set passed
- [x] `fail()` signals the event inside the method before returning, covering all callers (sweep expiry via `sweep_expired()`, WebSocket disconnect via `fail_in_flight()`, any internal-error path) — code: queue.py:183
- [x] Unit tests: waiter on the event wakes for complete, cancel, and direct fail() call — test_complete_signals_event, test_cancel_terminal_transition_signals_event, test_fail_signals_event passed
- [x] Unit test: event is NOT set when cancel() takes a non-terminal early-return guard path (no in-flight task; pre-bind teardown) — test_cancel_no_in_flight_event_not_set, test_cancel_pre_bind_event_not_set passed
- [x] Full pytest suite passes — 148 passed, 1 skipped
