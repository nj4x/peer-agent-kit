---
artifact-type: ticket
ticket-subtype: adr-direct
lineage-rules:
  - "Ticket must reference at least one source ADR"
  - "Spec field is intentionally omitted: this ticket traces directly to an ADR"
---

# 04 — Remove ask_peer_agent and migrate docs

**Source ADR**: docs/adr/0085-poll-peer-agent-long-poll-timeout-and-activity.md

## What to build

Remove the `ask_peer_agent` tool and migrate living documentation to the blocking-poll idiom. Breaking change, explicitly accepted in ADR 0085 decision 1.

- Delete `ask_peer_agent` from `mcp/vscode-agent-bridge/server.py`.
- Delete the now-dead 250ms sleep-loop polling path it exclusively used: `bridge.ask()` method and the `POLL_INTERVAL` constant in `mcp/vscode-agent-bridge/bridge/bridge.py` (not in server.py — `ask_peer_agent` in server.py calls `bridge.ask()`, which contains the sleep loop).
- Remove `BRIDGE_ASK_TIMEOUT` from `mcp/vscode-agent-bridge/bridge/bridge.py` — its sole consumer (`ask_peer_agent` / `bridge.ask()`) is deleted in this ticket, so key and consumer die together. `BRIDGE_POLL_TIMEOUT` (introduced in ticket 02) is the sole surviving timeout env var.
- Update `CLAUDE.md` Architecture section: remove `ask_peer_agent` from the tool list (line ~12 currently reads "exposes `ask_peer_agent` / `submit_to_peer_agent` / `poll_peer_agent` / `close_peer_agent`"). After deletion, the sentence should read "exposes `submit_to_peer_agent` / `poll_peer_agent` / `close_peer_agent`" (no more ask). Grep the entire living docs (excluding ADRs and research/) for any remaining `ask_peer_agent` references and remove them.
- Update `skills/peer-agent/SKILL.md`: migration example `submit_to_peer_agent` + `poll_peer_agent(poll_timeout_seconds=180)` replaces `ask_peer_agent`; scrub all `ask_peer_agent` mentions from mode tables and worked examples.
- Update `README.md` and `docs/diagrams/vscode-agent-bridge-e2e.md` to remove `ask_peer_agent` and show the blocking-poll idiom.
- Leave ADRs and `docs/research/` untouched (historical record, per ADR Consequences).

## Blocked by

02 — poll-timeout-param

## Status
done

## Checklist
- [x] `ask_peer_agent` tool removed from server.py — server.py: deleted tool function and timeout refs
- [x] `bridge.ask()` method and `POLL_INTERVAL` constant removed from bridge/bridge.py — both deleted, including `_ask_timeout()` helper
- [x] `BRIDGE_ASK_TIMEOUT` references removed from code — removed from server.py docstring and bridge.py
- [x] CLAUDE.md Architecture section updated: remove `ask_peer_agent` from tool list (still exposes submit/poll/close) — updated to "exposes `submit_to_peer_agent` / `poll_peer_agent` / `close_peer_agent`"
- [x] Grep entire living docs for remaining `ask_peer_agent` references (exclude docs/adr/ and docs/research/); remove all found — only historical plans file retains ref (acceptable, not living docs)
- [x] No remaining `ask_peer_agent` references in SKILL.md, README.md, docs/diagrams/vscode-agent-bridge-e2e.md — all removed, diagrams renumbered
- [x] SKILL.md shows submit + `poll_peer_agent(poll_timeout_seconds=180)` migration example — blocking-poll idiom documented
- [x] Tests referencing `ask_peer_agent` removed or migrated to the poll idiom — 4 ask-only tests removed from test_tools.py
- [x] Full pytest suite passes — 175 passed, 1 skipped in 2.89s
