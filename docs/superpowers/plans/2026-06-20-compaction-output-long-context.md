# Better Compaction Output for Long-Context Sessions

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When a session is compacted, the AI agent retains effective long-context capability by (a) receiving a richer `<compact_messages>` envelope with metadata + a `<message_index>` listing every dropped message id+role+timestamp, and (b) gaining a new `read_compacted_messages` tool that lets the agent fetch the full body of any dropped message on demand.

**Architecture:** Two parallel additions that work together. (1) At compaction time, `compactMessageInMemoryNew` captures a `message_index` of the soon-to-be-marked-not-for-llm messages (their `id`, `role`, `created_at`, and a short preview of `response_content`) and embeds it in the `<compact_messages>` envelope along with session metadata (timestamp, original count, token count, model, session id). (2) A new agent tool `read_compacted_messages` queries the same `llm_history` table but bypasses the `is_feed_to_llm=1` filter that `getMessages` applies, returning either just the index (default) or the full bodies of explicit `message_ids`. The two together give the agent both an "address book" inside the compacted summary and a way to actually open those addresses.

**Tech Stack:** Zig 0.16 (per `~/.config/nalar/memories/zig-*`), `std.Io.Threaded`, `SqliteBackend` from `nalarcore.sqlite`, the existing `AgentTool` schema from `src/modules/agent/tools/schemas.zig`, the standardized `<tool>` envelope from `wrapToolOutput`, and the project's `build_messages_for_agent_prompt.zig` dynamic tool listing.

---

## Context

### Current state (read this first)

`src/ai_workflow/tui/workflow.zig` has three compaction functions (verified by reading lines 420-1067):

1. **`maybeCompactMessagesNew` (lines 749-784)** — gates on `isDoCompact(total_tokens, model_token_count)`, calls `callCompactAgentNew` + `compactMessageInMemoryNew`. **Already changed in user's uncommitted diff** to return `bool` (`true` = compacted, `false` = no-op) instead of a fresh `ArrayList`, and to mutate `*std.ArrayList(AgentMessage)` in place. The agent loop calls it once per LLM step and `continue`s when `true` is returned (workflow.zig:420-423).

2. **`callCompactAgentNew` (lines 791-970)** — builds the prompt sent to the **CompactionAgent** (an LLM call). **Already partially improved in user's uncommitted diff**: messages are now labeled by role (`[user]:`, `[assistant]:`, `[tool]:`) and assistant tool calls surface as `[tool_call]: name(args)`. The prompt template at lines 854-915 still asks for a structured output with sections GOAL / CURRENT STATE / TECH STACK / FILES MODIFIED / KEY DISCOVERIES / FAILED ATTEMPTS / OPEN ISSUES / ASSUMPTIONS MADE / NEXT ACTION / AFTER THAT / DO NOT. The CompactionAgent's system prompt lives at `src/modules/agent/prompts/special.zig:5` (`pub const CompactionAgent`).

3. **`compactMessageInMemoryNew` (lines 984-1067)** — wraps the compactor's output in `<compact_messages>...</compact_messages>` (lines 1001-1007), saves it to the DB with `is_feed_to_llm=1` + `role="user"`, then rebuilds the in-memory `messages` list as `[system, compact_summary]`. The 50+ dropped messages are silently marked `is_feed_to_llm=0` via `llm_history.markMessageNotForLlmRun` (workflow.zig:999; implementation at llm_history.zig:12-19) and become invisible to every future LLM call.

### What's missing (the gap this plan closes)

The compaction envelope is **structurally lossy**:

- No metadata: when, how many, which model, which session.
- No `message_index`: the agent has no list of dropped message ids, so it cannot reference specific old messages.
- No way to read old messages: `llm_history.getMessages` (llm_history.zig:1076-1160) hard-filters on `is_feed_to_llm = 1 OR is_feed_to_llm IS NULL` (line 1109). After compaction, the only way to recover a dropped message is a direct DB query — and no tool exposes that.

### In-flight work to respect (do NOT undo)

The user has uncommitted changes on `main` (per `git diff --stat HEAD`):

```
modified:   src/ai_workflow/tui/http_handlers/http_response.zig     |  8 +++
modified:   src/ai_workflow/tui/http_handlers/tasks_list.zig        |  2 +
modified:   src/ai_workflow/tui/http_handlers/workspaces_list.zig   |  4 +-
modified:   src/ai_workflow/tui/workflow.zig                        | 58 ++++++++++++----
```

The workflow.zig changes add role labels and tool_call surfacing to `callCompactAgentNew` (the input to the compactor) and refactor `maybeCompactMessagesNew` to mutate the messages list in place. **All of those changes are compatible with this plan** — they improve the compactor's *input*, while this plan improves the compactor's *output* + adds a lookup tool. **Start the executor's worktree from the user's current `main` working tree state**, not from `origin/main` (`git diff HEAD` is non-empty; `git log origin/main..HEAD` is empty). If a worktree is created, copy or merge the uncommitted changes first.

The executor should `git status` at the start of every chunk to confirm the uncommitted workflow.zig changes are still present, and **must NOT `git checkout` or `git restore` workflow.zig** mid-task — see `multi-agent-file-reverts.md` for the warning.

### Conventions to follow

- Always alias tables in SELECTs (`h.`, `s.`, `t.`); see `nalar-sql-alias-tables.md`.
- HTTP handlers use `parseFromSliceLeaky` + `valueAlloc` for user-provided text; see `nalar-http-handler-thin-wrapper-pattern.md`.
- TUI handlers (not HTTP) do NOT use that pattern — they go through `tool_registry.execX` + `wrapToolOutput`.
- New tools: copy the shape of `src/modules/agent/tools/set_git_worktree.zig` (Input struct, `AgentTool` schema, `execute_xxx_to_string`, `toXmlSuccess`/`toXmlError`).
- Tests: separate `_test.zig` files, registered in `src/ai_workflow/tui/test_runner.zig`.
- Run tests on port 8080, NEVER 8081 (the project's mandatory rule; another `nalar` instance is always on 8081).
- Verify the install build too (`zig build install:linux:system`), not just `zig build test` — see `zig-0.16-t-to-t-param-becomes-const.md` for the lazy-analysis trap.

---

## File Structure

### Files to CREATE

| File | Purpose | Lines (est) |
|---|---|---|
| `src/modules/agent/tools/read_compacted_messages.zig` | New tool: query `llm_history` for messages with `is_feed_to_llm=0` | ~250 |
| `src/modules/agent/tools/read_compacted_messages_test.zig` | Unit tests for the new tool (in-memory SQLite) | ~150 |
| `src/ai_workflow/tui/llm_history_compacted_messages_test.zig` | Unit tests for the new query function | ~120 |
| `src/ai_workflow/tui/workflow_compaction_envelope_test.zig` | Unit tests for the envelope builder | ~120 |

### Files to MODIFY

| File | What changes | Why |
|---|---|---|
| `src/ai_workflow/tui/llm_history.zig` | Add `pub fn getCompactedMessages(allocator, db, session_id, opts)` — sibling to `getMessages` (line 1076) but skips the `is_feed_to_llm=1` filter. | Query layer for the new tool and for the envelope builder. |
| `src/ai_workflow/tui/workflow.zig` | (1) Refactor `compactMessageInMemoryNew` (line 984) to build a richer envelope: metadata header + `<message_index>` listing each dropped message. (2) Capture dropped-message metadata before `markMessageNotForLlmRun` is called. | Replace the thin `<compact_messages>` wrapper with a structured envelope. |
| `src/ai_workflow/tui/tool_registry.zig` | (1) Add `execReadCompactedMessages` near `execListMemory` (line 312). (2) Add entry to `UNIFIED_TOOL_REGISTRY` (line 1478). (3) Add to `allAgentTools` (line 1535). (4) Add module import near line 14-44. | Make the new tool available to the main agent. |
| `src/ai_workflow/tui/prompts/special.zig` | Update the `CompactionAgent` system prompt to tell the compactor that the agent has a `read_compacted_messages` tool available and that it should bias its output toward "summary + index-friendly headings" rather than "narrative". | Make the compactor's output *useful* with the new tool — without this hint, summaries will still over-narrate and the index will be the only useful artifact. |
| `src/ai_workflow/tui/test_runner.zig` | Add 4 `_ = @import(...)` lines (line ~3-44) for the new test files. | Register the new tests. |

### Files NOT touched

- Frontend (`src/apps/desktop/src/`) — the chat UI does not need any changes for v1. The new `<message_index>` is rendered by the existing `<compact_messages>` handler, and the tool is exercised through the agent's normal tool-call loop. A future UX improvement (collapse/expand on click) is out of scope.
- Migrations (`src/ai_workflow/tui/migration.zig`) — no schema changes. The new query uses existing columns.

---

## Pre-conditions

Before starting any task in any chunk:

- [ ] Confirm the user's uncommitted changes are present: `git -C /home/ginwa/agentic_coding_zig/ginwaaitoolbox diff --stat HEAD` shows `workflow.zig` modified. If not, abort and ask the user.
- [ ] Verify the baseline test count: `cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox && timeout 180 zig build test --summary all 2>&1 | tail -n 5`. Expected: `test success` with the current test count. Record the exact count — every chunk should add to it.
- [ ] Verify the baseline install build: `timeout 180 zig build install:linux:system 2>&1 | tail -n 10`. Expected: `Build Summary: 4/6 steps succeeded` (the `cp` step fails harmlessly with permission denied on `/usr/local/bin/nalar`). Record the exact line count for the compile step.

If the baseline fails to build, abort and surface to the user. The user's uncommitted workflow.zig changes may have introduced a bug.

---
## Chunk 1: Compaction envelope + index builder

**Files:**
- Modify: `src/ai_workflow/tui/workflow.zig:984-1067` (compactMessageInMemoryNew)
- Create: `src/ai_workflow/tui/workflow_compaction_envelope_test.zig`
- Modify: `src/ai_workflow/tui/test_runner.zig` (register new test file)

**Goal:** After compaction, the stored `<compact_messages>` envelope contains a metadata header (timestamp, original count, model, session id) and a `<message_index>` listing each dropped message with its id, role, created_at, and a one-line preview. The compactor's existing summary content is preserved verbatim inside `<summary>...</summary>`.

### Task 1.1: Write the failing envelope test

**File:** `src/ai_workflow/tui/workflow_compaction_envelope_test.zig`

- [ ] **Step 1.1.1: Create the new test file**

```zig
const std = @import("std");
const testing = std.testing;
const workflow = @import("workflow.zig");
const agent = @import("nalarcore").agent;
const sqlite = @import("nalarcore").sqlite;
const llm_history = @import("llm_history.zig");
const logger = @import("nalarcore").logger;

/// Build a minimal in-memory SQLite DB with the tables that
/// compactMessageInMemoryNew touches: llm_history (for saveMessage +
/// markMessageNotForLlmRun) and sessions (for the cwd UPDATE).
/// Mirrors the test setup in src/ai_workflow/tui/llm_history_routines_test.zig.
fn setupDb() !struct {
    db: sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
} {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");

    // Minimal schema — exactly the columns saveMessage writes and
    // markMessageNotForLlmRun updates. ORDER matches the production
    // CREATE TABLE in src/ai_workflow/tui/migration.zig (latest rev).
    try db.exec(alloc,
        \\CREATE TABLE llm_history (
        \\  id TEXT PRIMARY KEY,
        \\  session_id TEXT NOT NULL,
        \\  model TEXT,
        \\  response_content TEXT,
        \\  finish_reason TEXT,
        \\  role TEXT,
        \\  tool_calls_json TEXT,
        \\  tool_call_id TEXT,
        \\  reasoning_content TEXT,
        \\  is_feed_to_llm INTEGER DEFAULT 1,
        \\  agent TEXT,
        \\  loop_index INTEGER DEFAULT 0,
        \\  temperature REAL DEFAULT 0.2,
        \\  is_thinking INTEGER DEFAULT 0,
        \\  created_at TEXT DEFAULT (datetime('now')),
        \\  parent_session_id TEXT,
        \\  parent_id TEXT,
        \\  prompt_tokens INTEGER DEFAULT 0,
        \\  completion_tokens INTEGER DEFAULT 0,
        \\  total_tokens INTEGER DEFAULT 0,
        \\  is_input INTEGER DEFAULT 0,
        \\  is_output INTEGER DEFAULT 0,
        \\  tool_name TEXT,
        \\  diffview_before TEXT,
        \\  diffview_after TEXT,
        \\  image_url TEXT
        \\)
    , &.{});
    try db.exec(alloc,
        \\CREATE TABLE sessions (
        \\  id TEXT PRIMARY KEY,
        \\  cwd TEXT,
        \\  name TEXT
        \\)
    , .{});

    return .{ .db = db, .threaded = threaded };
}

fn teardownDb(s: *const @TypeOf(setupDb() catch unreachable)) void {
    s.db.deinit();
    s.threaded.deinit();
}

/// Build a synthetic in-memory message list shaped like the agent's
/// real messages: [system, user-1, assistant-1, tool-result-1, user-2, assistant-2].
/// Uses allocator.dupe'd slices so compactMessageInMemoryNew can free
/// them safely after compaction.
fn buildMessages(allocator: std.mem.Allocator) !std.ArrayList(agent.AgentMessage) {
    var list: std.ArrayList(agent.AgentMessage) = .empty;
    try list.append(allocator, .{
        .role = .system,
        .content = try allocator.dupe(u8, "You are a coding agent."),
    });
    try list.append(allocator, .{
        .role = .user,
        .content = try allocator.dupe(u8, "Fix the login bug"),
    });
    try list.append(allocator, .{
        .role = .assistant,
        .content = try allocator.dupe(u8, "I'll investigate"),
    });
    try list.append(allocator, .{
        .role = .tool,
        .content = try allocator.dupe(u8, "tests pass: 42/42"),
        .tool_call_id = try allocator.dupe(u8, "tc_1"),
        .tool_name = try allocator.dupe(u8, "bash"),
    });
    try list.append(allocator, .{
        .role = .user,
        .content = try allocator.dupe(u8, "Now ship it"),
    });
    try list.append(allocator, .{
        .role = .assistant,
        .content = try allocator.dupe(u8, "Shipping."),
    });
    return list;
}

test "compactMessageInMemoryNew: envelope contains metadata header" {
    const s = try setupDb();
    defer teardownDb(&s);
    const alloc = testing.allocator;

    var messages = try buildMessages(alloc);
    defer messages.deinit(alloc);

    const lg = try logger.createTestLogger(alloc);
    defer lg.deinit();

    const compacted_xml =
        \\GOAL: fix login
        \\NEXT ACTION: ship it
    ;

    const new_messages = try workflow.compactMessageInMemoryNew(
        alloc,
        messages,
        compacted_xml,
        "sess_123",
        "gpt-4o",
        "/tmp",
        &s.db,
        s.threaded.io(),
        lg,
    );
    defer new_messages.deinit(alloc);

    try testing.expectEqual(@as(usize, 2), new_messages.items.len); // [system, compact_summary]
    const summary = new_messages.items[1].content.?;
    try testing.expect(std.mem.indexOf(u8, summary, "<compact_messages>") != null);
    try testing.expect(std.mem.indexOf(u8, summary, "</compact_messages>") != null);
    try testing.expect(std.mem.indexOf(u8, summary, "<session_id>sess_123</session_id>") != null);
    try testing.expect(std.mem.indexOf(u8, summary, "<model>gpt-4o</model>") != null);
    try testing.expect(std.mem.indexOf(u8, summary, "<original_count>6</original_count>") != null);
    // Compactor's summary text is preserved inside <summary>...</summary>
    try testing.expect(std.mem.indexOf(u8, summary, "<summary>") != null);
    try testing.expect(std.mem.indexOf(u8, summary, "GOAL: fix login") != null);
    try testing.expect(std.mem.indexOf(u8, summary, "NEXT ACTION: ship it") != null);
}

test "compactMessageInMemoryNew: message_index lists every dropped message with id, role, created_at" {
    const s = try setupDb();
    defer teardownDb(&s);
    const alloc = testing.allocator;

    var messages = try buildMessages(alloc);
    defer messages.deinit(alloc);

    const lg = try logger.createTestLogger(alloc);
    defer lg.deinit();

    const new_messages = try workflow.compactMessageInMemoryNew(
        alloc, messages, "summary text", "sess_abc", "gpt-4o", "/tmp",
        &s.db, s.threaded.io(), lg,
    );
    defer new_messages.deinit(alloc);

    const summary = new_messages.items[1].content.?;

    // <message_index> section must exist and contain one entry per dropped
    // message (everything except index 0 = the system prompt). The 6-msg
    // fixture drops 5 messages (indices 1..5).
    try testing.expect(std.mem.indexOf(u8, summary, "<message_index>") != null);
    try testing.expect(std.mem.indexOf(u8, summary, "</message_index>") != null);

    // Every non-system role from the fixture must appear in the index.
    try testing.expect(std.mem.indexOf(u8, summary, "<role>user</role>") != null);
    try testing.expect(std.mem.indexOf(u8, summary, "<role>assistant</role>") != null);
    try testing.expect(std.mem.indexOf(u8, summary, "<role>tool</role>") != null);

    // Each index entry must include a message id and a preview.
    // The compactor's job is to retrieve these BEFORE markMessageNotForLlmRun,
    // so they must be populated from the in-memory message list, not the DB.
    try testing.expect(std.mem.indexOf(u8, summary, "<id>adhoc_") != null);
    try testing.expect(std.mem.indexOf(u8, summary, "<preview>") != null);
}

test "compactMessageInMemoryNew: tool-role index entries include tool_call_id and tool_name" {
    // Regression: a tool-result message has both `tool_call_id` and
    // `tool_name`. The index must surface BOTH so the agent can match
    // the result back to the call (and to the tool that produced it).
    const s = try setupDb();
    defer teardownDb(&s);
    const alloc = testing.allocator;

    var messages = try buildMessages(alloc);
    defer messages.deinit(alloc);

    const lg = try logger.createTestLogger(alloc);
    defer lg.deinit();

    const new_messages = try workflow.compactMessageInMemoryNew(
        alloc, messages, "summary", "sess_xyz", "gpt-4o", "/tmp",
        &s.db, s.threaded.io(), lg,
    );
    defer new_messages.deinit(alloc);

    const summary = new_messages.items[1].content.?;
    try testing.expect(std.mem.indexOf(u8, summary, "<tool_call_id>tc_1</tool_call_id>") != null);
    try testing.expect(std.mem.indexOf(u8, summary, "<tool_name>bash</tool_name>") != null);
}

test "compactMessageInMemoryNew: existing short-circuit (total <= 4) returns messages unchanged" {
    const s = try setupDb();
    defer teardownDb(&s);
    const alloc = testing.allocator;

    var messages: std.ArrayList(agent.AgentMessage) = .empty;
    try messages.append(allocator, .{ .role = .system, .content = try alloc.dupe(u8, "sys") });
    try messages.append(allocator, .{ .role = .user, .content = try alloc.dupe(u8, "hi") });
    defer messages.deinit(alloc);

    const lg = try logger.createTestLogger(alloc);
    defer lg.deinit();

    const result = try workflow.compactMessageInMemoryNew(
        alloc, messages, "summary", "sess_1", "gpt-4o", "/tmp",
        &s.db, s.threaded.io(), lg,
    );
    defer result.deinit(alloc);

    try testing.expectEqual(@as(usize, 2), result.items.len); // unchanged
    try testing.expectEqualStrings("hi", result.items[1].content.?);
}
```

**Note:** Adjust `logger.createTestLogger` / `lg.deinit()` to whatever the project's actual logger-creation function is. Verify by reading `src/modules/logger/Logger.zig` or `src/modules/logger/logger_test.zig` for the correct constructor (the project pattern is documented in `~/.config/nalar/memories/zig-0.16-inmemory-sqlite-test-setup/SKILL.MD`).

- [ ] **Step 1.1.2: Register the test in `src/ai_workflow/tui/test_runner.zig`**

Add this line in alphabetical order, between `tool_registry_test.zig` and `http_handlers/...`:

```zig
_ = @import("workflow_compaction_envelope_test.zig");
```

- [ ] **Step 1.1.3: Run the test to verify it fails**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
timeout 180 zig build test --summary all 2>&1 | tail -n 30
```

Expected: compile error or test failure — the test references fields/sections that don't exist yet (`<session_id>`, `<original_count>`, `<message_index>`, `<id>`, `<preview>`, `<tool_call_id>`, `<tool_name>`, `<summary>`). The current envelope is just `<compact_messages>\n\n{compacted_xml}\n\n</compact_messages>` and only has `<compact_messages>` / `</compact_messages>` / the compactor's verbatim text.

### Task 1.2: Refactor `compactMessageInMemoryNew` to build the rich envelope

**File:** `src/ai_workflow/tui/workflow.zig:984-1067`

The current implementation (lines 1001-1007):

```zig
try summary.print(allocator, "<compact_messages>\n\n", .{});
try summary.print(allocator, "{s}", .{compacted_xml});
try summary.print(allocator, "\n\n</compact_messages>", .{});
const summary_content = try summary.toOwnedSlice(allocator);
```

Must be replaced with a structured envelope builder. **The key constraint:** the existing summary content from the compactor (`compacted_xml`) must be preserved verbatim — it is a stable contract with the compactor and any change to it could break consumers that parse it (the LLM sees this content verbatim on the next turn).

**Approach:** introduce a private helper `buildCompactionEnvelope(allocator, dropped_messages, session_id, model, compacted_xml)` that:

1. Builds the envelope from the in-memory `messages.items[1..]` slice (we have them right there and don't need to round-trip to the DB).

2. Writes the envelope:

```
<compact_messages>
  <metadata>
    <session_id>{session_id}</session_id>
    <model>{model}</model>
    <compacted_at>{RFC3339 now}</compacted_at>
    <original_count>{N}</original_count>
  </metadata>
  <message_index>
    <entry>
      <id>adhoc_{i}</id>
      <role>{role}</role>
      <preview>{first 100 chars of response_content, XML-escaped}</preview>
      <tool_call_id>{tool_call_id}</tool_call_id>  <!-- only for tool role -->
      <tool_name>{tool_name}</tool_name>            <!-- only for tool role -->
    </entry>
    ...
  </message_index>
  <summary>
    {compacted_xml verbatim}
  </summary>
</compact_messages>
```

3. The `<id>` for in-memory messages is `adhoc_{index}` since v1 doesn't have stable DB ids for in-flight assistant content. **Document this in the tool description** — the `read_compacted_messages` tool will only resolve DB ids, not `adhoc_*`. A future improvement could persist message ids to in-memory content (out of scope for this plan).

- [ ] **Step 1.2.1: Add the helper function**

Insert after `compactMessageInMemoryNew` (around line 1068):

```zig
/// Build the structured `<compact_messages>` envelope that replaces
/// the dropped messages after compaction. The envelope has three
/// sections: <metadata> (compaction event facts), <message_index>
/// (id+role+preview for every dropped message so the agent can
/// reference them later via read_compacted_messages), and <summary>
/// (the compactor's output, preserved verbatim).
///
/// `dropped_messages` is the slice of messages that will be marked
/// `is_feed_to_llm=0` — typically `messages.items[1..]` for the
/// compactMessageInMemoryNew caller. We capture their metadata HERE
/// (in memory) rather than re-querying the DB, because these messages
/// still have their `id`/`created_at`/`tool_call_id`/`tool_name`
/// fields available in the in-memory struct.
///
/// Caller owns the returned string and must free with `allocator.free`.
fn buildCompactionEnvelope(
    allocator: std.mem.Allocator,
    dropped_messages: []const agent.AgentMessage,
    session_id: []const u8,
    model: []const u8,
    compacted_xml: []const u8,
) ![]u8 {
    // The timestamp: use the same pattern other code in workflow.zig
    // uses for "now". If workflow.zig already imports std.Io.Clock,
    // use that; otherwise std.fmt.allocPrint on the unix epoch seconds.
    // Placeholder — fill in the actual pattern from the codebase.
    const now_iso = try allocator.dupe(u8, "TBD_TIMESTAMP");

    var env: std.ArrayList(u8) = .empty;
    defer env.deinit(allocator);

    try env.appendSlice(allocator, "<compact_messages>\n");

    // --- metadata header ---
    try env.print(allocator,
        \\  <metadata>
        \\    <session_id>{s}</session_id>
        \\    <model>{s}</model>
        \\    <compacted_at>{s}</compacted_at>
        \\    <original_count>{d}</original_count>
        \\  </metadata>
        \\
    , .{ session_id, model, now_iso, dropped_messages.len });

    // --- message_index ---
    try env.appendSlice(allocator, "  <message_index>\n");
    for (dropped_messages, 0..) |msg, i| {
        const msg_id = try std.fmt.allocPrint(allocator, "adhoc_{d}", .{i});
        defer allocator.free(msg_id);

        const role_str = msg.role.to_str();
        const preview = msg.content orelse "";
        const preview_trimmed = if (preview.len > 100) preview[0..100] else preview;
        const preview_escaped = try helpers.xml_escape(allocator, preview_trimmed);
        defer allocator.free(preview_escaped);

        try env.print(allocator,
            \\    <entry>
            \\      <id>{s}</id>
            \\      <role>{s}</role>
            \\
        , .{ msg_id, role_str });

        // For tool-result messages, surface tool_call_id + tool_name so the
        // agent can match results back to calls. For other roles, omit.
        if (msg.role == .tool) {
            const tcid = msg.tool_call_id orelse "";
            try env.print(allocator, "      <tool_call_id>{s}</tool_call_id>\n", .{tcid});
            const tname = msg.tool_name orelse "";
            try env.print(allocator, "      <tool_name>{s}</tool_name>\n", .{tname});
        }

        try env.print(allocator,
            \\      <preview>{s}</preview>
            \\    </entry>
            \\
        , .{preview_escaped});
    }
    try env.appendSlice(allocator, "  </message_index>\n");

    // --- summary (the compactor's output, verbatim) ---
    try env.print(allocator, "  <summary>\n{s}\n  </summary>\n", .{compacted_xml});

    try env.appendSlice(allocator, "</compact_messages>\n");
    return try env.toOwnedSlice(allocator);
}
```

**Helpers used:** `helpers.xml_escape` is already imported via `nalar_mod` in `tool_registry.zig` (line 45: `const xmlEscape = helpers.xml_escape;`) — import the same way in workflow.zig.

- [ ] **Step 1.2.2: Replace lines 1001-1007 in `compactMessageInMemoryNew`**

```zig
// BEFORE (existing lines 1001-1007):
try summary.print(allocator, "<compact_messages>\n\n", .{});
try summary.print(allocator, "{s}", .{compacted_xml});
try summary.print(allocator, "\n\n</compact_messages>", .{});
const summary_content = try summary.toOwnedSlice(allocator);

// AFTER:
const summary_content = try buildCompactionEnvelope(
    allocator,
    messages.items[1..],
    session_id,
    model,
    compacted_xml,
);
```

The `summary` ArrayList + the three `summary.print` lines are now dead — remove them entirely (and the `defer summary.deinit(allocator);` at line 1003).

- [ ] **Step 1.2.3: Run the test to verify it passes**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
timeout 180 zig build test --summary all 2>&1 | tail -n 5
```

Expected: `test success` with 4 new tests passing. The test count grows by exactly 4 from the baseline.

### Task 1.3: Verify the install build + commit

- [ ] **Step 1.3.1: Run the install target** (catches lazy-analysis bugs that `zig build test` misses; see `zig-0.16-t-to-t-param-becomes-const.md`)

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
timeout 180 zig build install:linux:system 2>&1 | tail -n 10
```

Expected: `Build Summary: 4/6 steps succeeded`. The compile-exe step must succeed with 0 errors.

- [ ] **Step 1.3.2: Commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
git add src/ai_workflow/tui/workflow.zig \
        src/ai_workflow/tui/workflow_compaction_envelope_test.zig \
        src/ai_workflow/tui/test_runner.zig
git commit -m "feat(compaction): enrich <compact_messages> envelope with metadata + message_index

The compaction output now has three sections instead of one:
- <metadata>: session_id, model, compacted_at, original_count
- <message_index>: id, role, preview for every dropped
  message (with tool_call_id + tool_name for tool-result entries)
- <summary>: the compactor's output, preserved verbatim

The compactor's existing structured output (GOAL/CURRENT STATE/etc.)
is unchanged — it now lives inside <summary>...</summary>.

Refs: docs/superpowers/plans/2026-06-20-compaction-output-long-context.md"
```

---
## Chunk 2: New query function `getCompactedMessages`

**Files:**
- Modify: `src/ai_workflow/tui/llm_history.zig` (add `getCompactedMessages` after `getMessages` at line ~1161)
- Create: `src/ai_workflow/tui/llm_history_compacted_messages_test.zig`
- Modify: `src/ai_workflow/tui/test_runner.zig`

**Goal:** Add a public query function that returns messages marked `is_feed_to_llm=0` for a session, with optional filters (by id, role, since, until, limit). This is the data layer the new `read_compacted_messages` tool will call into.

### Task 2.1: Write the failing query test

**File:** `src/ai_workflow/tui/llm_history_compacted_messages_test.zig`

- [ ] **Step 2.1.1: Create the test file**

```zig
const std = @import("std");
const testing = std.testing;
const llm_history = @import("llm_history.zig");
const sqlite = @import("nalarcore").sqlite;

fn setupDb() !struct {
    db: sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
} {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");

    try db.exec(alloc,
        \\CREATE TABLE llm_history (
        \\  id TEXT PRIMARY KEY,
        \\  session_id TEXT NOT NULL,
        \\  model TEXT,
        \\  response_content TEXT,
        \\  role TEXT,
        \\  tool_call_id TEXT,
        \\  tool_name TEXT,
        \\  is_feed_to_llm INTEGER DEFAULT 1,
        \\  agent TEXT,
        \\  created_at TEXT DEFAULT (datetime('now'))
        \\)
    , &.{});
    return .{ .db = db, .threaded = threaded };
}

fn teardownDb(s: *const @TypeOf(setupDb() catch unreachable)) void {
    s.db.deinit();
    s.threaded.deinit();
}

fn seedMessage(alloc: std.mem.Allocator, db: *sqlite.SqliteBackend, id: []const u8, sess: []const u8, role: []const u8, content: []const u8, is_feed: u8, created_at: []const u8) !void {
    const feed_str = if (is_feed == 1) "1" else "0";
    const sql =
        \\INSERT INTO llm_history (id, session_id, role, response_content, is_feed_to_llm, created_at)
        \\VALUES (?, ?, ?, ?, ?, ?)
    ;
    try db.exec(alloc, sql, &.{ id, sess, role, content, feed_str, created_at });
}

test "getCompactedMessages: returns only is_feed_to_llm=0 messages for session" {
    const s = try setupDb();
    defer teardownDb(&s);
    const alloc = testing.allocator;

    try seedMessage(alloc, &s.db, "h1", "sess_1", "user", "Fix bug", 1, "2025-01-01 00:00:00");
    try seedMessage(alloc, &s.db, "h2", "sess_1", "assistant", "OK", 1, "2025-01-01 00:01:00");
    try seedMessage(alloc, &s.db, "h3", "sess_1", "user", "More", 0, "2025-01-01 00:02:00");
    try seedMessage(alloc, &s.db, "h4", "sess_1", "assistant", "Done", 0, "2025-01-01 00:03:00");
    try seedMessage(alloc, &s.db, "h5", "sess_2", "user", "other session", 0, "2025-01-01 00:04:00");

    const results = try llm_history.getCompactedMessages(alloc, &s.db, "sess_1", .{});
    defer {
        for (results) |m| var copy = m; copy.deinit(alloc);
        alloc.free(results);
    }

    try testing.expectEqual(@as(usize, 2), results.len);
    try testing.expectEqualStrings("h3", results[0].id);
    try testing.expectEqualStrings("h4", results[1].id);
}

test "getCompactedMessages: respects limit" {
    const s = try setupDb();
    defer teardownDb(&s);
    const alloc = testing.allocator;
    var i: usize = 0;
    while (i < 30) : (i += 1) {
        var buf: [16]u8 = undefined;
        const id = try std.fmt.bufPrint(&buf, "h{d}", .{i});
        try seedMessage(alloc, &s.db, id, "sess_1", "user", "msg", 0, "2025-01-01 00:00:00");
    }
    const results = try llm_history.getCompactedMessages(alloc, &s.db, "sess_1", .{ .limit = 5 });
    defer {
        for (results) |m| var copy = m; copy.deinit(alloc);
        alloc.free(results);
    }
    try testing.expectEqual(@as(usize, 5), results.len);
}

test "getCompactedMessages: filters by message_ids when provided" {
    const s = try setupDb();
    defer teardownDb(&s);
    const alloc = testing.allocator;
    try seedMessage(alloc, &s.db, "h1", "sess_1", "user", "A", 0, "2025-01-01 00:00:00");
    try seedMessage(alloc, &s.db, "h2", "sess_1", "user", "B", 0, "2025-01-01 00:01:00");
    try seedMessage(alloc, &s.db, "h3", "sess_1", "user", "C", 0, "2025-01-01 00:02:00");

    const ids = [_][]const u8{ "h1", "h3" };
    const results = try llm_history.getCompactedMessages(alloc, &s.db, "sess_1", .{ .message_ids = &ids });
    defer {
        for (results) |m| var copy = m; copy.deinit(alloc);
        alloc.free(results);
    }
    try testing.expectEqual(@as(usize, 2), results.len);
    try testing.expectEqualStrings("h1", results[0].id);
    try testing.expectEqualStrings("h3", results[1].id);
}

test "getCompactedMessages: returns empty slice when session has no compacted messages" {
    const s = try setupDb();
    defer teardownDb(&s);
    const alloc = testing.allocator;
    try seedMessage(alloc, &s.db, "h1", "sess_1", "user", "active", 1, "2025-01-01 00:00:00");

    const results = try llm_history.getCompactedMessages(alloc, &s.db, "sess_1", .{});
    defer {
        for (results) |m| var copy = m; copy.deinit(alloc);
        alloc.free(results);
    }
    try testing.expectEqual(@as(usize, 0), results.len);
}
```

- [ ] **Step 2.1.2: Register the test in `src/ai_workflow/tui/test_runner.zig`**

Add (alphabetical, near `get_session_list_test.zig`):

```zig
_ = @import("llm_history_compacted_messages_test.zig");
```

- [ ] **Step 2.1.3: Run the test to verify it fails**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
timeout 180 zig build test --summary all 2>&1 | tail -n 10
```

Expected: compile error referencing `getCompactedMessages` (function does not exist yet).

### Task 2.2: Implement `getCompactedMessages`

**File:** `src/ai_workflow/tui/llm_history.zig` (insert after `getMessages` at line ~1161, before the existing section divider)

- [ ] **Step 2.2.1: Add the function**

```zig
// =============================================================================
// Compacted Messages Query (is_feed_to_llm = 0)
// =============================================================================

/// Options for filtering `getCompactedMessages`.
pub const CompactedMessagesOptions = struct {
    /// When non-null, only return messages whose id is in this list.
    /// Used by `read_compacted_messages(message_ids=[...])`.
    message_ids: ?[]const []const u8 = null,
    /// When non-null, only return messages with `role` matching this value
    /// (e.g. "user", "assistant", "tool").
    role: ?[]const u8 = null,
    /// When non-null, only return messages with `created_at >= since`.
    since: ?[]const u8 = null,
    /// When non-null, only return messages with `created_at <= until`.
    until: ?[]const u8 = null,
    /// Max number of rows to return. Defaults to 100 for safety — the
    /// caller can request up to 1000 explicitly. The read_compacted_messages
    /// tool wraps this in its own user-facing limit parameter.
    limit: ?u32 = 100,
};

/// Lighter-weight return struct than `TUIHistory` — only the fields the
/// `read_compacted_messages` tool actually surfaces. Avoids the
/// ~30-field TUIHistory struct, which has columns that don't exist
/// in a minimal test schema (e.g. `diffview_before`) and would force
/// every test to seed them.
pub const CompactedMessage = struct {
    id: []const u8,
    session_id: []const u8,
    role: []const u8,
    content: []const u8,
    tool_call_id: ?[]const u8,
    tool_name: ?[]const u8,
    model: []const u8,
    agent: []const u8,
    created_at: []const u8,

    pub fn deinit(self: *const CompactedMessage, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.session_id);
        allocator.free(self.role);
        allocator.free(self.content);
        allocator.free(self.model);
        allocator.free(self.agent);
        allocator.free(self.created_at);
        if (self.tool_call_id) |t| allocator.free(t);
        if (self.tool_name) |t| allocator.free(t);
    }
};

/// Return messages marked `is_feed_to_llm = 0` for the given session.
/// This is the inverse of `getMessages` (line 1076): where `getMessages`
/// returns the messages the LLM sees, `getCompactedMessages` returns
/// the messages the LLM does NOT see (the ones dropped by compaction).
///
/// Filter semantics:
/// - `message_ids`: when non-null, IN-clause filter (skipped if empty).
/// - `role`: exact match on `llm_history.role`.
/// - `since` / `until`: lexicographic comparison on the
///   `created_at` string (which is in `YYYY-MM-DD HH:MM:SS` format from
///   `datetime('now')`, so lex-sort = chrono-sort). Matches the
///   existing cursor convention in `getSessionListWithCursor`.
/// - `limit`: clamps the row count (defaults to 100).
///
/// Returned slice's elements are heap-allocated via `allocator.dupe`;
/// caller must call `result[i].deinit(allocator)` for each and
/// `allocator.free(results)` to free the outer slice.
pub fn getCompactedMessages(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    session_id: []const u8,
    opts: CompactedMessagesOptions,
) ![]CompactedMessage {
    const effective_limit = opts.limit orelse 100;

    // Build the WHERE clause incrementally. Each filter appends
    // AND <clause> to the base `h.session_id = ? AND h.is_feed_to_llm = 0`.
    var sql: std.ArrayList(u8) = .empty;
    defer sql.deinit(allocator);
    try sql.appendSlice(allocator,
        \\SELECT
        \\    h.id, h.session_id, COALESCE(h.role, 'assistant'),
        \\    COALESCE(h.response_content, ''),
        \\    h.tool_call_id, h.tool_name,
        \\    COALESCE(h.model, ''), COALESCE(h.agent, ''),
        \\    COALESCE(h.created_at, '')
        \\FROM llm_history h
        \\WHERE h.session_id = ?
        \\  AND h.is_feed_to_llm = 0
    );

    var bind_values: std.ArrayList([]const u8) = .empty;
    defer bind_values.deinit(allocator);
    try bind_values.append(allocator, session_id);

    if (opts.message_ids) |ids| {
        if (ids.len > 0) {
            try sql.appendSlice(allocator, " AND h.id IN (");
            for (ids, 0..) |id, i| {
                if (i > 0) try sql.append(allocator, ',');
                try sql.append(allocator, '?');
                try bind_values.append(allocator, id);
            }
            try sql.append(allocator, ')');
        }
    }

    if (opts.role) |r| {
        try sql.appendSlice(allocator, " AND h.role = ?");
        try bind_values.append(allocator, r);
    }

    if (opts.since) |s| {
        try sql.appendSlice(allocator, " AND h.created_at >= ?");
        try bind_values.append(allocator, s);
    }

    if (opts.until) |u| {
        try sql.appendSlice(allocator, " AND h.created_at <= ?");
        try bind_values.append(allocator, u);
    }

    try sql.appendSlice(allocator, " ORDER BY h.created_at ASC");

    // Bind the limit at the end. Format inline since we know it's u32.
    try sql.print(allocator, " LIMIT {d}", .{effective_limit});

    var rows = try db.query(allocator, sql.items, bind_values.items);
    defer rows.deinit();

    var results: std.ArrayList(CompactedMessage) = .empty;
    errdefer {
        for (results.items) |m| {
            var copy = m;
            copy.deinit(allocator);
        }
        results.deinit(allocator);
    }

    while (try rows.next()) |row| {
        const msg = CompactedMessage{
            .id = try allocator.dupe(u8, row.values[0]),
            .session_id = try allocator.dupe(u8, row.values[1]),
            .role = try allocator.dupe(u8, row.values[2]),
            .content = try allocator.dupe(u8, row.values[3]),
            .tool_call_id = if (row.values[4].len > 0) try allocator.dupe(u8, row.values[4]) else null,
            .tool_name = if (row.values[5].len > 0) try allocator.dupe(u8, row.values[5]) else null,
            .model = try allocator.dupe(u8, row.values[6]),
            .agent = try allocator.dupe(u8, row.values[7]),
            .created_at = try allocator.dupe(u8, row.values[8]),
        };
        try results.append(allocator, msg);
    }

    return try results.toOwnedSlice(allocator);
}
```

- [ ] **Step 2.2.2: Run the test to verify it passes**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
timeout 180 zig build test --summary all 2>&1 | tail -n 5
```

Expected: `test success` with 4 new tests passing (Chunk 1's 4 + Chunk 2's 4).

- [ ] **Step 2.2.3: Verify the install build** (catches lazy-analysis bugs)

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
timeout 180 zig build install:linux:system 2>&1 | tail -n 10
```

Expected: 0 errors in the compile-exe step.

- [ ] **Step 2.2.4: Commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
git add src/ai_workflow/tui/llm_history.zig \
        src/ai_workflow/tui/llm_history_compacted_messages_test.zig \
        src/ai_workflow/tui/test_runner.zig
git commit -m "feat(llm_history): add getCompactedMessages query

Sibling to getMessages but returns rows where is_feed_to_llm=0
(the messages dropped by compaction). Supports filter options
for message_ids, role, since, until, and limit.

Refs: docs/superpowers/plans/2026-06-20-compaction-output-long-context.md"
```

---
## Chunk 3: New tool `read_compacted_messages`

**Files:**
- Create: `src/modules/agent/tools/read_compacted_messages.zig`
- Create: `src/modules/agent/tools/read_compacted_messages_test.zig`

**Goal:** Create the tool definition, input schema, executor, and XML serializer for `read_compacted_messages`. The tool has two modes — index-only (default) and full-body (when `message_ids` is provided) — and lives in the agent's toolbox alongside `read_file`, `glob`, etc.

### Task 3.1: Write the failing tool test

**File:** `src/modules/agent/tools/read_compacted_messages_test.zig`

- [ ] **Step 3.1.1: Create the test file**

```zig
const std = @import("std");
const testing = std.testing;
const rcm = @import("read_compacted_messages.zig");
const sqlite = @import("nalarcore").sqlite;

fn setupDb() !struct {
    db: sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
} {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");

    try db.exec(alloc,
        \\CREATE TABLE llm_history (
        \\  id TEXT PRIMARY KEY,
        \\  session_id TEXT NOT NULL,
        \\  model TEXT,
        \\  response_content TEXT,
        \\  role TEXT,
        \\  tool_call_id TEXT,
        \\  tool_name TEXT,
        \\  is_feed_to_llm INTEGER DEFAULT 1,
        \\  agent TEXT,
        \\  created_at TEXT DEFAULT (datetime('now'))
        \\)
    , &.{});
    return .{ .db = db, .threaded = threaded };
}

fn teardownDb(s: *const @TypeOf(setupDb() catch unreachable)) void {
    s.db.deinit();
    s.threaded.deinit();
}

test "execute_read_compacted_messages: index mode (no message_ids) returns only metadata" {
    const s = try setupDb();
    defer teardownDb(&s);
    const alloc = testing.allocator;

    // Seed: 2 compacted + 1 active + 1 different-session
    try s.db.exec(alloc, "INSERT INTO llm_history (id, session_id, role, response_content, is_feed_to_llm) VALUES ('h1','sess_1','user','Fix login',0)", &.{});
    try s.db.exec(alloc, "INSERT INTO llm_history (id, session_id, role, response_content, is_feed_to_llm) VALUES ('h2','sess_1','assistant','On it',0)", &.{});
    try s.db.exec(alloc, "INSERT INTO llm_history (id, session_id, role, response_content, is_feed_to_llm) VALUES ('h3','sess_1','user','active',1)", &.{});
    try s.db.exec(alloc, "INSERT INTO llm_history (id, session_id, role, response_content, is_feed_to_llm) VALUES ('h4','sess_2','user','other',0)", &.{});

    const xml = try rcm.execute_read_compacted_messages(alloc, s.threaded.io(), &s.db, "sess_1", .{});
    defer alloc.free(xml);

    // Index mode: <message_index> present, NO <content> tags
    try testing.expect(std.mem.indexOf(u8, xml, "<message_index>") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "<id>h1</id>") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "<id>h2</id>") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "<preview>Fix login</preview>") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "<preview>On it</preview>") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "<content>") == null); // CRITICAL — index mode hides full content
    // Different-session rows are excluded
    try testing.expect(std.mem.indexOf(u8, xml, "<id>h4</id>") == null);
    // Active rows (is_feed_to_llm=1) are excluded
    try testing.expect(std.mem.indexOf(u8, xml, "<id>h3</id>") == null);
}

test "execute_read_compacted_messages: full mode (with message_ids) returns content" {
    const s = try setupDb();
    defer teardownDb(&s);
    const alloc = testing.allocator;

    try s.db.exec(alloc, "INSERT INTO llm_history (id, session_id, role, response_content, is_feed_to_llm) VALUES ('h1','sess_1','user','Fix login',0)", &.{});
    try s.db.exec(alloc, "INSERT INTO llm_history (id, session_id, role, response_content, is_feed_to_llm) VALUES ('h2','sess_1','assistant','On it',0)", &.{});

    const ids = [_][]const u8{ "h1" };
    const xml = try rcm.execute_read_compacted_messages(alloc, s.threaded.io(), &s.db, "sess_1", .{ .message_ids = &ids });
    defer alloc.free(xml);

    try testing.expect(std.mem.indexOf(u8, xml, "<content>Fix login</content>") != null);
    // h2 not requested → only its metadata in <message_index>, NOT its content
    try testing.expect(std.mem.indexOf(u8, xml, "<id>h2</id>") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "<content>On it</content>") == null);
}

test "execute_read_compacted_messages: tool_call_id and tool_name surfaced for tool-role messages" {
    const s = try setupDb();
    defer teardownDb(&s);
    const alloc = testing.allocator;
    try s.db.exec(alloc, "INSERT INTO llm_history (id, session_id, role, response_content, tool_call_id, tool_name, is_feed_to_llm) VALUES ('h1','sess_1','tool','42/42 tests pass','tc_1','bash',0)", &.{});

    const ids = [_][]const u8{ "h1" };
    const xml = try rcm.execute_read_compacted_messages(alloc, s.threaded.io(), &s.db, "sess_1", .{ .message_ids = &ids });
    defer alloc.free(xml);

    try testing.expect(std.mem.indexOf(u8, xml, "<role>tool</role>") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "<tool_call_id>tc_1</tool_call_id>") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "<tool_name>bash</tool_name>") != null);
}

test "execute_read_compacted_messages: empty result returns well-formed empty message_index" {
    const s = try setupDb();
    defer teardownDb(&s);
    const alloc = testing.allocator;

    const xml = try rcm.execute_read_compacted_messages(alloc, s.threaded.io(), &s.db, "sess_empty", .{});
    defer alloc.free(xml);

    // Allow either <message_index></message_index> or
    // <message_index>\n  </message_index> — both are well-formed.
    const has_empty = std.mem.indexOf(u8, xml, "<message_index>") != null and
        std.mem.indexOf(u8, xml, "</message_index>") != null;
    try testing.expect(has_empty);
    try testing.expect(std.mem.indexOf(u8, xml, "<count>0</count>") != null);
}
```

- [ ] **Step 3.1.2: Run the test to verify it fails**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
timeout 180 zig build test --summary all 2>&1 | tail -n 15
```

Expected: compile error referencing `read_compacted_messages.zig` (file does not exist).

### Task 3.2: Implement the tool

**File:** `src/modules/agent/tools/read_compacted_messages.zig`

- [ ] **Step 3.2.1: Create the file**

```zig
const std = @import("std");
const schemas = @import("schemas.zig");
const AgentTool = schemas.AgentTool;
const ToolProperty = schemas.ToolProperty;
const ToolParameters = schemas.ToolParameters;
const nalarcore = @import("nalarcore");
const sqlite = nalarcore.sqlite;
const llm_history = nalarcore.llm_history;
const helpers = nalarcore.helpers;
const xmlEscape = helpers.xml_escape;

/// Input for read_compacted_messages. The LLM supplies this from the
/// <message_index> section of its current <compact_messages> summary.
///
/// Why both `mode` AND `message_ids`: the LLM often wants to "skim"
/// the index first (1 tool call returns 20 entries, ~500 tokens), then
/// fetch full content for 2-3 specific ids. Forcing a second round-trip
/// would add latency; collapsing the two modes into one tool keeps the
/// surface area small (one tool, one prompt line).
pub const ReadCompactedMessagesInput = struct {
    /// "index" (default) returns the <message_index> section only.
    /// "full" returns <message_index> + <content> bodies for the
    /// requested message_ids. The two modes produce overlapping but
    /// not identical output — pick the one that matches your need.
    mode: []const u8 = "index",
    /// Comma-separated message ids from the <message_index>. Required
    /// when mode="full". Ignored when mode="index". Example:
    ///   "h_123,h_456"
    message_ids: []const u8 = "",
    /// When non-empty, filter to messages with this exact role.
    /// Useful for "show me only the user's questions" queries.
    role: []const u8 = "",
    /// ISO 8601 / YYYY-MM-DD HH:MM:SS lower bound on created_at.
    since: []const u8 = "",
    /// Upper bound. Both bounds are inclusive and lex-sort = chrono-sort.
    until: []const u8 = "",
    /// Max rows to return. Defaults to 20 (matches the safe default in
    /// the description); capped at 200 by execute_read_compacted_messages
    /// to prevent token-budget blowups.
    limit: u32 = 20,
};

/// Tool definition for read_compacted_messages.
///
/// CRITICAL for the long-context story: this is the ONLY way the agent
/// can read the messages dropped by compaction. Without it, every
/// compaction is a permanent loss of detail (the summary is lossy by
/// design). The description must be precise enough that the LLM uses
/// the tool correctly: index mode first, then full mode with explicit ids.
pub const read_compacted_messages_tool = AgentTool{
    .type = "function",
    .function = .{
        .name = "read_compacted_messages",
        .description =
            \\Read messages that were dropped from the conversation by compaction. Compaction marks old messages as is_feed_to_llm=0 and replaces them with a <compact_messages> summary. This tool is the ONLY way to recover the full content of those dropped messages.
            \\
            \\TWO MODES:
            \\- mode="index" (default): returns a <message_index> with id, role, created_at, and a 100-char preview per message. Use this first to see what's available. Cheap.
            \\- mode="full": also returns the full <content> bodies of the messages whose ids you list in `message_ids`. Use this when you need the actual text — e.g. to re-read a tool result, a user question, or an assistant response.
            \\
            \\The id values come from the <message_index> section of the current <compact_messages> summary in your context. The summary is regenerated on every compaction, so the ids are stable for the lifetime of the session.
            \\
            \\Filters (optional, work in both modes):
            \\- role: "user", "assistant", or "tool" — exact match.
            \\- since / until: YYYY-MM-DD HH:MM:SS timestamps (inclusive).
            \\- limit: max rows (default 20, max 200).
            \\
            \\Example (index mode):
            \\  {"mode": "index", "role": "user"}
            \\Example (full mode, fetch 2 specific messages):
            \\  {"mode": "full", "message_ids": "h_1781,h_1782"}
        ,
        .parameters = .{
            .type = "object",
            .properties = &.{
                .{
                    .name = "mode",
                    .type = "string",
                    .description = "Either 'index' (default, returns only metadata + preview) or 'full' (also returns full <content> bodies for the messages listed in message_ids).",
                },
                .{
                    .name = "message_ids",
                    .type = "string",
                    .description = "Comma-separated message ids from the <message_index>. Required when mode='full'. Example: 'h_123,h_456'. Ignored when mode='index'.",
                },
                .{
                    .name = "role",
                    .type = "string",
                    .description = "Optional exact-match role filter: 'user', 'assistant', or 'tool'.",
                },
                .{
                    .name = "since",
                    .type = "string",
                    .description = "Optional lower bound on created_at (inclusive). YYYY-MM-DD HH:MM:SS format.",
                },
                .{
                    .name = "until",
                    .type = "string",
                    .description = "Optional upper bound on created_at (inclusive).",
                },
                .{
                    .name = "limit",
                    .type = "number",
                    .description = "Max rows to return. Default 20, max 200.",
                },
            },
            .required = &.{},
        },
    },
};

/// Parse `message_ids_csv` ("h_123,h_456") into a `[]const []const u8`.
/// Returns an empty slice for empty input. Caller owns the returned
/// strings + the outer slice; free with the helpers in
/// `std.ArrayList([]const u8)`.
fn parseMessageIds(allocator: std.mem.Allocator, csv: []const u8) ![]const []const u8 {
    if (csv.len == 0) return &.{};
    var ids: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (ids.items) |id| allocator.free(id);
        ids.deinit(allocator);
    }
    var iter = std.mem.splitScalar(u8, csv, ',');
    while (iter.next()) |id| {
        const trimmed = std.mem.trim(u8, id, " \t");
        if (trimmed.len > 0) {
            try ids.append(allocator, try allocator.dupe(u8, trimmed));
        }
    }
    return try ids.toOwnedSlice(allocator);
}

/// Execute read_compacted_messages. Returns an XML string for the LLM.
///
/// Output shape:
///   <read_compacted_messages mode="index">
///     <session_id>...</session_id>
///     <count>5</count>
///     <message_index>
///       <entry>
///         <id>h_123</id>
///         <role>user</role>
///         <created_at>2025-01-01 00:00:00</created_at>
///         <preview>Fix the login bug</preview>     <-- 100-char preview, always
///         <tool_call_id>tc_1</tool_call_id>         <-- only for tool role
///         <tool_name>bash</tool_name>              <-- only for tool role
///         <content>Full message body here</content> <-- ONLY when mode=full AND id in message_ids
///       </entry>
///       ...
///     </message_index>
///   </read_compacted_messages>
///
/// On a hard error (e.g. malformed mode), returns:
///   <read_compacted_messages><error>...</error></read_compacted_messages>
pub fn execute_read_compacted_messages(
    allocator: std.mem.Allocator,
    io: std.Io,
    db: *sqlite.SqliteBackend,
    session_id: []const u8,
    input: ReadCompactedMessagesInput,
) ![]const u8 {
    // Validate mode.
    const is_full_mode = blk: {
        if (std.mem.eql(u8, input.mode, "index")) break :blk false;
        if (std.mem.eql(u8, input.mode, "full")) break :blk true;
        // Default to index for unknown / empty mode.
        if (input.mode.len == 0) break :blk false;
        const msg = try std.fmt.allocPrint(allocator,
            "Invalid mode '{s}'. Must be 'index' or 'full'.",
            .{input.mode});
        defer allocator.free(msg);
        const err_escaped = try xmlEscape(allocator, msg);
        defer allocator.free(err_escaped);
        return std.fmt.allocPrint(allocator,
            "<read_compacted_messages><error>{s}</error></read_compacted_messages>",
            .{err_escaped});
    };

    // Parse and validate.
    const parsed_ids = try parseMessageIds(allocator, input.message_ids);
    defer {
        for (parsed_ids) |id| allocator.free(id);
        allocator.free(parsed_ids);
    }
    if (is_full_mode and parsed_ids.len == 0) {
        const msg = "mode='full' requires non-empty message_ids.";
        const err_escaped = try xmlEscape(allocator, msg);
        defer allocator.free(err_escaped);
        return std.fmt.allocPrint(allocator,
            "<read_compacted_messages><error>{s}</error></read_compacted_messages>",
            .{err_escaped});
    }

    const effective_limit = @min(input.limit, 200);

    const opts = llm_history.CompactedMessagesOptions{
        .message_ids = if (is_full_mode) parsed_ids else null,
        .role = if (input.role.len > 0) input.role else null,
        .since = if (input.since.len > 0) input.since else null,
        .until = if (input.until.len > 0) input.until else null,
        .limit = effective_limit,
    };

    const messages = llm_history.getCompactedMessages(allocator, db, session_id, opts) catch |err| {
        const msg = try std.fmt.allocPrint(allocator, "Database query failed: {s}", .{@errorName(err)});
        defer allocator.free(msg);
        const err_escaped = try xmlEscape(allocator, msg);
        defer allocator.free(err_escaped);
        return std.fmt.allocPrint(allocator,
            "<read_compacted_messages><error>{s}</error></read_compacted_messages>",
            .{err_escaped});
    };
    defer {
        for (messages) |m| {
            var copy = m;
            copy.deinit(allocator);
        }
        allocator.free(messages);
    }

    // Build a quick lookup set from parsed_ids (only used in full mode).
    var full_ids_set: ?std.StringHashMapUnmanaged(void) = if (is_full_mode)
        .empty
    else
        null;
    defer if (full_ids_set) |*s| s.deinit(allocator);
    if (is_full_mode) {
        for (parsed_ids) |id| try full_ids_set.?.put(allocator, id, {});
    }

    var xml: std.ArrayList(u8) = .empty;
    errdefer xml.deinit(allocator);

    try xml.print(allocator, "<read_compacted_messages mode=\"{s}\">\n", .{input.mode});
    try xml.print(allocator, "  <session_id>{s}</session_id>\n", .{session_id});
    try xml.print(allocator, "  <count>{d}</count>\n", .{messages.len});
    try xml.appendSlice(allocator, "  <message_index>\n");

    for (messages) |m| {
        const id_escaped = try xmlEscape(allocator, m.id);
        defer allocator.free(id_escaped);
        const role_escaped = try xmlEscape(allocator, m.role);
        defer allocator.free(role_escaped);
        const preview_src: []const u8 = if (m.content.len > 100) m.content[0..100] else m.content;
        const preview_escaped = try xmlEscape(allocator, preview_src);
        defer allocator.free(preview_escaped);

        try xml.appendSlice(allocator, "    <entry>\n");
        try xml.print(allocator, "      <id>{s}</id>\n", .{id_escaped});
        try xml.print(allocator, "      <role>{s}</role>\n", .{role_escaped});
        if (m.created_at.len > 0) {
            const ca_escaped = try xmlEscape(allocator, m.created_at);
            defer allocator.free(ca_escaped);
            try xml.print(allocator, "      <created_at>{s}</created_at>\n", .{ca_escaped});
        }
        try xml.print(allocator, "      <preview>{s}</preview>\n", .{preview_escaped});

        if (std.mem.eql(u8, m.role, "tool")) {
            if (m.tool_call_id) |tcid| {
                const tcid_escaped = try xmlEscape(allocator, tcid);
                defer allocator.free(tcid_escaped);
                try xml.print(allocator, "      <tool_call_id>{s}</tool_call_id>\n", .{tcid_escaped});
            }
            if (m.tool_name) |tn| {
                const tn_escaped = try xmlEscape(allocator, tn);
                defer allocator.free(tn_escaped);
                try xml.print(allocator, "      <tool_name>{s}</tool_name>\n", .{tn_escaped});
            }
        }

        // Full-mode content inclusion: only when this id is in the parsed_ids set.
        if (is_full_mode and full_ids_set != null and full_ids_set.?.contains(m.id)) {
            const content_escaped = try xmlEscape(allocator, m.content);
            defer allocator.free(content_escaped);
            try xml.print(allocator, "      <content>{s}</content>\n", .{content_escaped});
        }

        try xml.appendSlice(allocator, "    </entry>\n");
    }

    try xml.appendSlice(allocator, "  </message_index>\n");
    try xml.appendSlice(allocator, "</read_compacted_messages>\n");

    _ = io; // Reserved for future streaming; not used in v1.
    return try xml.toOwnedSlice(allocator);
}

/// `toXmlSuccess` / `toXmlError` are the standardized envelope helpers
/// used by the tool_registry.execX wrapper. They wrap the inner XML
/// in `<tool>...</tool>` so handle_tool sees the consistent envelope.
pub fn toXmlSuccess(allocator: std.mem.Allocator, inner: []const u8) ![]u8 {
    return allocator.dupe(u8, inner);
}

pub fn toXmlError(allocator: std.mem.Allocator, err_msg: []const u8) ![]u8 {
    const escaped = try xmlEscape(allocator, err_msg);
    defer allocator.free(escaped);
    return std.fmt.allocPrint(allocator,
        "<read_compacted_messages><error>{s}</error></read_compacted_messages>",
        .{escaped});
}
```

- [ ] **Step 3.2.2: Run the test to verify it passes**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
timeout 180 zig build test --summary all 2>&1 | tail -n 5
```

Expected: `test success` with 4 new tests passing (baseline + 4 + 4 + 4 = +12 from the start).

- [ ] **Step 3.2.3: Commit (chunk-3 partial — registering is Chunk 4)**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
git add src/modules/agent/tools/read_compacted_messages.zig \
        src/modules/agent/tools/read_compacted_messages_test.zig
git commit -m "feat(tool): add read_compacted_messages

Two-mode tool for the agent to read messages dropped by compaction:
- mode='index': <message_index> with id+role+created_at+preview
- mode='full': same index + full <content> for explicit message_ids

This is the only way for the agent to recover detail lost during
compaction — without it, every compaction is permanent loss.

Refs: docs/superpowers/plans/2026-06-20-compaction-output-long-context.md"
```

---
## Chunk 4: Tool registry integration

**Files:**
- Modify: `src/ai_workflow/tui/tool_registry.zig` (add import + `execReadCompactedMessages` + 3 registry entries)
- Modify: `src/ai_workflow/tui/handle_tool.zig` (verify dispatch reaches `execReadCompactedMessages` — likely no change if dispatch is name-based)

**Goal:** The new tool is available to the main agent's tool-calling loop.

### Task 4.1: Wire the tool into the registry

**File:** `src/ai_workflow/tui/tool_registry.zig`

- [ ] **Step 4.1.1: Add the import (near line 44, alongside the other `const ..._mod = nalar_mod.X` lines)**

```zig
const read_compacted_messages_mod = nalar_mod.read_compacted_messages;
```

- [ ] **Step 4.1.2: Add the `execReadCompactedMessages` function (insert after `execListMemory` at line 323, near the other memory/history-related exec functions)**

```zig
pub fn execReadCompactedMessages(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    const parsed = std.json.parseFromSlice(
        read_compacted_messages_mod.ReadCompactedMessagesInput,
        ctx.allocator,
        tc.function.arguments,
        .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
    ) catch |err| {
        const err_msg = try std.fmt.allocPrint(ctx.allocator, "read_compacted_messages failed: {s}", .{@errorName(err)});
        const output = try wrapToolOutput(ctx.allocator, "read_compacted_messages", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    defer parsed.deinit();

    const inner = read_compacted_messages_mod.execute_read_compacted_messages(
        ctx.allocator,
        ctx.io,
        ctx.db,
        ctx.session_id,
        parsed.value,
    ) catch |err| {
        const err_msg = try std.fmt.allocPrint(ctx.allocator, "read_compacted_messages failed: {s}", .{@errorName(err)});
        const output = try wrapToolOutput(ctx.allocator, "read_compacted_messages", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };

    const output = try wrapToolOutput(ctx.allocator, "read_compacted_messages", tc.function.arguments, true, null, inner);
    return ToolExecResult{ .output = output, .output_allocated = true };
}
```

- [ ] **Step 4.1.3: Add to `UNIFIED_TOOL_REGISTRY` (line 1478, in the "MEMORY TOOLS" section)**

Insert in the "MEMORY TOOLS" section (after the `list_memory` entry on line 1496):

```zig
.{ .name = "read_compacted_messages", .exec = execReadCompactedMessages, .tool_def = read_compacted_messages_mod.read_compacted_messages_tool },
```

- [ ] **Step 4.1.4: Add to `allAgentTools` (line 1535, in the comptime `_tool_models.AgentTool` block)**

Add (alphabetical, between `list_memory_tool` and `view_skill_tool`):

```zig
read_compacted_messages_mod.read_compacted_messages_tool,
```

- [ ] **Step 4.1.5: Verify the build**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
timeout 180 zig build test --summary all 2>&1 | tail -n 5
timeout 180 zig build install:linux:system 2>&1 | tail -n 10
```

Both should succeed. If `handle_tool.zig` does dispatch by name (most likely), no change is needed there. **If the build fails with a "tool not found" error from handle_tool.zig**, that means dispatch is explicit and needs an entry there — add it to whatever dispatch map the file uses.

- [ ] **Step 4.1.6: Commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
git add src/ai_workflow/tui/tool_registry.zig
git commit -m "feat(tool_registry): register read_compacted_messages

Add execReadCompactedMessages + entries in UNIFIED_TOOL_REGISTRY
and allAgentTools so the main agent can call the new tool.
The new tool's import comes from nalar_mod.read_compacted_messages
(re-exported from src/modules/agent/tools/read_compacted_messages.zig).

Refs: docs/superpowers/plans/2026-06-20-compaction-output-long-context.md"
```

---

## Chunk 5: CompactionAgent prompt update

**Files:**
- Modify: `src/ai_workflow/tui/prompts/special.zig` (update the `CompactionAgent` constant)

**Goal:** Tell the CompactionAgent LLM that the next agent has a `read_compacted_messages` tool. This biases the compactor toward producing output that pairs well with the lookup tool (a structured summary that the agent can use immediately, plus a clean separation between "summary" and "raw context to fetch on demand").

### Task 5.1: Update the CompactionAgent prompt

- [ ] **Step 5.1.1: Read the current `CompactionAgent` prompt** (likely 200-500 lines; located at `src/ai_workflow/tui/prompts/special.zig:5`)

```bash
cat /home/ginwa/agentic_coding_zig/ginwaaitoolbox/src/ai_workflow/tui/prompts/special.zig
```

- [ ] **Step 5.1.2: Add a new section to the prompt that explains the `read_compacted_messages` tool**

Find the line that starts with `\\You are **CompactionAgent**` (or similar) and append a new section before the closing of the prompt. Use `text_replace` to add the new section. The new section should explain:

1. The next agent has a `read_compacted_messages` tool.
2. The tool returns the FULL content of any dropped message (by id, with optional filters).
3. The compactor should NOT bloat the summary with raw text that the next agent could re-fetch. Focus on the synthesized handoff package.
4. The compactor SHOULD ensure every id/filename/decision in the summary is precise (the agent may fetch and re-read the underlying messages to verify).

Suggested prompt addition (use `text_replace` to insert just before the final `\` line):

```text
IMPORTANT: The next agent will have a `read_compacted_messages` tool
that can fetch the full content of any dropped message by id. You do
NOT need to include the full text of tool results, file contents, or
long assistant responses in your summary — the next agent can fetch
them on demand. Focus on:

- SUMMARIZED context (what happened, why, what was decided).
- POINTERS to specific old messages by id (e.g. "see h_42 for the
  full test output") so the next agent knows what to fetch.
- KEY EXCERPTS (a sentence or two, never the whole thing) only when
  the exact wording matters — e.g. a specific error message the
  next agent will pattern-match against.

Verbose pastes of tool outputs, file contents, or back-and-forth
transcript are ANTI-PATTERNS. The next agent will fetch what it
needs; your job is the synthesized handoff, not a verbatim copy.
```

- [ ] **Step 5.1.3: Verify the build**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
timeout 180 zig build test --summary all 2>&1 | tail -n 5
```

Expected: `test success` — no test changes, but the prompt update should compile.

- [ ] **Step 5.1.4: Commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
git add src/ai_workflow/tui/prompts/special.zig
git commit -m "feat(prompts): tell CompactionAgent about read_compacted_messages

Bias the compactor toward producing a synthesized handoff package
(not a verbatim copy). The next agent can fetch full content via
read_compacted_messages when it needs specifics.

Refs: docs/superpowers/plans/2026-06-20-compaction-output-long-context.md"
```

---

## Chunk 6: End-to-end smoke test

**Files:**
- Create: `src/ai_workflow/tui/compaction_long_context_test.zig` (integration test combining envelope + query)
- Modify: `src/ai_workflow/tui/test_runner.zig`

**Goal:** A single end-to-end test that exercises the full chain: build an envelope → mark messages as compacted → query the compacted messages with the new tool. This catches integration bugs that the per-chunk unit tests miss (e.g. a `markMessageNotForLlmRun` + `getCompactedMessages` mismatch, or an envelope id format that the tool can't resolve).

### Task 6.1: Write the integration test

**File:** `src/ai_workflow/tui/compaction_long_context_test.zig`

- [ ] **Step 6.1.1: Create the test file**

```zig
const std = @import("std");
const testing = std.testing;
const workflow = @import("workflow.zig");
const agent = @import("nalarcore").agent;
const sqlite = @import("nalarcore").sqlite;
const llm_history = @import("llm_history.zig");
const rcm = @import("read_compacted_messages.zig");
const logger = @import("nalarcore").logger;

fn setupDb() !struct { db: sqlite.SqliteBackend, threaded: std.Io.Threaded } {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");

    try db.exec(alloc,
        \\CREATE TABLE llm_history (
        \\  id TEXT PRIMARY KEY,
        \\  session_id TEXT NOT NULL,
        \\  model TEXT,
        \\  response_content TEXT,
        \\  finish_reason TEXT,
        \\  role TEXT,
        \\  tool_calls_json TEXT,
        \\  tool_call_id TEXT,
        \\  reasoning_content TEXT,
        \\  is_feed_to_llm INTEGER DEFAULT 1,
        \\  agent TEXT,
        \\  loop_index INTEGER DEFAULT 0,
        \\  temperature REAL DEFAULT 0.2,
        \\  is_thinking INTEGER DEFAULT 0,
        \\  created_at TEXT DEFAULT (datetime('now')),
        \\  parent_session_id TEXT,
        \\  parent_id TEXT,
        \\  prompt_tokens INTEGER DEFAULT 0,
        \\  completion_tokens INTEGER DEFAULT 0,
        \\  total_tokens INTEGER DEFAULT 0,
        \\  is_input INTEGER DEFAULT 0,
        \\  is_output INTEGER DEFAULT 0,
        \\  tool_name TEXT,
        \\  diffview_before TEXT,
        \\  diffview_after TEXT,
        \\  image_url TEXT
        \\)
    , &.{});
    try db.exec(alloc,
        \\CREATE TABLE sessions (id TEXT PRIMARY KEY, cwd TEXT, name TEXT)
    , .{});
    return .{ .db = db, .threaded = threaded };
}

fn teardownDb(s: *const @TypeOf(setupDb() catch unreachable)) void {
    s.db.deinit();
    s.threaded.deinit();
}

test "end-to-end: compaction envelope is queryable via read_compacted_messages" {
    const s = try setupDb();
    defer teardownDb(&s);
    const alloc = testing.allocator;

    // Build a 6-message fixture (system + 5 dropped). Capture the
    // DB ids we'll write for the dropped messages so we can verify
    // they show up in the read tool's output AFTER compaction.
    const session_id = "sess_e2e_1";
    const dropped_ids = [_][]const u8{ "h_real_1", "h_real_2", "h_real_3", "h_real_4", "h_real_5" };
    const dropped_contents = [_][]const u8{
        "Fix the login bug",
        "I'll investigate the auth flow",
        "running tests now",
        "tests pass: 42/42",
        "shipping the patch",
    };
    const dropped_roles = [_][]const u8{ "user", "assistant", "assistant", "tool", "user" };

    // Pre-seed the DB with realistic ids (so the agent can fetch them after compaction).
    for (dropped_ids, dropped_contents, dropped_roles) |id, content, role| {
        const sql =
            \\INSERT INTO llm_history (id, session_id, model, response_content, role, is_feed_to_llm, created_at, tool_call_id, tool_name)
            \\VALUES (?, ?, ?, ?, ?, 1, ?, ?, ?)
        ;
        const created_at = "2025-01-01 00:00:00";
        var tcid_buf: [16]u8 = undefined;
        const tcid = if (std.mem.eql(u8, role, "tool")) std.fmt.bufPrint(&tcid_buf, "tc_{s}", .{id}) catch "" else "";
        const tname = if (std.mem.eql(u8, role, "tool")) "bash" else "";
        try s.db.exec(alloc, sql, &.{ id, session_id, "gpt-4o", content, role, created_at, tcid, tname });
    }

    // Build the in-memory message list and compact it.
    var messages: std.ArrayList(agent.AgentMessage) = .empty;
    try messages.append(alloc, .{ .role = .system, .content = try alloc.dupe(u8, "You are a coding agent.") });
    for (dropped_contents, 0..) |content, i| {
        const role_str = dropped_roles[i];
        const role_enum = std.meta.stringToEnum(agent.Role, role_str) orelse .user;
        try messages.append(alloc, .{
            .role = role_enum,
            .content = try alloc.dupe(u8, content),
            .tool_call_id = if (std.mem.eql(u8, role_str, "tool")) try alloc.dupe(u8, "tc_x") else null,
            .tool_name = if (std.mem.eql(u8, role_str, "tool")) try alloc.dupe(u8, "bash") else null,
        });
    }
    defer messages.deinit(alloc);

    const lg = try logger.createTestLogger(alloc);
    defer lg.deinit();

    const new_messages = try workflow.compactMessageInMemoryNew(
        alloc, messages, "GOAL: ship the fix\nNEXT: deploy",
        session_id, "gpt-4o", "/tmp", &s.db, s.threaded.io(), lg,
    );
    defer new_messages.deinit(alloc);

    // Now exercise read_compacted_messages in both modes.

    // INDEX MODE: should return the 5 dropped messages.
    const index_xml = try rcm.execute_read_compacted_messages(alloc, s.threaded.io(), &s.db, session_id, .{});
    defer alloc.free(index_xml);
    try testing.expect(std.mem.indexOf(u8, index_xml, "<count>5</count>") != null);
    for (dropped_ids) |id| {
        // The envelope uses adhoc_* ids, but the read tool uses the
        // pre-seeded h_real_* ids. Both should appear: the adhoc_* in
        // the envelope (not in this test's scope), the h_real_* in
        // the index (because the DB rows are still there with those ids).
        try testing.expect(std.mem.indexOf(u8, index_xml, id) != null);
    }

    // FULL MODE: fetch h_real_4 (the tool-result with "tests pass: 42/42").
    const full_ids = [_][]const u8{"h_real_4"};
    const full_xml = try rcm.execute_read_compacted_messages(
        alloc, s.threaded.io(), &s.db, session_id,
        .{ .mode = "full", .message_ids = &full_ids },
    );
    defer alloc.free(full_xml);
    try testing.expect(std.mem.indexOf(u8, full_xml, "<content>tests pass: 42/42</content>") != null);
    try testing.expect(std.mem.indexOf(u8, full_xml, "<tool_name>bash</tool_name>") != null);
    try testing.expect(std.mem.indexOf(u8, full_xml, "<tool_call_id>") != null);
}
```

- [ ] **Step 6.1.2: Register the test in `src/ai_workflow/tui/test_runner.zig`**

```zig
_ = @import("compaction_long_context_test.zig");
```

- [ ] **Step 6.1.3: Run the test to verify it passes**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
timeout 180 zig build test --summary all 2>&1 | tail -n 5
```

Expected: `test success` with 1 new test passing. Total tests should now be baseline + 13 (4 envelope + 4 query + 4 tool + 1 e2e).

- [ ] **Step 6.1.4: Verify the install build** (catches lazy-analysis bugs)

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
timeout 180 zig build install:linux:system 2>&1 | tail -n 10
```

Expected: 0 errors in the compile-exe step.

- [ ] **Step 6.1.5: Commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
git add src/ai_workflow/tui/compaction_long_context_test.zig \
        src/ai_workflow/tui/test_runner.zig
git commit -m "test: end-to-end compaction envelope + read_compacted_messages

Pre-seed the DB with realistic message ids, run compactMessageInMemoryNew
over a synthetic message list, then exercise read_compacted_messages
in both index and full modes. Catches integration bugs that the
per-chunk unit tests miss.

Refs: docs/superpowers/plans/2026-06-20-compaction-output-long-context.md"
```

---

## Verification Checklist (run before declaring done)

- [ ] All chunks committed cleanly with descriptive messages.
- [ ] `cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox && timeout 180 zig build test --summary all 2>&1 | tail -n 5` → `test success` with baseline + 13 tests (4 envelope + 4 query + 4 tool + 1 e2e).
- [ ] `cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox && timeout 180 zig build install:linux:system 2>&1 | tail -n 10` → `Build Summary: 4/6 steps succeeded` with 0 compile errors.
- [ ] `git diff HEAD --stat` → no spurious changes; the user's pre-existing workflow.zig diff is preserved AND extended (not reverted).
- [ ] No new files outside the planned scope (`git status` lists only the 4 new files + 5 modifications listed in File Structure).
- [ ] Manual smoke: build the binary, start a session on port 8080, force a compaction (by hitting the threshold), and verify the saved `llm_history` row's `response_content` contains the new envelope tags. The smoke test is OUT OF SCOPE for v1 but the executor should at least confirm the binary builds and runs (no startup crash). See `nalar-http-handler-thin-wrapper-pattern.md` for the manual smoke recipe.

## Out of Scope (future work)

These are deliberately NOT in this plan — they would be follow-up plans if needed:

- **Persistent message ids for in-flight content** (replacing `adhoc_*` ids in the envelope with real DB ids). Requires changing the in-memory `AgentMessage` struct to carry an `id` field; touches `Agent.zig` and the streaming aggregator.
- **Chat UI: collapse/expand `<message_index>` in the chat bubble** (frontend-only). Out of scope; the existing `<compact_messages>` renderer will display the new tags as plain text.
- **HTTP endpoint `POST /api/sessions/:id/compact`** (force compaction on demand). The plumbing exists (`maybeCompactMessagesNew(..., force=true, ...)`); needs a handler + frontend button. Trivial follow-up.
- **Recursive compaction** (compaction of an already-compacted session). Out of scope; would need a new "compaction of compaction" system prompt and envelope.
- **Token-count delta in the envelope** (`<saved_tokens>N</saved_tokens>` between original and compacted). Useful for observability but not required for the long-context story. The data is already available; just needs plumbing.

## Reference Materials

- `~/.config/nalar/memories/nalar-tui-history-tool-call-id-field.md` — reminder that `tool_call_id` is the field to read for tool-result messages, not `tools`.
- `~/.config/nalar/memories/zig-0.16-t-to-t-param-becomes-const.md` — `T → !T` functions get implicit `const` on the parameter. `compactMessageInMemoryNew` already has the local-copy workaround in place; preserve it.
- `~/.config/nalar/memories/nalar-sql-alias-tables.md` — always alias tables in SELECTs.
- `~/.config/nalar/memories/zig-0.16-inmemory-sqlite-test-setup/SKILL.MD` — the `std.Io.Threaded.init + .io()` setup pattern for in-memory SQLite tests.
- `~/.config/nalar/memories/nalar-http-handler-thin-wrapper-pattern.md` — TUI handlers (not HTTP) bypass the `parseFromSliceLeaky`/`valueAlloc` pattern; they go through `tool_registry.execX` + `wrapToolOutput`.
- `~/.config/nalar/memories/multi-agent-file-reverts.md` — if other workers are in the same worktree, commit early and often to avoid file reverts.
