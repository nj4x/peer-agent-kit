# Research: Reducing Workspace Parameter Validation Errors in `submit_to_peer_agent`

**Date**: 2026-09-02  
**Context**: Callers sometimes omit the required `workspace` parameter when invoking `submit_to_peer_agent`, producing Pydantic validation errors (Field required). Goal: identify root causes and evaluate mitigations.

---

## 1. Tool Definition & Schema

### 1.1 Function Signature
**Source**: `/Users/r.herasymenk/workspace/peer-agent-kit/mcp/vscode-agent-bridge/server.py:50`

```python
async def submit_to_peer_agent(question: str, workspace: str, ctx: Context, summary: str | None = None) -> dict:
    """Ask cline-sr a question without waiting for the answer.
    
    ...
    Args:
        question: The task question/prompt.
        workspace: Path to the workspace directory.
        ...
    """
```

- `workspace` is a required positional parameter (no default value), type `str`
- The docstring's "Args" section includes a one-line description: "Path to the workspace directory."
- The function-level docstring explains the semantic role: "required, an existing directory" and warns about credentials (lines 54–58)

### 1.2 JSON Schema Generation

**Framework**: MCP Python SDK v2.1.1 (FastMCP), available in `.venv/lib/python3.10/site-packages/mcp/server/mcpserver/`

**Schema generation flow**:  
1. `server.py:49–50` defines the tool via `@mcp.tool()` decorator on the async function
2. `tools/base.py:101–106` invokes `func_metadata(fn, skip_names=[...])` to extract argument metadata
3. `func_metadata.py:275–356` builds a Pydantic model from function parameters:
   - Each parameter becomes a Pydantic field
   - Required parameters (no default) are included in the model's `required` list (func_metadata.py:356 uses `Annotated[...], param.default` when default exists; no default → bare `Annotated[...]`)
   - **Per-parameter docstrings in the function's Args section are NOT extracted into the Pydantic Field descriptions** — only the function-level docstring becomes the tool's main description
4. `tools/base.py:106` calls `arg_model.model_json_schema(by_alias=True)` to produce the JSON schema

**Actual schema** (output from async schema inspection):
```json
{
  "properties": {
    "question": {
      "title": "Question",
      "type": "string"
    },
    "workspace": {
      "title": "Workspace",
      "type": "string"
    },
    "summary": {
      "anyOf": [{"type": "string"}, {"type": "null"}],
      "default": null,
      "title": "Summary"
    }
  },
  "required": ["question", "workspace"],
  "title": "submit_to_peer_agentArguments",
  "type": "object"
}
```

**Key observation**: The `workspace` property has only `title` and `type`; no `description` field. The per-parameter docstring ("Path to the workspace directory.") is lost during schema generation. The semantic necessity ("required, an existing directory") is only in the function docstring, not in the schema that the LLM client sees.

### 1.3 Why Docstring Details Don't Flow into Schema

**Source**: `func_metadata.py:275–362` (func_metadata function)

- Pydantic's Field descriptor (line 352, 356) receives only keyword arguments passed via `field_kwargs` dict
- The function's docstring is parsed as the overall tool description (in `tools/base.py:117`)
- **Per-parameter descriptions are NOT extracted from the docstring and added to field_kwargs** — the code extracts `param.annotation`, `param.default`, and applies Pydantic Field validators, but never reads the "Args:" section of the docstring
- To include per-parameter descriptions in the JSON schema, they must be passed via `Annotated[..., Field(description="...")]` in the type hint, not in the docstring

**MCP Python SDK limitation**: The SDK's `func_metadata()` treats per-parameter docstrings as documentation for humans, not schema metadata for the LLM client. This is by design — docstrings are unstructured prose, and extracting them reliably (parsing "Args:" sections, handling varying formats, escaping JSON) is fragile.

---

## 2. Skill Documentation & Injected Ruleset

### 2.1 SKILL.md Delegation Mechanics
**Source**: `/Users/r.herasymenk/workspace/peer-agent-kit/skills/peer-agent/SKILL.md:37–48`

> Delegation mechanics:
> 1. Resolve the **workspace**: the directory the task is about, defaulting to the current working directory. It is cline's live working tree — edits land there and show up in `git diff`. Never delegate a workspace holding production credentials: the peer's reads inside it are unconstrained.
> 2. Brief the peer like a colleague with zero context: the goal, relevant file paths, constraints, and the report format you expect back.
> 3. Use the blocking-poll idiom: call `submit_to_peer_agent`, then immediately collect with `poll_peer_agent(poll_timeout_seconds=180)` (or your chosen timeout). ...

**Assessment**: The "Delegation mechanics" section (point 1) describes *what* workspace means semantically, but does NOT explicitly state: "pass workspace as the `workspace` argument to the tool, not in the question text." The wording could lead a reader to interpret "resolve the workspace" as a planning step, with the resolution happening implicitly.

### 2.2 Hook Injection of Mode Ruleset
**Source**: `/Users/r.herasymenk/workspace/peer-agent-kit/hooks/peer-agent-activate.js:73–98`

The SessionStart hook reads SKILL.md, strips YAML frontmatter, filters the intensity table rows and examples to match the active mode, and injects the result as `additionalContext` in the system prompt (line 103):

```
hookSpecificOutput: {
  hookEventName,
  additionalContext: `PEER_AGENT MODE ACTIVE — level: ${mode}\n\n` + filtered.join('\n')
}
```

This injected context reaches Claude Code's system prompt and includes the Delegation mechanics text. However:
- The injected text is long and contains many rules for different modes
- It does NOT include a prominent, isolated warning like: **"Always pass `workspace` as the `workspace` tool argument."**
- It relies on the reader parsing prose under "Delegation mechanics" and inferring the requirement

---

## 3. Error Messaging

**Current error** (Pydantic validation):
```
Error executing tool submit_to_peer_agent: 1 validation error for submit_to_peer_agentArguments
workspace
  Field required [type=missing, ...]
```

**Issues**:
- Purely mechanical: "Field required" tells the caller a field is missing, but not *which* field is important to which tool
- No remediation guidance: does not explain that workspace should be a file path, or that it must be a tool argument (not prose)
- No context: does not appear alongside the tool description; reaches the caller as a raw exception

---

## 4. ADR Review

**ADR-0086** (`Brief-File Summary Prefix`, source SRS-PAK-008):  
- Adds optional `summary` parameter to tool contract
- Validates summary length (600 encoded chars)
- No mention of workspace validation or schema clarity

**ADR-0077** (`Brief-File Offload`):  
- Describes prompt truncation and URI length limits
- No mention of parameter validation or schema descriptions

**ADR-0068** (`Orchestration Module`):  
- Covers tool contract and Bridge submission
- No guidance on parameter ergonomics or schema completeness

**Finding**: No ADR addresses tool parameter schema completeness, validation error messaging, or schema descriptions for optional/required parameters. This is a gap in the design documentation.

---

## 5. MCP SDK Schema Capabilities

**Question**: Does the MCP SDK support richer parameter descriptions, examples, or validation hints in the JSON schema?

**Answer** (from MCP SDK source):

1. **Field descriptions via `Annotated`**: The SDK supports Pydantic `Field(description="...")` inside `Annotated[...]` type hints (func_metadata.py:17, 352, 356). Example:
   ```python
   from pydantic import Field
   from typing import Annotated
   
   async def submit_to_peer_agent(
       question: str,
       workspace: Annotated[str, Field(description="Absolute path to the working directory. Must exist.")],
       ctx: Context,
       summary: Annotated[str | None, Field(description="Optional one-line task summary.")] = None
   ) -> dict:
   ```
   This description flows into `properties.workspace.description` in the JSON schema.

2. **Examples in schema**: Pydantic 2.0+ supports `Field(examples=[...])`, which appears in the schema as `"examples": [...]`. The MCP SDK passes it through (tools/base.py:106 uses `model_json_schema()`).

3. **Enum or constrained types**: Pydantic supports `Field(pattern="^/")` or custom validators, which flow into the schema.

4. **Required field enforcement**: Pydantic automatically includes required fields in the JSON schema's `required` array (as observed in the current schema output, line "required": ["question", "workspace"]).

**Limitation**: The per-parameter docstring (in the function's "Args:" section) is NOT read by func_metadata or the SDK; it must be manually duplicated in `Field(description="...")` or the LLM client never sees it.

---

## 6. Evidence of Frequency

Log inspection (if available) was requested but `.vscode-agent-bridge/logs/` is user-local and not accessible in this repo. However, the error pattern ("workspace" field missing from tool invocation) is a known LLM behavior: when a tool's schema omits `description` for a required parameter, LLMs often skip or misinterpret it, especially if:
- The parameter name is generic ("workspace" rather than "workspace_directory_path")
- The parameter description in the schema is empty (just `title: "Workspace"`)
- The parameter appears in a list with other required fields, and context is minimal

---

## Candidate Mitigations

### A. **Enrich Schema Descriptions** (Low effort, high impact)

Add per-parameter `Field(description="...")` to the function signature using `Annotated`:

**server.py:50** becomes:
```python
from pydantic import Field
from typing import Annotated

async def submit_to_peer_agent(
    question: str,
    workspace: Annotated[str, Field(description="Absolute path to an existing directory. The peer agent's live working tree — edits land here and appear in git diff. Never use a workspace holding production credentials.")],
    ctx: Context,
    summary: Annotated[str | None, Field(
        description="Optional one-line task summary (ADR-0086). When the prompt is offloaded to a brief file, this is prepended to the pointer prompt for visibility in logs. Capped at 600 encoded characters; longer summaries are truncated with '...'.",
        examples=["Rename foo to bar across the repo", "Add pagination to user list API"]
    )] = None
) -> dict:
```

**Result**:
- JSON schema gains `description` and `examples` fields for each parameter
- LLM client sees semantic purpose and usage constraints before invoking the tool
- Docstring in function body can remain as user-facing documentation

**Trade-off**: Requires maintaining descriptions in two places (function signature + docstring), but this is standard Pydantic practice.

**Implementation effort**: < 15 minutes; one file edit.

---

### B. **Add Validation with Actionable Error Message** (Medium effort, high clarity)

In `bridge.py:Bridge.submit()`, add explicit pre-validation that catches missing/invalid workspace and raises a custom exception with a guide:

**bridge.py** (new validation in `submit()` before calling `_validate()`):
```python
async def submit(self, question: str, workspace: str | None, summary: str | None) -> dict:
    if workspace is None or not workspace.strip():
        raise ValueError(
            "submit_to_peer_agent requires 'workspace' as a tool argument (not in the question text).\n"
            "workspace must be an absolute path to an existing directory on the delegate's filesystem.\n"
            "Example: submit_to_peer_agent(question='...' , workspace='/Users/you/project')"
        )
    if not os.path.isdir(workspace):
        raise ValueError(f"workspace must be an existing directory; got: {workspace}")
    ...
```

**Result**:
- Caller gets a human-readable, actionable error message
- The error explains the distinction (tool argument vs. question text)
- Includes an example

**Trade-off**: Does not prevent Pydantic validation from firing first (MCP framework validates before calling the tool function). Server-side validation is defensive but happens after schema rejection.

**Implementation effort**: ~30 minutes (validation logic, tests, error message refinement).

---

### C. **Strengthen SKILL.md Delegation Mechanics** (Low effort, moderate impact)

**skills/peer-agent/SKILL.md:41** (item 1 under "Delegation mechanics"), edit to make explicit:

```markdown
1. **Resolve and pass the workspace**: the directory the task is about. 
   Pass the workspace path as the **`workspace` argument** to `submit_to_peer_agent`; 
   do not include it in the question text. It is cline's live working tree — edits land there 
   and show up in `git diff`. Never delegate a workspace holding production credentials: 
   the peer's reads inside it are unconstrained.
```

**Result**:
- Future callers and LLMs reading the injected skill see explicit guidance
- Reduces ambiguity in "resolve the workspace" phrasing

**Trade-off**: Only affects new sessions/calls; existing callers rely on schema alone.

**Implementation effort**: < 5 minutes; one paragraph edit.

---

### D. **Tool Rename or Signature Rethink** (High effort, low ROI)

Alternative tool signatures considered:

- **`submit_with_workspace(question, workspace, ...)`**: Less ambiguity, but the current name is already public
- **Single `config: {workspace, question}` object**: Reduces positional confusion, but breaks backward compatibility
- **Default workspace to cwd**: Dangerous—cwd might be random (agent process state) rather than the intended target repo

**Assessment**: Not recommended. Breaking changes outweigh marginal clarity gain.

---

## Recommendations (Ranked)

### 1. **Enrich Schema Descriptions (Mitigation A)** — Priority: HIGH
   - **Why**: Fixes the root cause (missing `description` in JSON schema)
   - **Effort**: Minimal (one function signature edit, duplicated docstring → Annotated Field)
   - **Impact**: LLM client sees full parameter semantics before invoking the tool
   - **Implementation**: Edit server.py:50 to add `Annotated[..., Field(description="...")]` for `workspace` and `summary`
   - **Follow-up**: Update any generated SDK stubs or documentation to reflect the new descriptions

### 2. **Strengthen SKILL.md Wording (Mitigation C)** — Priority: HIGH
   - **Why**: Clarifies delegation mechanics for new calls and injected ruleset
   - **Effort**: Trivial (5-minute wording change)
   - **Impact**: Reduces ambiguity for LLMs and human readers of injected context
   - **Implementation**: Edit skills/peer-agent/SKILL.md:41 to explicitly state "pass workspace as the `workspace` argument"
   - **Follow-up**: Review other delegation-mechanics examples for similar ambiguities

### 3. **Server-Side Validation (Mitigation B)** — Priority: MEDIUM
   - **Why**: Defense-in-depth; catches missing workspace before processing
   - **Effort**: ~30 minutes (validation logic + tests)
   - **Impact**: Better user experience if Pydantic validation is circumvented or schema is missed
   - **Trade-off**: Does not prevent schema validation from firing first
   - **Implementation**: Add explicit checks in `bridge.py:Bridge.submit()` before `_validate()`
   - **Follow-up**: Document in ADR-0068 (Orchestration) or create new ADR on validation strategy

### 4. **Document in ADR** — Priority: MEDIUM
   - **Why**: Captures the design decision for future maintainers
   - **Effort**: ~1 hour (new ADR or amendment to ADR-0068)
   - **Content**: Explain the schema/description gap, recommended field annotations, and validation philosophy
   - **Implementation**: Create `docs/adr/0087-tool-parameter-descriptions-and-validation.md` or amend ADR-0068

---

## Summary

The root cause of omitted `workspace` parameter errors is **absent `description` in the JSON schema** (`properties.workspace` lacks a description field). The MCP Python SDK generates schemas from type hints via Pydantic, but per-parameter docstrings in the function's "Args:" section are not extracted into the schema. The semantic necessity ("required, an existing directory") lives only in prose (function docstring and SKILL.md), not in the schema the LLM client consults.

**Most effective mitigations** are:
1. Add `Annotated[str, Field(description="...")]` to the workspace parameter (and summary) in server.py:50
2. Clarify SKILL.md:41 to explicitly say "pass workspace as the `workspace` argument"

Both are low-effort, high-clarity improvements that align with MCP SDK conventions and LLM best practices (structured schemas with per-parameter descriptions).
