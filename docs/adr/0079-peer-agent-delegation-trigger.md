---
artifact-type: adr
lineage-rules: exempt
title: Peer-agent delegation trigger model
status: accepted
date: 2026-09-01
authors: Roman Herasymenko
---

# ADR-0079: Peer-agent delegation trigger model

Lineage is exempt: this ADR records a delegation-policy decision about the kit's
own authoring workflow, not a behavior any SRS item governs.

## Context

The peer-agent skill enables Claude Code sessions to delegate work to cline-sr running in a dedicated VS Code window via the `ask_peer_agent` / `submit_to_peer_agent` MCP tools. Three candidate trigger models were evaluated:

- **Option A: Policy-driven injection** — Inject mode rules (SessionStart hook) and rely on Claude's judgment to invoke the tools.
- **Option B: Explicit opt-in** — Caller passes explicit `tools` or `mcpServers` overrides when spawning a subagent.
- **Option C: Hybrid** — Policy-driven for top-level sessions, explicit opt-in for subagents.

## Research findings

1. **Policy injection exists but doesn't auto-fire.** SessionStart hook injects SKILL.md mode rules into the system prompt (ADR-0070 hook correlation, ADR-0068 bridge orchestration). However, Claude Code's Agent tool reads only subagent YAML `description:` fields for delegation decisions, not system prompt content — so injected policy rules do not influence Agent tool behavior.

2. **Direct peer-agent tool invocation works end-to-end.** Explicit `ask_peer_agent` calls are executed and dispatched correctly (confirmed via #21 prototype). The tool works; injection alone is not the blocker.

3. **Injection-only has zero observed auto-delegation across 38 sessions.** Research (peer-agent-delegation-analysis-2026-09-01.md) found zero automatic peer-agent tool invocations despite policy rules being injected. Tool availability is confirmed, but users do not automatically invoke it based on injected policy.

4. **Option B (explicit opt-in via `tools` parameter) lacks Claude Code support.** No evidence exists that Claude Code's `Agent()` tool accepts caller-supplied `tools` or `mcpServers` overrides at spawn time. This was inspired by DeepAgents but is not confirmed for Claude Code.

5. **Subagents run in separate sessions and need explicit injection.** Research (#23) confirmed subagents spawn as fresh sessions (separate JSONL files). SessionStart hook runs in the parent session only, so subagents never receive injected policy. Issue #24 decided: subagents should receive identical injection via the SubagentStart hook, which Claude Code added in v2.0.43 (`~/.claude/cache/changelog.md`) and fixed in v2.1.141.

## Decision

**Unified injection approach: SessionStart + SubagentStart, no explicit opt-in layer.**

- Top-level sessions receive mode policy injection at SessionStart.
- Subagents receive identical mode policy injection at SubagentStart (per the Issue #24 design).
- No new enforcement mechanism (e.g., PreToolUse nudge) is added.
- No explicit opt-in layer for subagent spawning; injection is the sole propagation mechanism.

### Consequences

**Accepted limitations:**
- Delegation does not fire automatically. Policy injection documents the session's *capability* and *encouragement*, not a guarantee.
- Users and skills invoke `ask_peer_agent` / `submit_to_peer_agent` by explicit choice, guided by the injected policy documentation.
- Subagents inherit the parent session's active mode and receive the same injection, but do not override parent behavior — they make their own invocation decisions within the injected policy.

**SKILL.md reframe (§ Modes, the `**max**` table row):**
- Before: "Delegate by default — if the peer can attempt it, it goes to the peer: multi-step implementation, research, debugging, refactors."
- After: "Favor delegation when the peer can attempt it: multi-step implementation, research, debugging, refactors. Invocation is explicit — skill-driven or user-invoked via `ask_peer_agent` / `submit_to_peer_agent`."

**Implementation:**
- No code changes to SessionStart injection (already working).
- Implement SubagentStart hook registration in install.sh / uninstall.sh (single marker couples both hooks, per #24 design).
- Update the `**max**` row in SKILL.md § Modes to reflect the documented limitation.
- No changes to bridge, extension, or MCP server contracts.

## Rationale

The gap between "policy injected" and "tool invoked" is a product decision, not a bug. Automatic delegation based on injected rules is theoretically attractive but unproven at scale — zero invocations across 38 real sessions confirm this risk. An enforcement mechanism (e.g., PreToolUse hook) would re-introduce the complexity #24 solved with SubagentStart injection. Accepting the gap keeps the system simple: inject policy (documented, visible to user), let the user decide to delegate (explicit, auditable). This is already the live pattern — documenting it is the change.

## Related

- ADR-0068: Bridge orchestration and task lifecycle.
- ADR-0070: Hook event correlation and task log inheritance.
- Issue #24: Subagent mode inheritance via SubagentStart hook (closed, implemented).
- Issue #21: End-to-end delegation prototype (closed, confirmed working).
- Research: docs/research/peer-agent-delegation-analysis-2026-09-01.md
