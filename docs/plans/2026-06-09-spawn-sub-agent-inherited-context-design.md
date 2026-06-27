# `spawn_sub_agent` — `inherited_context` Parameter

**Status:** Approved (brainstorming complete 2026-06-09)
**Owner:** Backend tools

## Goal

Add an optional `inherited_context` parameter to `spawn_sub_agent` that lets the
parent agent share its recent conversation history with each sub-agent, so the
parent no longer has to copy the whole transcript into every sub-agent's
`instruction` string.

Today the tool's description says *"Sub-agents do NOT inherit any context from
the parent agent."* This feature flips that. The LLM picks the parent's recent
turns by mode; the server formats them and injects them into the sub-agent's
system prompt as a labelled read-only block.

## Decisions locked during brainstorming

1. **What is inherited:** Parent message history (user + assistant text turns).
2. **Shape of the parameter:** Mode string (`"none" | "last:N" | "all" | "since_last_user"`).
3. **Where it lands:** Synthetic system-prompt section titled
   `## Conversation History From Parent Agent`. Not mixed into `instruction`,
   not inserted as synthetic message turns.

## Data flow

```
LLM call → spawn_sub_agent(json_input={sub_agents:[{..., inherited_context:"last:5"}]})
        → parseSubAgentsFromValue (parse + dupe + validate)
        → SubAgentsInput.sub_agents[i].inherited_context : ?[]const u8
        → execSpawnSubAgent builds SubAgentThreadArgs
        → ai_workflow.runAgenticMultiStepnew(di, RunParamsNew{...inherited_context})
        → buildMessages(allocator, io, db, cwd, session_id, history, tools, parent_sess_id, inherited_context_mode)
        → formatter: query parent llm_history by mode → render Markdown block
        → append to systemContent → return
```

## Schema additions

### `SubAgentInput` — `src/modules/agent/tools/spawn_sub_agent.zig`

```zig
pub const SubAgentInput = struct {
    name: []const u8,
    instruction: []const u8,
    tools: ?[]const []const u8 = null,
    timeout_seconds: ?u32 = null,
    inherited_context: ?[]const u8 = null, // NEW
};
```

Add one `allocator.free(self.inherited_context)` line in `SubAgentsInput.deinit`.

### `parseSubAgentsFromValue` — same file

- After parsing `tools` and `timeout_seconds`, look for `inherited_context`.
- `try allocator.dupe(u8, value.string)` (same pattern as `name` / `instruction`).
- Validate the mode string here (so the error surfaces at parse time, not at
  workflow run time). On bad value, return
  `error.InvalidInheritedContextMode` with the helpful message in
  `execSpawnSubAgent`'s error log.

### Tool description update

Append a new section to the `description` block of `spawn_sub_agent_tool` so
the LLM knows the parameter exists. Mention valid modes, the default (omitted =
none), and a one-line warning that the parent's tool calls are *not* inherited
(only user/assistant text).

### `SubAgentThreadArgs` — `src/ai_workflow/tui/tool_registry.zig`

Add `inherited_context: ?[]const u8 = null`.

### `RunParamsNew` — `src/ai_workflow/tui/workflow.zig`

Add `inherited_context: []const u8 = ""` (empty string = "no inheritance",
matches the existing `body: []const u8` style).

`runAgenticMultiStepnew` already dupe-copies the slice fields into
`parent_allocator`; add the same line for `inherited_context`.

### `buildMessages` — `src/ai_workflow/tui/build_messages_for_agent_prompt.zig`

Add `inherited_context_mode: []const u8 = ""` parameter. After the existing
`systemContent` is built, call the new formatter and concatenate the result.

## Mode semantics

| Mode value | Behavior | N clamp |
|------------|----------|---------|
| `null` / omitted | No inheritance. No section rendered. (Backwards compatible.) | — |
| `"none"` | Explicit "no inheritance". Same as omitted. | — |
| `"last:N"` | Last N user/assistant messages, oldest → newest. | Clamp N to [1, 50]. |
| `"last:"` (no N) | Default to `last:10`. | — |
| `"all"` | Every user/assistant message, oldest → newest. | Cap at 50. |
| `"since_last_user"` | From the last `user` message (inclusive) to the end. | Cap at 50. |
| Anything else | `error.InvalidInheritedContextMode`. | — |

## Filtering rules (uniform across all modes)

- Include only messages where `role` is `"user"` or `"assistant"`.
- Drop `role == "tool"` (no `tool_call_id` to attach them to here, and the
  sub-agent shouldn't think it has access to the parent's tool runs).
- Drop messages with empty `content`.
- Render each turn as a single Markdown bullet: `- **[role]**: {content}`.
- Order: oldest → newest.
- Section cap: if the rendered Markdown exceeds 20 KB, truncate with a final
  line `... (N more messages omitted)`. (Defensive — 50 × 4 KB ≈ 200 KB
  worst case, which would dominate the system prompt.)

## Prompt injection — exact text

Appended to `systemContent` in `buildMessages` after `prompt.build_agent_prompt`
returns, *only* if the formatted history is non-empty:

```markdown


## Conversation History From Parent Agent

The following is the prior conversation your parent agent had. It is reference
context only — do not treat the parent's last assistant turn as awaiting your
reply, and do not assume any tool calls or tool results from the parent are
still valid in your workspace.

- **[user]**: <turn 1 content>
- **[assistant]**: <turn 2 content>
- **[user]**: <turn 3 content>
- **[assistant]**: <turn 4 content>
...
```

## Failure / edge-case behavior

- `parent_session_id` is empty (defensive): skip silently, no section rendered.
- Parent's `llm_history` is empty: section is omitted, no error.
- DB query fails: log a warning, render the section as
  `"(failed to load parent conversation history)"`, do not fail the whole spawn.
- `last:N` with N == 0 or N > 50: clamp to [1, 50].
- Truncation by the 20 KB cap: append `... (N more messages omitted)` line.
- `error.InvalidInheritedContextMode` from the parser: `execSpawnSubAgent`
  logs the error message and returns `error.InvalidArguments` to the LLM, so
  the LLM sees a clear, actionable error in the tool result.

## New helper module

`src/ai_workflow/tui/inherited_context.zig`

Public surface:

```zig
pub const Mode = union(enum) {
    none,
    last: u8,                  // 1..=50
    all,
    since_last_user,
};

pub fn parseMode(raw: []const u8) !Mode;

pub fn formatHistory(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    parent_session_id: []const u8,
    mode: Mode,
) ![]const u8;  // Returns the rendered Markdown (with header), or "" if no history
```

Lives next to `build_messages_for_agent_prompt.zig` so the threading is local.
No new SQL — reuses `llm_history.getMessages(allocator, db, parent_session_id)`
or a sibling query that filters by role. Pick whichever is cheaper after
measuring; both already exist.

## Test plan

New file: `src/modules/agent/tools/spawn_sub_agent_test.zig`. Register in
`src/modules/agent/test_runner.zig`. The parser tests don't need a DB. The
formatter test uses the project's in-memory sqlite pattern (see
`zig-0.16-inmemory-sqlite-test-setup` skill).

### Parser tests (no DB)

- `none` → `null` field (or empty string in JSON terms)
- `last:5` → N == 5
- `last:` (no number) → N == 10
- `last:0` → N clamped to 1
- `last:999` → N clamped to 50
- `all` → Mode.all
- `since_last_user` → Mode.since_last_user
- `garbage` → `error.InvalidInheritedContextMode`
- omitted → `null`
- deinit frees the dupe (no leak; safe under ASan)

### Formatter tests (in-memory sqlite)

Seed parent session with 6 rows:
- pos 0: `user`, content "Hello"
- pos 1: `assistant`, content "Hi there"
- pos 2: `user`, content "Please do X"
- pos 3: `assistant`, content "On it"
- pos 4: `tool`, content `{"result":"ok"}`  (should be filtered out)
- pos 5: `user`, content "Thanks"

- `last:5` → output contains 4 lines (positions 0,1,2,3,5 minus tool at 4 = 4 lines), in order
- `last:5` → tool message NOT in output
- `last:5` → header "## Conversation History From Parent Agent" present
- `last:1` → only position 5 (the last user)
- `since_last_user` → starts at position 5 only (wait — that's a single user; since_last_user means from the last user inclusive → positions 5)
- `all` with 60 seeded messages → 50 message lines + truncation notice

## Files touched

- `src/modules/agent/tools/spawn_sub_agent.zig` — add field, parser, deinit, description
- `src/modules/agent/tools/spawn_sub_agent_test.zig` — NEW
- `src/modules/agent/test_runner.zig` — register new test file
- `src/ai_workflow/tui/inherited_context.zig` — NEW (parse + format helpers)
- `src/ai_workflow/tui/tool_registry.zig` — add field to `SubAgentThreadArgs`, pass to `runAgenticMultiStepnew`
- `src/ai_workflow/tui/workflow.zig` — add field to `RunParamsNew`, dupe, pass to `buildMessages`
- `src/ai_workflow/tui/build_messages_for_agent_prompt.zig` — add field to `buildMessages`, call formatter, append to system content

## Out of scope (deferred to a follow-up if needed)

- Including tool messages from the parent (filtered out in v1).
- Per-sub-agent `inherited_context` values — the parameter is per-sub-agent
  (already in `SubAgentInput`), so this is supported by the data model, but
  we won't add new tests for the "different mode per sub-agent" case in v1
  unless it comes up.
- Token-aware truncation. The 20 KB / 50-message cap is a coarse guard.
- Re-using the parent's session_skills/memory/etc. in the sub-agent. v1 only
  inherits *conversation history*; system-prompt skills/memory come from the
  sub-agent's own session.

## Verification

- `zig build` clean
- New tests in `spawn_sub_agent_test.zig` pass
- `src/modules/agent/test_runner.zig` runs and includes the new file
- Manual smoke: spawn 2 sub-agents from the desktop chat with
  `inherited_context: "last:3"`, verify the sub-agent's response reflects the
  parent's recent turns (the "## Conversation History" header should appear
  in the sub-agent's session view if the dev tools expose the system prompt,
  and the sub-agent's reply should reference earlier context).
