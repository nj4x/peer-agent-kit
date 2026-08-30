---
artifact-type: adr
lineage-rules:
  - "ADR must reference at least one source SRS item"
source-srs: .data/requirements/peer-agent-kit-SRS-001.md
---

# ADR-0077: Brief-File Offload for Long Delegation Prompts

**Status**: Accepted

**Source SRS**: SRS-PAK-008

## Context

The extension submits a delegated task's prompt to cline-sr via a VS Code URI: `vscode://cline-sr.cline-sr/task?prompt=<encodeURIComponent(prompt)>` (`extension/src/extension.ts:137-141`). This URI handler is cline-sr's own external API — not something this kit controls — and it accepts only a `prompt` query parameter. URI query parameters have implicit OS/VS Code length limits (~2000-8000 chars); `encodeURIComponent()` inflates the prompt further — ASCII specials become `%XX` (newline → `%0A`), and non-ASCII code units become multi-byte sequences up to `%XX%XX%XX` (3× per character for CJK/emoji) — so the effective limit in original characters varies with content and cannot be bounded by a raw character count. No component in the pipeline (`bridge.py:_validate()`, `hookserver.py:dispatch()`, `extension.ts`) validates or warns on prompt length today.

In one observed session, a delegated brief was silently truncated mid-sentence at the URI layer. cline-sr received a prompt ending mid-token and stopped to ask the user for the missing content — defeating low-friction delegation (FS-PAK-004) despite the delegating LLM having written a complete brief. See `docs/research/brief-truncation-analysis.md` for the full investigation.

## Decision

The length check operates on the **encoded** prompt — the exact string the URI transport sees. When `encodeURIComponent(prompt).length` exceeds `ENCODED_BRIEF_THRESHOLD = 1900` (a conservative budget under the ~2000-char OS lower bound, leaving headroom for the URI scheme/path/param overhead), the bridge writes the full prompt to `~/.vscode-agent-bridge/briefs/brief-<task-id>.md` and dispatches a short pointer prompt instead, using the **absolute** path:

> "Your full task brief is at `/Users/<user>/.vscode-agent-bridge/briefs/brief-<task-id>.md` — read it first, then proceed."

Prompts whose encoded form is at or under the threshold are dispatched inline unchanged, preserving today's behavior for typical tasks. Because the check measures encoded length, it is encoding-agnostic: a CJK-heavy prompt offloads at the correct point even though its raw character count is far below what an ASCII prompt would tolerate.

**Brief file location — deliberately outside the peer's workspace.** Brief files live under the bridge's own data root (`~/.vscode-agent-bridge/briefs/`), co-located with Task Logs, not inside the delegated workspace. This removes any dependency on workspace-path resolution (rootless, multi-root, and non-git sessions need no special handling), keeps delegated worktrees free of bridge artifacts (no `.gitignore`/`.git/info/exclude` machinery needed), and gives brief files the same ownership and retention surface as the rest of the bridge's on-disk state. The prerequisite — cline-sr must be able to read an absolute path outside its open workspace root — was **verified live on 2026-08-30**: a marker file at `~/.vscode-agent-bridge/briefs/test-brief-read.md` was read back correctly by cline-sr via `ask_peer_agent` from a workspace that does not contain it.

**Failure policy.** Writing the brief file is a prerequisite of dispatch, not an enhancement: if the write fails (disk full, permissions), the task is rejected — the error propagates to the bridge caller and the task is marked failed. A pointer prompt is never dispatched unless the file it points to has been written successfully. This follows the fatal-prerequisite / best-effort-enhancement distinction established in ADR-0076's failure policy.

**No hard rejection ceiling.** File-offload removes the URI's practical limit, so arbitrarily large briefs are accepted. A WARNING is logged when the written brief exceeds 50KB (~12k tokens — a substantial fraction of the peer's context window, signalling a brief that probably should have been a workspace file reference instead), as a signal for oversized-brief investigation, not a block.

**Retention.** Brief files persist after task completion with no cleanup mechanism defined here — the same retention posture as Task Logs, which share the `~/.vscode-agent-bridge/` root and also accumulate without sweeping. A future cleanup decision (e.g. extending ADR-0071's orphan sweep to `briefs/`) would cover both surfaces at once.

## Considered Options

- **Reject over-length prompts** (fail `_validate()`, force the delegating LLM to shorten): rejected — caps what can legitimately be delegated (e.g. a large diff or full error log) rather than solving the transport limit.
- **Chunk the prompt across multiple URI dispatches**: rejected — cline-sr's task URI has no documented multi-part or append semantics; would require protocol support this kit doesn't own.
- **Write brief files into the delegated workspace** (`<workspace>/.vscode-agent-bridge/`): rejected — requires workspace-path resolution with undefined behavior for rootless/multi-root/non-git sessions, adds `.git/info/exclude` patching machinery, and scatters bridge artifacts across user worktrees. Chosen location removes all three at the cost of one verified assumption (out-of-workspace reads).
- **File-offload to bridge data root (chosen)**: works within cline-sr's existing single `prompt` param; reading a file by absolute path is a verified peer-agent capability, not a new integration surface.

## Consequences

- **Pro**: removes the URI length limit as a delegation failure mode entirely; briefs of any size are delivered intact, regardless of character encoding.
- **Pro**: no change to cline-sr's URI contract — the fix stays entirely within the bridge and its own data directory.
- **Pro**: zero footprint in delegated workspaces; no VCS-hygiene machinery.
- **Con**: adds one extra read step for the peer on large briefs (open the file, then proceed) instead of receiving the prompt directly.
- **Con**: depends on cline-sr's ability to read outside its workspace root. Verified against the current cline-sr build; a future cline-sr sandboxing change would break offloaded briefs (failure surfaces as the peer reporting it cannot read the path — visible, not silent).
- **Con**: brief files accumulate under `~/.vscode-agent-bridge/briefs/` with no cleanup; bounded by the same accepted posture as Task Log retention on the same root.

## Related

- `docs/research/brief-truncation-analysis.md`: investigation that identified the URI truncation mechanism
- **ADR-0068**: orchestration flow, documents the existing URI dispatch path this ADR modifies
- **ADR-0069**: observability; established the "log prompt length only, not content" convention this ADR's threshold logic builds on
- **ADR-0071**: orphaned session data-dir sweep; the natural extension point for future brief-file cleanup
- **ADR-0076**: source of the fatal-prerequisite vs. best-effort-enhancement failure-policy distinction applied here
