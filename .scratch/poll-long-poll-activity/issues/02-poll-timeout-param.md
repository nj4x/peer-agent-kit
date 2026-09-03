---
artifact-type: ticket
ticket-subtype: adr-direct
lineage-rules:
  - "Ticket must reference at least one source ADR"
  - "Spec field is intentionally omitted: this ticket traces directly to an ADR"
---

# 02 — poll_timeout_seconds parameter on poll_peer_agent

**Source ADR**: docs/adr/0085-poll-peer-agent-long-poll-timeout-and-activity.md

## What to build

Add an optional `poll_timeout_seconds` parameter to the `poll_peer_agent` tool in `mcp/vscode-agent-bridge/server.py`:

- Default `None`: wait indefinitely until the task reaches a terminal state, by awaiting the per-task `asyncio.Event` from ticket 01. Indefinite waits are bounded in practice by the 30-minute request expiry (sweep signals the event; poll returns `failed` with reason `timeout`).
- `poll_timeout_seconds=0`: immediate poll, returns `pending` if the task is still in-flight (current `ask_peer_agent` behavior).
- Positive value: block up to that many seconds; on timeout expiry return status `timed_out` (new response status) with the task still pending and no event signal.
- Env var `BRIDGE_POLL_TIMEOUT` sets the fleet-wide default. Do not rename `BRIDGE_ASK_TIMEOUT` yet; that happens in ticket 04 when `ask_peer_agent` is deleted. This ticket introduces `BRIDGE_POLL_TIMEOUT` as the new name, and `ask_peer_agent` (which uses `BRIDGE_ASK_TIMEOUT`) is still live.
- No sleep loops: waiting uses `asyncio.Event` / `asyncio.wait_for`.

**Async integration:** `poll_peer_agent` in server.py is an async tool (line 88), but `bridge.poll()` is sync (bridge.py:246). Bridge gains an async method `async def poll_async()` (or similar name) that:
1. Checks current status first (returns immediately if terminal: `answered`/`failed`/`unknown_handle`).
2. Bounded case: awaits `asyncio.wait_for(record.signal_event.wait(), timeout=poll_timeout_seconds)`, returns `timed_out` on timeout, or the terminal status when the event fires.
3. Indefinite case (poll_timeout_seconds=None): awaits the event directly with no timeout.
4. **Unknown handle short-circuits:** when the record is missing, return `failed`/`unknown_handle` immediately regardless of poll_timeout_seconds value; no event wait attempted. This prevents indefinite waits on non-existent handles.
5. `poll_peer_agent` in server.py delegates to this async method.

## Blocked by

01 — queue-event-signaling

## Status
done

## Checklist
- [x] `bridge.py` gains async method `async def poll_async(handle: str, poll_timeout_seconds: float | None) -> dict` that integrates with `asyncio.Event` (ticket 01) — code: bridge.py:257
- [x] `poll_async` checks current status first (returns immediately if terminal, unknown_handle, or QUEUED) — code: bridge.py:268-280; deviation: QUEUED records are NOT returned immediately on indefinite/bounded polls — implementation waits on their event per ADR 0085 Decision 2 ("wait until the task reaches a terminal state"); the sweep expiry signals queued records, so waits stay bounded. Verified by test_poll_async_indefinite_waits_on_queued. Terminal and unknown_handle immediate returns verified by test_poll_async_immediate_terminal, test_poll_async_unknown_handle_no_block
- [x] Bounded case: awaits `asyncio.wait_for(record.signal_event.wait(), timeout=poll_timeout_seconds)`, returns `timed_out` on `asyncio.TimeoutError`, or the terminal status when the event fires — code: bridge.py:288-300; tests: test_poll_async_bounded_timeout_returns_timed_out, test_poll_async_bounded_event_fires_before_timeout passed
- [x] Indefinite case (poll_timeout_seconds=None): awaits the event directly with no timeout, returns terminal status when event fires — code: bridge.py:283-285; tests: test_poll_async_indefinite_resolved_by_complete/_cancel/_expiry passed
- [x] Unknown handle short-circuits to `failed`/`unknown_handle` immediately regardless of poll_timeout_seconds value; no event wait attempted — code: bridge.py:271-272; test: test_poll_async_unknown_handle_no_block passed
- [x] `poll_timeout_seconds` param added to `poll_peer_agent` in server.py, optional, default from `BRIDGE_POLL_TIMEOUT` env var, else `None` — code: server.py:89-98, _poll_timeout_default()
- [x] `poll_peer_agent` delegates to `bridge.poll_async()` — code: server.py:121-122
- [x] `BRIDGE_POLL_TIMEOUT` env var sets default timeout; `BRIDGE_ASK_TIMEOUT` remains unchanged (still used by `ask_peer_agent`, to be removed in ticket 04) — code: server.py:91, bridge.py:36 untouched; test: test_poll_peer_agent_uses_bridge_poll_timeout_env_default passed
- [x] Test: immediate poll (poll_timeout_seconds=0) returns current status (pending if in-flight, terminal if completed/failed) — test_poll_async_immediate_pending, test_poll_async_immediate_terminal passed
- [x] Test: bounded timeout expiry returns `timed_out` with task still pending — test_poll_async_bounded_timeout_returns_timed_out passed
- [x] Test: indefinite wait resolved by complete, cancel, and expiry signal paths — test_poll_async_indefinite_resolved_by_complete, test_poll_async_indefinite_resolved_by_cancel, test_poll_async_indefinite_resolved_by_expiry passed
- [x] Test: poll with poll_timeout_seconds=None on nonexistent handle returns `failed`/`unknown_handle` without blocking — test_poll_async_unknown_handle_no_block passed
- [x] Full pytest suite passes — 158 passed, 1 skipped
