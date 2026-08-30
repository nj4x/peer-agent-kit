---
name: peer-agent
description: >
  Delegate work to cline, a separate VS Code agent, through the
  vscode-agent-bridge MCP tools. Modes: off, lite, full, max. Use for
  /peer-agent, "delegate to cline", "ask the peer agent", or when the
  active mode's policy sends a task to the peer.
disable-model-invocation: true
---

Delegate work to **cline** — a peer VS Code agent reached through the vscode-agent-bridge MCP tools (`ask_peer_agent`, `submit_to_peer_agent`, `poll_peer_agent`). The active mode decides *what* gets delegated; the mechanics apply at every mode.

## Persistence

Mode holds for the whole session until changed. Default: **full**. Switch: `/peer-agent off|lite|full|max`. `off` means no delegation — do all work locally.

## Modes

| Mode | What delegates |
|------|----------------|
| **lite** | Delegate only filesystem/codebase search, mechanical edits fully specified in advance (rename, find/replace, apply a given patch), and running commands to report output. Floor: any request carrying planning, design, or architecture language stays local even if phrased simply — never lite-delegate on wording alone. |
| **full** | Main agent designs, plans, critiques, accepts. Delegate: everything in lite; execution of an already-developed plan or a discrete slice of it; drafting code changes whose design is already decided; validating reports or claims (independent second read); straightforward skill-based tasks (e.g. render a markdown file via html-view). Stays local: design and architecture, planning, resolving ambiguity, anything depending on conversation context the peer lacks, and final acceptance of every delegated result. |
| **max** | Delegate by default — if the peer can attempt it, it goes to the peer: multi-step implementation, research, debugging, refactors. Local-only floor: conversation and judgement calls with the user, mode changes, composing the delegation prompts, and verification/acceptance of delegated work. Motivation is token economy — prefer one well-briefed delegation over doing the work locally, and batch related work into fewer, larger delegations. |

Worked examples:

- lite: "find every call site of `parseConfig`" — delegate (search)
- lite: "rename `foo` to `bar` across the repo" — delegate (mechanical edit)
- lite: "run the test suite and report failures" — delegate (command)
- lite: "plan how to add pagination" — stays local (floor: planning language)
- full: "implement the three steps we just agreed on" — delegate (plan execution)
- full: "does this report's claim about the migration hold up?" — delegate (validation)
- full: "how should we structure the auth module?" — stays local (design)
- max: "fix the failing tests" — delegate
- max: "should we ship this?" — stays local (judgement call with the user)

## Delegation mechanics

These apply at every mode.

1. Resolve the **workspace**: the directory the task is about, defaulting to the current working directory. It is cline's live working tree — edits land there and show up in `git diff`. Never delegate a workspace holding production credentials: the peer's reads inside it are unconstrained.
2. Brief the peer like a colleague with zero context: the goal, relevant file paths, constraints, and the report format you expect back.
3. Pick the call by task length:
   - Quick question or small task: `ask_peer_agent` — blocks up to 180 seconds. On `failed` with reason `timeout`, the answer may still be coming: call `poll_peer_agent` with the returned `id` after a short wait to recover it.
   - Long task (minutes of work, multi-step edits): `submit_to_peer_agent`, then collect with `poll_peer_agent`. When the delegation needs multiple submit/poll cycles, spawn a general-purpose subagent to run the loop — it follows the same active mode's rules; there is no dedicated peer-agent agent type.
4. Verify before reporting done: read the peer's answer and diff, then accept or redo. Acceptance stays local at every mode, including max.

The first call spawns the dedicated VS Code window if it is not already up — expect extra latency on a cold start.

**Sub-workspace targets**: if the delegated task's workspace is nested inside the folder already open in the dedicated window (e.g., open root `/project`, task workspace `/project/src`), the bridge reuses the window without a reload — cline-sr receives no workspace-root-change signal and keeps resolving relative paths against the open root, not the sub-workspace. When briefing a sub-workspace task, reference files by absolute path or by path relative to the open root, never relative to the sub-workspace.

## Bridge down

On the first delegation failure with reason `instance_down` in a session, tell the user once that the peer is unavailable and continue locally. Retry only when the user asks or a new session starts.
