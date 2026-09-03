import asyncio

from bridge.queue import ANSWERED, DISPATCHED, FAILED, QUEUED, BridgeQueue, Record


def test_submit_starts_queued():
    queue = BridgeQueue()
    record = queue.submit("question", "/tmp")
    assert record.status == QUEUED
    assert queue.get(record.id) is record


def test_submit_with_summary_stores_summary():
    """BridgeQueue.submit stores summary on Record when provided."""
    queue = BridgeQueue()
    record = queue.submit("question", "/tmp", summary="Task summary here")
    assert record.summary == "Task summary here"


def test_submit_without_summary_defaults_to_none():
    """BridgeQueue.submit defaults summary to None when not provided."""
    queue = BridgeQueue()
    record = queue.submit("question", "/tmp")
    assert record.summary is None


def test_record_summary_field_defaults_to_none():
    """Record dataclass has summary field defaulting to None."""
    record = Record(id="test-id", question="q", workspace="/tmp")
    assert record.summary is None


def test_next_dispatchable_marks_in_flight():
    queue = BridgeQueue()
    record = queue.submit("q", "/tmp")
    dispatched = queue.next_dispatchable()
    assert dispatched is record
    assert record.status == DISPATCHED
    assert queue.in_flight() is record


def test_single_in_flight_blocks_second_dispatch():
    queue = BridgeQueue()
    first = queue.submit("q1", "/tmp")
    second = queue.submit("q2", "/tmp")
    assert queue.next_dispatchable() is first
    assert queue.next_dispatchable() is None  # still busy
    assert second.status == QUEUED


def test_complete_frees_in_flight_for_next_dispatch():
    queue = BridgeQueue()
    first = queue.submit("q1", "/tmp")
    second = queue.submit("q2", "/tmp")
    queue.next_dispatchable()
    queue.complete("answer", "ls -la")
    assert first.status == ANSWERED
    assert first.answer == "answer"
    assert first.command == "ls -la"
    assert queue.in_flight() is None
    assert queue.next_dispatchable() is second


def test_cancel_with_bound_matching_id_marks_in_flight_failed():
    queue = BridgeQueue()
    record = queue.submit("q", "/tmp")
    queue.next_dispatchable()
    queue.bind_cline_task("cline-1")
    queue.cancel("cancelled", "cline-1")
    assert record.status == FAILED
    assert record.reason == "cancelled"
    assert queue.in_flight() is None


def test_cancel_before_bind_is_ignored_as_teardown():
    queue = BridgeQueue()
    record = queue.submit("q", "/tmp")
    queue.next_dispatchable()
    queue.cancel("cancelled", "old-cline-task")  # previous task's teardown
    assert record.status == DISPATCHED
    assert queue.in_flight() is record


def test_cancel_with_mismatched_id_is_ignored():
    queue = BridgeQueue()
    record = queue.submit("q", "/tmp")
    queue.next_dispatchable()
    queue.bind_cline_task("cline-1")
    queue.cancel("cancelled", "cline-other")
    assert record.status == DISPATCHED
    assert queue.in_flight() is record


def test_cancel_without_payload_id_on_bound_record_applies_positionally():
    """Cancel without payload ID on a bound record degrades to positional (lost TaskCancel id)."""
    queue = BridgeQueue()
    record = queue.submit("q", "/tmp")
    queue.next_dispatchable()
    queue.bind_cline_task("cline-1")
    queue.cancel("cancelled", None)  # payload taskId missing; apply positionally
    assert record.status == FAILED
    assert record.reason == "cancelled"


def test_bind_keeps_first_binding():
    queue = BridgeQueue()
    record = queue.submit("q", "/tmp")
    queue.next_dispatchable()
    queue.bind_cline_task("cline-1")
    queue.bind_cline_task("cline-2")
    assert record.cline_task_id == "cline-1"


def test_complete_without_ids_applies_positionally():
    queue = BridgeQueue()
    record = queue.submit("q", "/tmp")
    queue.next_dispatchable()
    queue.complete("answer", None)
    assert record.status == ANSWERED


def test_complete_with_matching_id_succeeds():
    queue = BridgeQueue()
    record = queue.submit("q", "/tmp")
    queue.next_dispatchable()
    queue.bind_cline_task("cline-1")
    queue.complete("answer", "pytest", "cline-1")
    assert record.status == ANSWERED
    assert record.answer == "answer"
    assert record.command == "pytest"


def test_complete_with_mismatched_id_drops_answer(caplog):
    caplog.set_level("WARNING", logger="vscode-agent-bridge.queue")
    queue = BridgeQueue()
    record = queue.submit("q", "/tmp")
    queue.next_dispatchable()
    queue.bind_cline_task("cline-1")
    queue.complete("answer", None, "cline-other")
    assert record.status == DISPATCHED
    assert record.answer is None
    assert any("mismatch" in r.getMessage() for r in caplog.records)


def test_late_completion_resurrects_failed_bound_record():
    queue = BridgeQueue()
    record = queue.submit("q", "/tmp")
    queue.next_dispatchable()
    queue.bind_cline_task("cline-1")
    queue.fail(record.id, "timeout")  # ask deadline hit while work continues
    assert record.status == FAILED
    queue.complete("late answer", "pytest", "cline-1")
    assert record.status == ANSWERED
    assert record.answer == "late answer"
    assert record.command == "pytest"
    assert record.reason is None


def test_late_completion_without_match_is_dropped(caplog):
    caplog.set_level("WARNING", logger="vscode-agent-bridge.queue")
    queue = BridgeQueue()
    record = queue.submit("q", "/tmp")
    queue.next_dispatchable()
    queue.fail(record.id, "timeout")  # never bound
    queue.complete("late answer", None, "cline-1")
    assert record.status == FAILED
    assert any("answer dropped" in r.getMessage() for r in caplog.records)


def test_record_tool_use_only_touches_in_flight():
    queue = BridgeQueue()
    record = queue.submit("q", "/tmp")
    queue.record_tool_use()  # nothing in flight yet — no-op, no crash
    assert record.tool_uses == 0
    queue.next_dispatchable()
    queue.record_tool_use()
    queue.record_tool_use()
    assert record.tool_uses == 2
    assert record.last_event_at is not None


def test_fail_queued_record_removes_from_pending():
    queue = BridgeQueue()
    first = queue.submit("q1", "/tmp")
    second = queue.submit("q2", "/tmp")
    queue.next_dispatchable()  # first is in flight
    queue.fail(second.id, "timeout")
    assert second.status == FAILED
    assert second.reason == "timeout"
    queue.complete("a", None)
    assert queue.next_dispatchable() is None  # second was removed, nothing left


def test_fail_is_idempotent_after_terminal_state():
    queue = BridgeQueue()
    record = queue.submit("q", "/tmp")
    queue.next_dispatchable()
    queue.complete("answer", None)
    queue.fail(record.id, "timeout")  # must not clobber an answered record
    assert record.status == ANSWERED
    assert record.answer == "answer"


def test_fail_in_flight_clears_slot():
    queue = BridgeQueue()
    record = queue.submit("q", "/tmp")
    queue.next_dispatchable()
    queue.fail_in_flight("instance_down")
    assert record.status == FAILED
    assert record.reason == "instance_down"
    assert queue.in_flight() is None


def test_fail_in_flight_noop_when_idle():
    queue = BridgeQueue()
    queue.fail_in_flight("instance_down")  # must not raise


def test_sweep_expired_only_touches_queued_and_dispatched(monkeypatch):
    import time

    queue = BridgeQueue()
    stale = queue.submit("q1", "/tmp")
    fresh = queue.submit("q2", "/tmp")

    real_monotonic = time.monotonic
    monkeypatch.setattr(time, "monotonic", lambda: real_monotonic() - 10_000)
    stale.submitted_at = time.monotonic()
    monkeypatch.setattr(time, "monotonic", real_monotonic)

    queue.sweep_expired(async_timeout=1.0)
    assert stale.status == FAILED
    assert stale.reason == "timeout"
    assert fresh.status == QUEUED


def test_get_unknown_handle_returns_none():
    queue = BridgeQueue()
    assert queue.get("nope") is None


def test_status_transitions_logged(caplog):
    caplog.set_level("INFO", logger="vscode-agent-bridge.queue")
    queue = BridgeQueue()
    record = queue.submit("q", "/tmp")
    queue.next_dispatchable()
    queue.complete("done", None)
    messages = [r.getMessage() for r in caplog.records]
    assert any(f"task submitted: id={record.id}" in m for m in messages)
    assert any(f"task {record.id}: queued -> dispatched" in m for m in messages)
    assert any(f"task {record.id}: dispatched -> answered" in m for m in messages)


def test_failure_transition_logged_with_reason(caplog):
    caplog.set_level("INFO", logger="vscode-agent-bridge.queue")
    queue = BridgeQueue()
    record = queue.submit("q", "/tmp")
    queue.next_dispatchable()
    queue.bind_cline_task("cline-1")
    queue.cancel("cancelled", "cline-1")
    messages = [r.getMessage() for r in caplog.records]
    assert any(f"task {record.id}: dispatched -> failed (reason=cancelled)" in m for m in messages)


# Tests for signal_event signaling on terminal transitions

async def test_complete_signals_event():
    """Waiter on record.signal_event wakes when complete() is called."""
    queue = BridgeQueue()
    record = queue.submit("q", "/tmp")
    queue.next_dispatchable()

    # Start a waiter on the event
    wait_task = asyncio.create_task(record.signal_event.wait())

    # Complete the task
    queue.complete("answer", None)

    # Waiter should wake up
    await asyncio.wait_for(wait_task, timeout=0.1)
    assert record.signal_event.is_set()


async def test_cancel_terminal_transition_signals_event():
    """Waiter wakes when cancel() reaches the terminal transition (record must be bound)."""
    queue = BridgeQueue()
    record = queue.submit("q", "/tmp")
    queue.next_dispatchable()
    queue.bind_cline_task("cline-1")

    # Start a waiter on the event
    wait_task = asyncio.create_task(record.signal_event.wait())

    # Cancel with matching bound id (terminal transition)
    queue.cancel("cancelled", "cline-1")

    # Waiter should wake up
    await asyncio.wait_for(wait_task, timeout=0.1)
    assert record.signal_event.is_set()
    assert record.status == "failed"


async def test_fail_signals_event():
    """Waiter wakes on direct fail(record_id, reason) call."""
    queue = BridgeQueue()
    record = queue.submit("q", "/tmp")
    queue.next_dispatchable()

    # Start a waiter on the event
    wait_task = asyncio.create_task(record.signal_event.wait())

    # Fail the record
    queue.fail(record.id, "timeout")

    # Waiter should wake up
    await asyncio.wait_for(wait_task, timeout=0.1)
    assert record.signal_event.is_set()
    assert record.status == "failed"


async def test_cancel_no_in_flight_event_not_set():
    """Event is NOT set when cancel() takes the no in-flight task guard."""
    queue = BridgeQueue()
    record = queue.submit("q", "/tmp")
    # Do not dispatch - leave it queued
    # Create a separate record that would be in flight if we dispatched
    queue.cancel("cancelled", "some-task")

    # The queued record's event should NOT be set
    assert not record.signal_event.is_set()


async def test_cancel_pre_bind_event_not_set():
    """Event is NOT set when cancel() takes the pre-bind teardown guard."""
    queue = BridgeQueue()
    record = queue.submit("q", "/tmp")
    queue.next_dispatchable()
    # Do NOT bind - leave cline_task_id as None
    # Cancel with a payload id (pre-bind teardown path)
    queue.cancel("cancelled", "old-cline-task")

    # The dispatched record's event should NOT be set (still DISPATCHED, not terminal)
    assert not record.signal_event.is_set()
    assert record.status == "dispatched"


async def test_cancel_id_mismatch_event_not_set():
    """Event is NOT set when cancel() takes the cline taskId mismatch guard."""
    queue = BridgeQueue()
    record = queue.submit("q", "/tmp")
    queue.next_dispatchable()
    queue.bind_cline_task("cline-1")
    # Cancel with mismatched id
    queue.cancel("cancelled", "cline-other")

    # The record's event should NOT be set (still DISPATCHED, not terminal)
    assert not record.signal_event.is_set()
    assert record.status == "dispatched"


# Tests for dispatch_at field (ADR-0085 ticket 03)

def test_dispatch_at_defaults_to_none():
    """Record.dispatch_at is None by default."""
    queue = BridgeQueue()
    record = queue.submit("q", "/tmp")
    assert record.dispatch_at is None


def test_next_dispatchable_sets_dispatch_at(monkeypatch):
    """next_dispatchable() sets record.dispatch_at = time.monotonic() when marking DISPATCHED."""
    import time
    
    queue = BridgeQueue()
    record = queue.submit("q", "/tmp")
    
    # Mock time.monotonic to return a known value
    monkeypatch.setattr(time, "monotonic", lambda: 1000.0)
    
    dispatched = queue.next_dispatchable()
    
    assert dispatched is record
    assert record.dispatch_at == 1000.0
    assert record.status == "dispatched"


def test_dispatch_at_not_set_for_queued_record():
    """A record that is never dispatched keeps dispatch_at as None."""
    queue = BridgeQueue()
    record = queue.submit("q", "/tmp")
    # Never dispatch - leave it queued
    assert record.dispatch_at is None
    assert record.status == "queued"


# Tests for activity field on poll responses (ADR-0085 ticket 03)

def test_poll_includes_activity_field(monkeypatch):
    """All poll response shapes include activity field."""
    import time
    from bridge.bridge import Bridge

    bridge = Bridge()

    # Override time.monotonic to control staleness
    current_time = 1000.0
    def mock_monotonic():
        return current_time
    monkeypatch.setattr(time, "monotonic", mock_monotonic)

    # Queued record — activity should be None
    record = bridge.queue.submit("q", "/tmp")
    response = bridge.poll(record.id)
    assert response["activity"] is None
    assert response["status"] == "pending"

    # Dispatch the record
    bridge.queue.next_dispatchable()
    assert record.dispatch_at == 1000.0

    # Immediately after dispatch, activity should be "live" (fresh)
    response = bridge.poll(record.id, baseline_tool_uses=0)
    assert response["activity"] == "live"
    assert response["status"] == "pending"


def test_poll_activity_live_for_terminal_states():
    """Terminal states (answered, failed) always report activity='live'."""
    from bridge.bridge import Bridge

    bridge = Bridge()

    # Answered record
    r_answered = bridge.queue.submit("q1", "/tmp")
    bridge.queue.next_dispatchable()
    bridge.queue.complete("answer", "cmd")
    response = bridge.poll(r_answered.id)
    assert response["status"] == "answered"
    assert response["activity"] == "live"

    # Failed record - must bind before cancel for cancel to apply
    r_failed = bridge.queue.submit("q2", "/tmp")
    bridge.queue.next_dispatchable()
    bridge.queue.bind_cline_task("cline-1")
    bridge.queue.cancel("cancelled", "cline-1")  # cancel with matching bound id
    response = bridge.poll(r_failed.id)
    assert response["status"] == "failed"
    assert response["activity"] == "live"


def test_poll_activity_null_for_unknown_handle():
    """Unknown handle returns activity=None."""
    from bridge.bridge import Bridge

    bridge = Bridge()
    response = bridge.poll("nonexistent-id")
    assert response["status"] == "failed"
    assert response["reason"] == "unknown_handle"
    assert response["activity"] is None


def test_poll_activity_live_when_tool_fired(monkeypatch):
    """Activity is 'live' when tool_uses increased since baseline (delta > 0)."""
    import time
    from bridge.bridge import Bridge

    bridge = Bridge()
    current_time = 1000.0
    def mock_monotonic():
        return current_time
    monkeypatch.setattr(time, "monotonic", mock_monotonic)

    record = bridge.queue.submit("q", "/tmp")
    bridge.queue.next_dispatchable()

    # Baseline at dispatch: tool_uses == 0
    baseline = record.tool_uses

    # Tool fires (simulating hook POST)
    bridge.queue.record_tool_use()
    assert record.tool_uses == 1

    # Fast-forward time 60s (well past 30s stale threshold)
    current_time = 1060.0

    # Activity should still be 'live' because tool_uses increased since baseline
    response = bridge.poll(record.id, baseline_tool_uses=baseline)
    assert response["activity"] == "live"
    assert response["tool_uses"] == 1


def test_poll_activity_stalled_when_no_delta_and_old_heartbeat(monkeypatch):
    """Activity is 'stalled' when no tool delta and heartbeat > 30s stale."""
    import time
    from bridge.bridge import Bridge

    bridge = Bridge()
    current_time = 1000.0
    def mock_monotonic():
        return current_time
    monkeypatch.setattr(time, "monotonic", mock_monotonic)

    record = bridge.queue.submit("q", "/tmp")
    bridge.queue.next_dispatchable()

    # Record one tool use at dispatch time
    current_time = 1005.0
    bridge.queue.record_tool_use()
    assert record.last_event_at == 1005.0
    assert record.tool_uses == 1

    # Baseline is set AFTER the tool use (simulating poll entry after hook fired)
    baseline = record.tool_uses  # 1

    # Fast-forward past 30s stale threshold (last_event_at was at 1005.0)
    current_time = 1036.0  # 31 seconds after last_event_at

    # No new tool uses (delta is 0 since baseline matches current)
    response = bridge.poll(record.id, baseline_tool_uses=baseline)
    assert response["activity"] == "stalled"
    assert response["tool_uses"] == 1


def test_poll_activity_live_when_heartbeat_recent(monkeypatch):
    """Activity is 'live' when heartbeat is recent (< 30s stale)."""
    import time
    from bridge.bridge import Bridge

    bridge = Bridge()
    current_time = 1000.0
    def mock_monotonic():
        return current_time
    monkeypatch.setattr(time, "monotonic", mock_monotonic)

    record = bridge.queue.submit("q", "/tmp")
    bridge.queue.next_dispatchable()
    baseline = record.tool_uses

    # Record event at dispatch
    bridge.queue.record_tool_use()
    assert record.last_event_at == 1000.0

    # Fast-forward 15s (within 30s threshold)
    current_time = 1015.0

    # Activity should be "live" due to recency
    response = bridge.poll(record.id, baseline_tool_uses=baseline)
    assert response["activity"] == "live"


def test_poll_activity_stalled_with_dispatch_at_reference(monkeypatch):
    """Activity uses dispatch_at as reference when last_event_at is None."""
    import time
    from bridge.bridge import Bridge

    bridge = Bridge()
    current_time = 1000.0
    def mock_monotonic():
        return current_time
    monkeypatch.setattr(time, "monotonic", mock_monotonic)

    record = bridge.queue.submit("q", "/tmp")
    bridge.queue.next_dispatchable()
    assert record.dispatch_at == 1000.0
    assert record.last_event_at is None  # No hook event yet
    baseline = record.tool_uses  # 0

    # Fast-forward 31s (past stale threshold)
    current_time = 1031.0

    # No tool uses, no last_event_at, but dispatch_at is 31s old
    response = bridge.poll(record.id, baseline_tool_uses=baseline)
    assert response["activity"] == "stalled"


def test_poll_activity_at_exact_30s_boundary(monkeypatch):
    """Activity is 'live' when recency is exactly 30s (threshold inclusive)."""
    import time
    from bridge.bridge import Bridge

    bridge = Bridge()
    current_time = 1000.0
    def mock_monotonic():
        return current_time
    monkeypatch.setattr(time, "monotonic", mock_monotonic)

    record = bridge.queue.submit("q", "/tmp")
    bridge.queue.next_dispatchable()
    bridge.queue.record_tool_use()
    baseline = record.tool_uses  # 1

    # Fast-forward exactly 30s
    current_time = 1030.0

    # recency == 30.0 (should be "live" per <= comparison)
    response = bridge.poll(record.id, baseline_tool_uses=baseline)
    assert response["activity"] == "live"


def test_poll_activity_just_over_30s_boundary(monkeypatch):
    """Activity is 'stalled' when recency is just over 30s."""
    import time
    from bridge.bridge import Bridge

    bridge = Bridge()
    current_time = 1000.0
    def mock_monotonic():
        return current_time
    monkeypatch.setattr(time, "monotonic", mock_monotonic)

    record = bridge.queue.submit("q", "/tmp")
    bridge.queue.next_dispatchable()
    bridge.queue.record_tool_use()
    baseline = record.tool_uses

    # Fast-forward slightly past 30s
    current_time = 1030.01

    # recency > 30.0 (should be "stalled")
    response = bridge.poll(record.id, baseline_tool_uses=baseline)
    assert response["activity"] == "stalled"
