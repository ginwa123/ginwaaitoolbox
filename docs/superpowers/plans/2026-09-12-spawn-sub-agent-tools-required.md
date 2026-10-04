# Spawn Sub-Agent Tools-Required + Worktree Guidance Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `spawn_sub_agent.tools` a required explicit allowlist (no omit, no `all`, no empty) and document the worktree pattern (explorer shares cwd, writer gets own worktree by explicit instruction).

**Architecture:** Parse-time enforcement in `src/modules/agent/tools/spawn_sub_agent.zig` (`parseSubAgentsFromValue` returns `MissingSubAgentTools` / `EmptySubAgentTools` / rejects `"all"`); exec simplification in `src/agentic_loop/tools_exec_spawn_sub_agent.zig` (always build CSV from required list, drop the `""` fallback); prompt updates in the tool description + `spawn_sub_agent_tool_system_prompt` (+ `appendSubAgentsListing` footer if needed) to teach explorer-vs-writer + worktree-then-summarize-or-push.

**Tech Stack:** Zig 0.16 (`std.json`, `std.ArrayList`), `allowlistFilter` CSV semantics, python functional harness (`tests/functional/harness.py`, never live `curl` on port 8081).

## Global Constraints

- DONT KILL PORT 8081 server; functional tests use harness ports 8080..8199 excl 8081.
- No `// NEW (plan: ...)` comment tags; explain *why*, not *when*.
- `tools` is REQUIRED per sub-agent: missing field, empty array, or any element `"all"` (case-sensitive, trimmed) is a parse error. No `"all"` passthrough, no omit-means-all.
- Explorer-code (read-only code exploration: `read_file`, `glob`, `search`, `web_search`) shares parent cwd, NO new worktree needed — shares parent cwd. Writer/editor (any `write_file`, `text_replace`, `remove_file`, `bash` that writes, `set_git_worktree`) MUST be told explicitly in `instruction` to create its own worktree via `set_git_worktree`, work there, then return a summary and optionally push — and `set_git_worktree` MUST be in its explicit `tools` list.
- Existing tests that omit `tools` must be updated in the same commit (they become invalid input).
- Verify with Zig unit tests + isolated functional harness test (wire payload), never `nohup pabrik + curl`.

## Steps

### Task 1 — Failing parse tests for required tools

- [ ] In `src/modules/agent/tools/spawn_sub_agent.zig` add failing tests:
  - `{"sub_agents":[{"agent_name":"a","instruction":"do x"}]}` → `error.MissingSubAgentTools`.
  - `{"sub_agents":[{"agent_name":"a","instruction":"do x","tools":[]}]}` → `error.EmptySubAgentTools`.
  - `{"sub_agents":[{"agent_name":"a","instruction":"do x","tools":["all"]}]}` → `error.AllToolsNotAllowed` (or reuse one error; pick one name and use everywhere).
  - `{"sub_agents":[{"agent_name":"a","instruction":"do x","tools":["read_file","glob"]}]}` → parses, `tools.len == 2`.
- [ ] Run: `timeout 60 zig test src/modules/agent/tools/spawn_sub_agent.zig 2>&1 | head -n 50` — confirm the 3 new negative tests fail.
- [ ] Commit: no (tests failing, do not commit yet).

### Task 2 — Make `tools` required in parse

- [ ] Change `SubAgentInput.tools` from `?[]const []const u8 = null` to `[]const []const u8` (required, no default).
- [ ] Rewrite the `// Parse optional "tools" field` block in `parseSubAgentsFromValue` to:
  - `agent_obj.get("tools") orelse return error.MissingSubAgentTools;`
  - require `.array`, else `error.InvalidSubAgentsFormat` (or a dedicated `InvalidToolsFormat`).
  - empty array → `error.EmptySubAgentTools`.
  - per-element must be `.string` non-empty; trimmed `"all"` → `error.AllToolsNotAllowed`.
  - dupe names as today.
- [ ] Adjust `deinit` (no longer `if (sa.tools)` — always free list + strings).
- [ ] Adjust `SubAgentThreadArgs.tools` plumbing if needed (keep `?` there only if exec still supports it, else make required too — prefer required end-to-end).
- [ ] Run new + old parse tests; update every old test JSON in this file that omits `tools` to include `"tools":["read_file"]` (or similar) so valid-input tests stay valid.
- [ ] Run: `timeout 60 zig test src/modules/agent/tools/spawn_sub_agent.zig 2>&1 | head -n 30`.
- [ ] Commit.

### Task 3 — Exec: drop the omit-means-all fallback

- [ ] In `src/agentic_loop/tools_exec_spawn_sub_agent.zig`, replace `.allowed_tools = if (args_ptr.tools) ... else ""` with unconditional CSV join from `args_ptr.tools` (required). No `""`, no `"all"` passthrough.
- [ ] Keep unknown-tool behaviour as-is (`allowlistFilter` ignores unknown names) — do NOT add new resolution; the description already says unknown tools error (verify where that error comes from; if it is actually ignore, fix the doc line to say "unknown names are ignored").
- [ ] Add/adjust static-contract test if needed (e.g. assert source contains `MissingSubAgentTools` handling or no `else ""` fallback).
- [ ] Run: `timeout 120 zig test src/agentic_loop/tools_exec_spawn_sub_agent.zig 2>&1 | head -n 30`.
- [ ] Commit.

### Task 4 — Tool description + system prompt (explicit tools + worktree rule)

- [ ] Rewrite in `src/modules/agent/tools/spawn_sub_agent.zig`:
  - `TOOL SELECTION GUIDE` → `TOOLS (REQUIRED, explicit)`:
    - `tools` is REQUIRED per sub-agent, non-empty array of exact tool names.
    - No omit, no `[]`, no `"all"`. Example: `"tools": ["read_file", "glob", "search"]`.
    - How to pick: explorer → read-only set; writer → include `set_git_worktree` + write set.
    - `json_input` SCHEMA comment: `"tools": ["read_file", "glob"], // REQUIRED. Non-empty. No "all".`
  - `spawn_sub_agent_tool_system_prompt`: add 2 short rules:
    - `tools` required/explicit; never `"all"`.
    - Worktree: explorer (read-only) shares cwd, no worktree. Writer/editor MUST be told explicitly in `instruction` to call `set_git_worktree` first (path `.worktree/worktrees_agent_<randomname>`), work there, then return a summary of changed files and optionally push. Include `set_git_worktree` in its `tools`.
  - Good/bad instruction examples: add worktree example for writer (`"First call set_git_worktree with path ... , do the edit there, then summarize changed files and push status."`) and explorer example (no worktree).
- [ ] Optionally append one line to `appendSubAgentsListing` footer in `src/agentic_loop/prompts_build_messages_for_agent_prompt.zig` pointing at the worktree rule (only if the tool-description update alone is not visible enough; prefer tool description only — YAGNI).
- [ ] Run: `timeout 120 zig build test 2>&1 | tail -n 30` (or targeted `zig test` on touched files).
- [ ] Commit.

### Task 5 — Wire verification (functional harness, not live curl)

- [ ] Add `tests/functional/spawn_sub_agent_tools_required_test.py` (harness boots fresh binary on isolated HOME/port):
  - missing `tools` → tool result `<error>` / `InvalidArguments` (assert the envelope, not just unit error).
  - `"tools": ["all"]` → same error path.
  - `"tools": ["read_file"]` explorer with read-only instruction → success, no worktree created.
  - writer with `"tools": ["read_file","write_file","text_replace","set_git_worktree"]` + explicit worktree instruction → success and worktree path exists (or summary mentions worktree).
- [ ] Run: `timeout 300 python -m pytest tests/functional/spawn_sub_agent_tools_required_test.py -x -q 2>&1 | tail -n 30`.
- [ ] Commit.

## Verification

- [ ] Plan saved here (`docs/superpowers/plans/2026-09-12-spawn-sub-agent-tools-required.md`).
- [ ] `zig test` on `spawn_sub_agent.zig` + `tools_exec_spawn_sub_agent.zig` green.
- [ ] Functional harness test green (4 cases above).
- [ ] No `omit → all` path remains (`search(pattern="else \"\"", path="src/agentic_loop/tools_exec_spawn_sub_agent.zig")` empty).
- [ ] User reviewed plan before execution (card stays in `in_review_planning` until approved).
