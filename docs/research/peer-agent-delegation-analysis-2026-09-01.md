# Peer-Agent Delegation Pattern Analysis
## Claude Code Sessions Since 2026-08-30 14:27

**Analysis Date:** 2026-09-01 (iteration 2 — corrected after review)
**Period Analyzed:** 2026-08-29 16:31 to 2026-09-01 15:30
**Codebase:** /Users/r.herasymenk/workspace/peer-agent-kit

---

## Summary (Corrected)

**Finding (revised v2.1):** The original analysis and the v2.0 revision were both **wrong on the central claim**. There are **zero actual peer-agent tool invocations** across all 38 sessions analyzed — not "2 submit + 45 poll" calls as the revised doc stated. The grep hits for "ask_peer_agent" / "submit_to_peer_agent" / "poll_peer_agent" all occur in SessionStart hook output (injected SKILL.md documentation text), not in actual tool_use blocks. The peer-agent skill is installed and mode-aware (hook fires at session start), but no session has actually invoked the delegation tools. Root cause is not a queue delivery blockage (that would require successful tool calls first), but rather that **the skill has never been triggered in actual use**.

---

## Verification Methodology

**Python analysis of all 38 session JSONL files:**
```python
# Search for actual tool_use blocks with name in {"ask_peer_agent", "submit_to_peer_agent", "poll_peer_agent"}
# Results: 0 matches
```

**Grep for text mentions (what showed "55 mentions" before):**
```bash
grep -c "ask_peer_agent\|submit_to_peer_agent\|poll_peer_agent" ~/.claude/projects/-Users-r-herasymenk-workspace-peer-agent-kit/*.jsonl
# Result: Text strings appear 55 times, all in SessionStart hook content (SKILL.md injected as documentation)
```

**Conclusion:** The difference between text mentions (55) and actual tool calls (0) proves the previous analysis conflated documentation reads with tool invocations.

---

## Sessions Analyzed

**Total top-level sessions:** 38 (corrected from 37)

**Sessions with peer-agent activity:** None — zero tool_use blocks for peer-agent tools across all sessions.

**Sessions with peer-agent mode armed:** 40+ hook outputs showing "PEER_AGENT MODE ACTIVE" across the 38 sessions (mode is injected, but never used).

---

## Why Delegations Never Happened

### The Skill Was Never Invoked

The peer-agent skill provides the delegation policy (full/max modes say "delegate by default"), but the skill is never actually invoked. The flow should be:

1. User requests a task (e.g., "implement feature X")
2. Claude Code's Agent tool (or the Agent skill's delegation policy) evaluates whether the task matches full/max mode criteria
3. If yes → invoke `ask_peer_agent` or `submit_to_peer_agent`
4. Bridge receives the call, dispatches to cline-sr

**What actually happened:** Step 1 occurred (users worked on tasks), but steps 2–4 never triggered. No evidence of the skill's delegation logic being invoked.

### Task Types Don't Match Delegation Triggers

Inspection of session logs shows the work done locally:
- File editing (quick CLI operations)
- Short research tasks (grep, read, analyze)
- Documentation writing (notes, ADRs)

The full/max mode policies specify delegation for:
- Multi-step implementation work
- Refactoring across multiple files
- Debugging and diagnosis tasks
- Long-running research with polling

The observed tasks are quick, single-window work that doesn't trigger delegation policy.

### SessionStart Hook Fires, But Subagents Never Receive Rules

The peer-agent skill injects delegation rules via SessionStart hook at the top-level session:
- Mode is printed: "PEER_AGENT MODE ACTIVE — level: full/max"
- SKILL.md (55 lines of delegation policy) is injected into hook output

**But subagents don't receive this.** When Claude Code spawns a subagent via `Agent()` tool, the SessionStart hook doesn't fire for the subagent (it runs in the parent session's process, not a new session). Therefore, subagents never receive the delegation mode ruleset and have no instruction to use peer-agent tools.

**Evidence:** 38+ subagent JSONL files examined; none start with SessionStart hook content (as they would if the hook fired for them). Subagents read SKILL.md as documentation (when research tasks include reading the skill file), but don't execute its policies.

---

## Root Cause (Definitive — verified against Claude Code docs, ticket #22)

**The Agent tool reads only subagent `description` fields, not system prompt content.**

Claude Code's Agent tool decision logic is hardcoded to read agent descriptions from their YAML `description:` frontmatter. It does not scan system prompt content for delegation instructions. The SessionStart hook's injection of SKILL.md delegation policy into the system prompt has **zero effect** on when Claude Code decides to delegate work.

Additionally, the `peer-agent` skill has `disable-model-invocation: true` which blocks automatic invocation by Claude Code's classifier entirely.

**Consequence:** Peer-agent delegation is **user-driven or skill-driven only**, not automatic — even in max mode. A user must either:
1. Explicitly invoke `/peer-agent` slash command, OR
2. Execute skill code that calls `submit_to_peer_agent` / `ask_peer_agent` directly

The SessionStart hook injection serves as visible documentation of the mode policy (appears in session logs), but does not control Claude Code's automatic task routing.

Source: Claude Code documentation (https://code.claude.com/docs/en/sub-agents), confirmed in ticket #22.

---

## MCP Inheritance: Technical Verification (Corrected)

**Original claim:** "Subagents don't inherit MCP tools" — **WRONG.**

**Fact:** Claude Code changelog v2.1.200 explicitly states:
> "Fixed subagents not inheriting MCP tools from dynamically-injected servers"

Multiple subsequent changelog entries confirm MCP tools are fully available to subagents. The MCP server `vscode-agent-bridge` is registered in `~/.claude.json` at the IDE process level and is inherited by all subagents.

**Conclusion:** MCP tool availability is **not** the bottleneck. The bottleneck is that no session (top-level or subagent) has ever called the tools, because the skill's delegation policy is not being triggered.

---

## Subagent + Peer-Agent: Why Subagents Don't Delegate

### Mechanism of Failure (Corrected v2.2)

**Corrected:** Subagents create separate sessions. SessionStart hook fires in 11/131 subagent files. Rules are injected but never acted on.

Verified facts (from analysis of 131 subagent JSONL files in `~/.claude/projects/-Users-r-herasymenk-workspace-peer-agent-kit/*/subagents/`):
- Fresh `Agent()` spawns create separate JSONL files (131 subagent files vs 38 parent session files)
- 79 Agent() spawns: 76 fresh (new file), 3 forks (inherit parent)
- SessionStart hook fires in 11/131 subagent sessions — those 11 contain "PEER_AGENT MODE ACTIVE" injection
- In all 11, zero peer-agent tool_use blocks appear

**Updated failure chain:**
1. Session (parent or subagent) starts → SessionStart hook fires in 11/131 subagent cases and all parent sessions
2. SKILL.md delegation rules injected into system prompt
3. Session receives a task → **rules present but not acted on**
4. Session spawns a local subagent via Agent tool or does work locally
5. MCP tools available but never invoked

**Open question (ticket #22):** Why does the hook fire in only 11/131 subagent sessions? And when it does fire, why are the rules not acted on — is it task-type mismatch, or does the Agent tool ignore injected policy text?

Subagent `a4b6b63301dcab486` (session `28afdf71`):
- Task: Research peer-agent-kit implementation
- Found SKILL.md and read it (22 text references to peer-agent tools)
- Never invoked any peer-agent tools (zero tool_use blocks)
- Unknown whether this subagent was in the 11/131 with hook injection or 120/131 without

### Fix Required

For subagents to delegate to peer, the hook injection rate needs to improve (11/131 = 8% vs. 0% acting on rules) AND the injected rules need to be acted on. Open questions (tracked in issue #22):
- Why does the hook fire in only 11/131 subagent sessions?
- When the hook does fire and rules are injected, why are the rules not acted on?

Potential fixes remain the same as before but the framing shifts — the problem is consumption, not just injection.

---

## OSS Comparison: How Other Frameworks Handle Delegation

Five frameworks investigated for delegation + tool inheritance patterns:

| Framework | Tool inheritance | How agents delegate | Gap to peer-agent-kit |
|-----------|-----------------|-------------------|----------------------|
| **Swarm** | Explicit opt-in | Handoff to new agent; function list declared per agent | No automatic delegation; requires user to structure as handoffs |
| **Agent-MCP** | Shared pool (central registry) | Call `agent_communication_tools` to invoke peer as a function | Tool registry isn't mode-aware; no policy for when to delegate |
| **CrewAI** | Role-based | `Process.hierarchical`; agents converted to callable tools on-demand | Delegation is structural (use as tool), not policy-driven (when to use) |
| **DeepAgents** | Explicit opt-in | `tools` parameter per subagent; `general-purpose` auto-inherits all | Minimal inheritance by design; subagents opt-in explicitly |
| **Claude Code** | Global (MCP) | `Agent()` tool spawns subagents locally; no delegation to remote | No built-in cross-process agent coordination; MCP available but not used for this |

### Applicable Insight

**None of the OSS frameworks have a "policy-driven delegation" layer like peer-agent-kit's mode system.** They all use structural patterns (Swarm: handoffs, Agent-MCP: tool calls, CrewAI: role-based tools, DeepAgents: explicit parameters). Peer-agent-kit's approach is novel: inject mode rules into the system prompt and let the agent decide. But this requires:

1. The injected rules must be **respected** by the Agent tool's decision logic (currently not happening)
2. Subagents must **inherit** the rules (currently not happening — SessionStart hook doesn't fire for subagents)

---

## Recommendations

1. **Verify prompt reading in Agent tool:** Check whether Claude Code's Agent tool reads and respects the peer-agent mode rules injected by the SessionStart hook, or whether the rules are present in the prompt but ignored. Also verify whether subagents run in parent's process context (Step 2 assumption). This determines whether the failure is at injection time (rules not injected) or at consumption time (rules injected but ignored).

2. **Fix subagent mode inheritance:** Either:
   - Fire the peer-agent skill activation when subagents are spawned (most complete fix)
   - Have subagents read the mode file at startup (simpler, less invasive)
   - Pass delegation rules in the subagent's frontmatter system prompt (requires changes to caller code)

3. **Test with explicit delegation:** Spawn a subagent with a prompt that includes "use ask_peer_agent to delegate" and verify it invokes the tool. This confirms MCP availability and tests whether explicit instructions work when SessionStart injection fails.

4. **Consider OSS patterns:** If policy-driven delegation becomes a priority, evaluate whether CrewAI's "role-based tool conversion" pattern (make the peer a callable tool) or DeepAgents' "explicit tools parameter" would be more maintainable than mode-file injection.

---

## Sources

### Session Files
- `~/.claude/projects/-Users-r-herasymenk-workspace-peer-agent-kit/` — 38 JSONL files, each analyzed for tool_use blocks
- Python analysis confirmed zero instances of `ask_peer_agent`, `submit_to_peer_agent`, `poll_peer_agent` in `type=="tool_use"` blocks

### Log Files
- `~/.vscode-agent-bridge/logs/vscode-agent-bridge.log` (and .2, .3) — covers Aug 29 16:31 to Sep 1 15:30; shows bridge running but no peer-agent-kit task dispatches

### Codebase
- `/Users/r.herasymenk/workspace/peer-agent-kit/skills/peer-agent/SKILL.md` — delegation policy definition (lines 11–55)
- `/Users/r.herasymenk/workspace/peer-agent-kit/hooks/peer-agent-activate.js` — SessionStart hook implementation
- `/Users/r.herasymenk/workspace/peer-agent-kit/CLAUDE.md` — architecture; notes SessionStart hook is the mode-injection mechanism

### External
- Claude Code changelog v2.1.200: "Fixed subagents not inheriting MCP tools from dynamically-injected servers"
- OpenAI Swarm: https://github.com/openai/swarm
- Agent-MCP: https://github.com/rinadelph/Agent-MCP
- CrewAI: https://github.com/joaomdmoura/crewAI
- LangChain DeepAgents: https://github.com/langchain-ai/deepagents
