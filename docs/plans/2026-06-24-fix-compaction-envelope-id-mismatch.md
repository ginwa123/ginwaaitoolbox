# Fix compaction envelope: synthetic IDs break `read_compacted_messages` + aggressive 100-char preview truncation

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan.

**Status:** Open. Diagnosis completed `2026-06-24` after user reported "text is truncated" on llm_history row `id=1782255850061275060` (the compacted-summary user message in session `task_1782027225831`).

**Goal:** After this plan ships, the `<compact_messages>` envelope embedded in the compacted-summary user message must (1) carry the **real DB primary keys** of every dropped message so the documented `read_compacted_messages(mode="full", message_ids=...)` retrieval path actually finds rows, and (2) use role-aware preview lengths that don't strip long tool results down to a useless 100-char tag fragment.

---

## Root cause (verified by direct DB inspection)

### Diagnostic facts (session `task_1782027225831`)

| Field | Value |
|---|---|
| Compaction envelope row id | `1782255850061275060` (role=user, is_input=1, is_feed_to_llm=1) |
| Envelope size | 88,986 bytes |
| `<entry>` count in envelope | 358 |
| Total dropped `response_content` bytes | 872,565 |
| Total dropped `tool_calls_json` bytes | 261,860 |
| Total dropped content | **1,134,425 bytes (~1.1 MB)** |
| Largest single dropped tool result | 72,368 bytes (a `write_file` tool result, truncated to 100 chars in envelope) |
| IDs in envelope | synthetic `adhoc_0` … `adhoc_357` |
| Real DB ids of dropped messages | 19-digit timestamps e.g. `1782027251703514461` |
| `SELECT count(*) FROM llm_history WHERE id IN ('adhoc_0','adhoc_1',...)` | **0 rows** |

### Three concrete bugs

**Bug 1 — CRITICAL: synthetic IDs break the retrieval tool.**

`buildCompactionEnvelope` in `src/ai_workflow/tui/workflow.zig:1121` invents
synthetic per-position ids:

```zig
const msg_id = try std.fmt.allocPrint(allocator, "adhoc_{d}", .{i});
```

But the only way the LLM can recover full content is
`read_compacted_messages(mode="full", message_ids="adhoc_5,adhoc_10")`,
which translates to SQL
`WHERE h.id IN ('adhoc_5','adhoc_10')` in `src/ai_workflow/tui/llm_history.zig:1264-1273`.

Those ids do not exist in `llm_history.id` (which is the 19-digit
timestamp primary key). The tool returns zero rows every time. The
`<message_index>` block of the envelope is therefore **unusable** as
a lookup index, contradicting the docstring at line 1076-1077 of
`workflow.zig`:

> "message_index: id+role+preview for every dropped message so the
> agent can reference them later via read_compacted_messages"

**Why the synthetic ids exist at all:** the in-memory
`agent.AgentMessage` struct (in `src/modules/agent/Agent.zig:466-497`)
has no `id` field. The DB row's primary key is loaded into
`TUIHistory.id` by `llm_history.getMessages` (line 1122), then
**silently dropped** by `transform_llm_history_to_agent_message`
(`src/ai_workflow/tui/transform_llm_history_to_agent_messages.zig:114-121`).
By the time `compactMessageInMemoryNew` calls
`buildCompactionEnvelope(messages.items[1..])`, no DB id survives.

**Bug 2 — 100-char preview cap is far too aggressive for tool results.**

`src/ai_workflow/tui/workflow.zig:1126`:

```zig
const preview_trimmed = if (preview.len > 100) preview[0..100] else preview;
```

The largest dropped tool result is **72,368 bytes** (a write_file output).
After this truncation it appears in the envelope as:

```
<tool><name>write_file</name><parameters><parameters><path>/home/ginwa/agentic_coding_zig/ginwaaitoo
```

i.e. 100 chars of XML opening tags. The file's actual content — which
is the entire reason the LLM would want to recall the message — is
gone. The agent has no way to even know what file was written.

The 100-char limit predates the `read_compacted_messages` retrieval
tool. It was the only way to keep the envelope small when the index
was the *only* view of dropped content. With the retrieval tool now
designed to recover full content, the preview can be longer — but
should still be role-aware because tool results dwarf user/assistant
content in this codebase.

**Bug 3 — vision `content_parts` produces empty previews.**

`src/ai_workflow/tui/workflow.zig:1125`:

```zig
const preview = msg.content orelse "";
```

When an `AgentMessage` carries vision data, `content` is `null` and
`content_parts` holds the structured payload (see
`Agent.zig:469` and the transform at
`transform_llm_history_to_agent_messages.zig:83-112`). The envelope's
preview falls back to `""`, so the envelope records `<preview></preview>`
for every vision message — the agent has no signal that an image
attachment existed.

---

## Architecture decisions locked during brainstorming

1. **Add `id: ?[]const u8 = null` to `AgentMessage`** — not a parallel
   slice parameter on `buildCompactionEnvelope`. Reason: the in-memory
   message list already flows through the entire workflow as
   `[]AgentMessage` (see `workflow.zig:420`, `:792`, `:984`, `:1002`,
   `:1120`). Adding a parallel array would require plumbing at every
   call site. Adding an optional field on the struct itself is a
   single-line change that also benefits any future caller that needs
   to trace a message back to its DB row (e.g. SSE event emission,
   audit logging).

2. **Populate `id` in `transform_llm_history_to_agent_message`** — the
   transform already takes a `TUIHistory` and produces an
   `AgentMessage`; the DB primary key is in scope (`message.id`).
   Setting `.id = try allocator.dupe(u8, message.id)` in both the
   tool-result branch (line 14-22) and the user/assistant/system
   branch (line 114-121) is sufficient.

3. **Drop the `adhoc_` synthesis in `buildCompactionEnvelope`** — use
   `msg.id orelse "unknown"` as the fallback. The "unknown" path is
   only reachable for messages that did NOT originate from
   `transform_llm_history_to_agent_message` (e.g. system prompt
   synthesized in-place at `workflow.zig:1046-1064` — but those are
   not in `dropped_messages`, which is `messages.items[1..]`). The
   fallback is defensive code for tests and future callers.

4. **Role-aware preview length**: tool results get **500 chars**, all
   other roles get **200 chars**. Tool results are the most
   information-dense and the most-asked-for-after-compaction; user
   prompts and assistant replies are usually short. The 500/200 split
   keeps the envelope at a reasonable size (358 × 500 + 100 × 200 ≈
   200 KB worst case, vs 88 KB today with 100 chars across the board)
   while making previews actually useful. The hard cap is still in
   place — the read tool handles longer fetches.

5. **Extract text from `content_parts` for vision previews** — when
   `content == null` and `content_parts != null`, concatenate the
   text parts (skipping image parts) into the preview. The order of
   `content_parts` is preserved by the transform (text part first
   when present, then images), so the preview reads naturally.

6. **No backend changes to `getCompactedMessages`** — the SQL filter
   `WHERE h.id IN (...)` already does the right thing once Bug 1 is
   fixed. No schema migration, no new column, no new function.
   `read_compacted_messages.zig` continues to work unchanged.

7. **No changes to the `read_compacted_messages` tool itself** —
   the tool is correctly designed; the envelope was feeding it
   garbage ids. With real ids flowing through, the tool's existing
   `mode="full"` + `message_ids` path produces correct full content
   on the first try.

---

## Files to change

| File | Change |
|---|---|
| `src/modules/agent/Agent.zig` | Add `id: ?[]const u8 = null` field to `AgentMessage`; free in `deinit` |
| `src/ai_workflow/tui/transform_llm_history_to_agent_messages.zig` | Populate `.id` from `message.id` in both branches |
| `src/ai_workflow/tui/workflow.zig` | `buildCompactionEnvelope`: use `msg.id`, role-aware preview length, vision content_parts text extraction |
| `src/ai_workflow/tui/workflow_compaction_envelope_test.zig` | Update assertions (was `<id>adhoc_` → now `<id>h_19_digit`); add tests for real-IDs and role-aware previews |
| `src/ai_workflow/tui/llm_history_compacted_messages_test.zig` | Add a round-trip test that proves: envelope ids are real DB ids, `read_compacted_messages(mode="full", message_ids=[envelope_id])` returns the full content |

No changes to:
- `src/modules/agent/tools/read_compacted_messages.zig` (tool is correct as-is)
- `src/ai_workflow/tui/llm_history.zig` (SQL filter is correct as-is)
- Any migration or schema (no DB change)

---

## Tech Stack

Zig 0.16 + `std.Io.Threaded` + `std.ArrayList(u8).empty`. No new dependencies.

---

## Implementation chunks

### Chunk 1 — `AgentMessage.id` field

**File:** `src/modules/agent/Agent.zig`

Add the field. The struct is at line 466-497:

```zig
pub const AgentMessage = struct {
    /// DB primary key from `llm_history.id` (19-digit timestamp string).
    /// NULL for messages synthesized in-memory (e.g. system prompts at
    /// workflow.zig:1046-1064). Populated by
    /// `transform_llm_history_to_agent_message` for messages loaded from
    /// the DB. Used by `buildCompactionEnvelope` to embed real ids in
    /// the `<compact_messages>` envelope so `read_compacted_messages`
    /// can find them.
    id: ?[]const u8 = null,
    role: Role,
    content: ?[]const u8,
    content_parts: ?[]const ContentPart = null,
    tool_calls: ?[]ToolCall = null,
    tool_call_id: ?[]const u8 = null,
    reasoning_content: ?[]const u8 = null,

    pub fn deinit(self: *const AgentMessage, allocator: std.mem.Allocator) void {
        if (self.id) |i| allocator.free(i);     // ← ADD THIS LINE
        if (self.content) |c| allocator.free(c);
        // ... rest unchanged
    }
};
```

The `id` field is added FIRST in the struct (before `role`) so the
newly-added line stands out at code review time and any future
"struct field order" linter rule is satisfied. The free in `deinit`
goes BEFORE `content` to match the declaration order.

**Regression tests** (in `src/modules/agent/Agent_test.zig` if it
exists; otherwise add inline assertions to existing tests):

1. `AgentMessage.deinit frees id when set`
2. `AgentMessage.deinit does NOT crash when id is null`

These verify the deinit ordering: `id` is freed before the other
fields, and the optional chain handles `null` cleanly.

### Chunk 2 — populate `id` in transform

**File:** `src/ai_workflow/tui/transform_llm_history_to_agent_messages.zig`

Two branches to update:

**Branch 1 — tool result (lines 14-22):**
```zig
if (role == .tool) {
    const agentMessage = agent.AgentMessage{
        .id = try allocator.dupe(u8, message.id),     // ← ADD
        .role = .tool,
        .content = try allocator.dupe(u8, message.response_content),
        .tool_call_id = try allocator.dupe(u8, message.tool_call_id orelse ""),
    };
    try messages.append(allocator, agentMessage);
    return messages.toOwnedSlice(allocator);
}
```

**Branch 2 — user/assistant/system (lines 114-121):**
```zig
const agentMessage = agent.AgentMessage{
    .id = try allocator.dupe(u8, message.id),         // ← ADD
    .role = role,
    .content = if (content_parts != null) null else content,
    .content_parts = content_parts,
    .tool_calls = tool_calls,
    .reasoning_content = reasoning_content,
};
```

The transform always produces a fresh `agentMessage` (or two, in the
vision case), so the `dupe` happens on the right allocator (the one
passed in) and the lifecycle matches the existing fields. No `deinit`
changes needed in the transform — callers still own the returned
`[]AgentMessage` and free via `AgentMessage.deinit`.

**Regression test:** add to `transform_llm_history_to_agent_messages_test.zig`:

```zig
test "transform populates AgentMessage.id from TUIHistory.id" {
    const alloc = testing.allocator;
    const tui_history = TUIHistory{
        .id = try alloc.dupe(u8, "1782027251703514461"),
        // ... rest of fields ...
        .role = try alloc.dupe(u8, "user"),
        .response_content = try alloc.dupe(u8, "hello"),
        // ... etc ...
    };
    defer tui_history.deinit(alloc);

    const msgs = try transform_llm_history_to_agent_message(alloc, tui_history);
    defer {
        for (msgs) |*m| m.deinit(alloc);
        alloc.free(msgs);
    }

    try testing.expect(msgs.len > 0);
    try testing.expect(msgs[0].id != null);
    try testing.expectEqualStrings("1782027251703514461", msgs[0].id.?);
}
```

### Chunk 3 — `buildCompactionEnvelope` rewrites

**File:** `src/ai_workflow/tui/workflow.zig`

Three changes to the loop at lines 1119-1153:

**Change 3a — use real id:**
```zig
// Before:
const msg_id = try std.fmt.allocPrint(allocator, "adhoc_{d}", .{i});
defer allocator.free(msg_id);

// After:
const msg_id = msg.id orelse "unknown";
// msg.id is borrowed (owned by AgentMessage); do NOT free.
```

**Change 3b — role-aware preview length:**
```zig
// Before:
const preview_trimmed = if (preview.len > 100) preview[0..100] else preview;

// After:
const preview_max: usize = if (msg.role == .tool) 500 else 200;
const preview_trimmed = if (preview.len > preview_max)
    preview[0..preview_max]
else
    preview;
```

**Change 3c — vision content_parts text extraction:**
```zig
// Before:
const preview = msg.content orelse "";

// After:
// Prefer explicit content. If the message carries vision
// content_parts instead (content == null), concatenate the text
// parts in order. Image parts are skipped — they have no
// string preview. The result may be empty if the message is
// pure-vision with no accompanying text; that is OK, the entry
// still records the id+role so the agent can fetch the full
// row via read_compacted_messages.
var preview_buf: std.ArrayList(u8) = .empty;
defer preview_buf.deinit(allocator);

if (msg.content) |c| {
    try preview_buf.appendSlice(allocator, c);
} else if (msg.content_parts) |parts| {
    for (parts) |part| {
        if (part.text) |t| try preview_buf.appendSlice(allocator, t);
        // image_url parts contribute no preview text.
    }
}

const preview: []const u8 = preview_buf.items;
const preview_max: usize = if (msg.role == .tool) 500 else 200;
const preview_trimmed = if (preview.len > preview_max)
    preview[0..preview_max]
else
    preview;
```

The `preview_buf` is local to the iteration; `defer preview_buf.deinit`
fires on the next iteration boundary, freeing the per-entry scratch.
`preview_buf.items` is borrowed (no extra `dupe`) so the rest of the
loop body (`xml_escape` → `env.print`) is unchanged.

**Tool-result comment update** (line 1137-1140): remove the obsolete
sentence "the read_compacted_messages tool can fetch it from the DB
row" — that promise is now backed by working ids. Replace with:

```zig
// For tool-result messages, surface tool_call_id so the agent
// can match results back to calls. tool_name is also surfaced
// for the same reason. Both are available on the in-memory
// AgentMessage struct (tool_call_id directly; tool_name via
// the first tool_call.function.name when tool_calls is set,
// otherwise fall back to "unknown").
if (msg.role == .tool) {
    const tcid = msg.tool_call_id orelse "";
    const tcid_escaped = try helpers.xml_escape(allocator, tcid);
    defer allocator.free(tcid_escaped);
    try env.print(allocator, "      <tool_call_id>{s}</tool_call_id>\n", .{tcid_escaped});

    // Surface tool_name too — for tool messages there is exactly one
    // tool_call; if absent (synthetic test fixtures), write "unknown".
    const tool_name: []const u8 = if (msg.tool_calls) |tcs|
        if (tcs.len > 0) tcs[0].function.name else "unknown"
    else
        "unknown";
    const tool_name_escaped = try helpers.xml_escape(allocator, tool_name);
    defer allocator.free(tool_name_escaped);
    try env.print(allocator, "      <tool_name>{s}</tool_name>\n", .{tool_name_escaped});
}
```

This makes the envelope self-sufficient: the agent sees id, role,
tool_call_id, tool_name, and a 500-char preview without ever needing
`read_compacted_messages` for routine tool-result identification.

### Chunk 4 — update envelope test assertions

**File:** `src/ai_workflow/tui/workflow_compaction_envelope_test.zig`

**Test at line 166-207 — update id assertion (line 205):**

```zig
// Before:
try testing.expect(std.mem.indexOf(u8, summary, "<id>adhoc_") != null);

// After:
// Envelope ids must be the real DB primary keys (19-digit timestamps),
// not synthetic adhoc_<n> markers. This is the contract that makes
// read_compacted_messages(mode="full", message_ids=[envelope_id])
// work — see getCompactedMessages WHERE h.id IN (...) filter.
try testing.expect(std.mem.indexOf(u8, summary, "<id>1782") != null);
```

**Test at line 209-240 — tool_call_id still passes**, but add a new
assertion for tool_name:

```zig
// ADD after the existing tool_call_id assertion (after line 239):
try testing.expect(std.mem.indexOf(u8, summary, "<tool_name>bash</tool_name>") != null);
```

**Add a new test for role-aware preview length:**

```zig
test "buildCompactionEnvelope: tool results get 500-char preview, others 200-char" {
    // Build a 1000-char tool result and a 1000-char user message.
    // After compaction, the tool's preview should be 500 chars and the
    // user's preview should be 200 chars.
    var s = try setupDb();
    defer teardownDb(&s);
    const alloc = testing.allocator;

    const long_text = try alloc.alloc(u8, 1000);
    defer alloc.free(long_text);
    @memset(long_text, 'x');

    var messages: std.ArrayList(agent.AgentMessage) = .empty;
    try messages.append(alloc, .{ .role = .system, .content = try alloc.dupe(u8, "sys") });
    try messages.append(alloc, .{
        .id = try alloc.dupe(u8, "1782027251703514461"),
        .role = .user,
        .content = try alloc.dupe(u8, long_text),
    });
    try messages.append(alloc, .{
        .id = try alloc.dupe(u8, "1782027292879102675"),
        .role = .tool,
        .content = try alloc.dupe(u8, long_text),
        .tool_call_id = try alloc.dupe(u8, "tc_1"),
    });

    var lg = logger_mod.Logger.init(alloc, std.testing.io, .{});
    defer lg.deinit();

    const new_messages = try workflow.compactMessageInMemoryNew(
        alloc, messages, "summary", "sess_500", "gpt-4o", "/tmp",
        &s.db, s.threaded.io(), &lg,
    );
    defer {
        for (new_messages.items) |*m| m.deinit(alloc);
        var nm_owned = new_messages;
        nm_owned.deinit(alloc);
    }

    const summary = new_messages.items[1].content.?;

    // user preview: 200 chars
    try testing.expect(std.mem.indexOf(u8, summary,
        "<id>1782027251703514461</id>") != null);
    try testing.expect(std.mem.indexOf(u8, summary,
        "<role>user</role>") != null);

    // tool preview: 500 chars. Find the user entry's preview and the
    // tool entry's preview by their enclosing <entry>...</entry>.
    const user_entry_start = std.mem.indexOf(u8, summary,
        "<id>1782027251703514461</id>").?;
    const tool_entry_start = std.mem.indexOf(u8, summary,
        "<id>1782027292879102675</id>").?;
    const user_entry_end = std.mem.indexOfPos(u8, summary, user_entry_start, "</entry>").?;
    const tool_entry_end = std.mem.indexOfPos(u8, summary, tool_entry_start, "</entry>").?;

    const user_entry = summary[user_entry_start..user_entry_end];
    const tool_entry = summary[tool_entry_start..tool_entry_end];

    // Count the preview tag contents length.
    const user_preview_match = std.mem.indexOf(u8, user_entry, "<preview>").?;
    const user_preview_close = std.mem.indexOf(u8, user_entry, "</preview>").?;
    const user_preview_len = user_preview_close - user_preview_match - "<preview>".len;
    try testing.expectEqual(@as(usize, 200), user_preview_len);

    const tool_preview_match = std.mem.indexOf(u8, tool_entry, "<preview>").?;
    const tool_preview_close = std.mem.indexOf(u8, tool_entry, "</preview>").?;
    const tool_preview_len = tool_preview_close - tool_preview_match - "<preview>".len;
    try testing.expectEqual(@as(usize, 500), tool_preview_len);
}
```

**Add a new test for vision content_parts:**

```zig
test "buildCompactionEnvelope: vision message preview extracts text from content_parts" {
    var s = try setupDb();
    defer teardownDb(&s);
    const alloc = testing.allocator;

    const part_text = "What is in this image?";

    const image_part = agent.ContentPart{
        .part_type = "image_url",
        .text = null,
        .image_url = .{
            .url = try alloc.dupe(u8, "data:image/png;base64,iVBORw0..."),
            .detail = null,
        },
    };
    const text_part = agent.ContentPart{
        .part_type = "text",
        .text = try alloc.dupe(u8, part_text),
        .image_url = null,
    };
    const content_parts = try alloc.dupe(agent.ContentPart, &[_]agent.ContentPart{ text_part, image_part });

    var messages: std.ArrayList(agent.AgentMessage) = .empty;
    try messages.append(alloc, .{ .role = .system, .content = try alloc.dupe(u8, "sys") });
    try messages.append(alloc, .{
        .id = try alloc.dupe(u8, "1782027251703514461"),
        .role = .user,
        .content = null,
        .content_parts = content_parts,
    });

    var lg = logger_mod.Logger.init(alloc, std.testing.io, .{});
    defer lg.deinit();

    const new_messages = try workflow.compactMessageInMemoryNew(
        alloc, messages, "summary", "sess_vision", "gpt-4o", "/tmp",
        &s.db, s.threaded.io(), &lg,
    );
    defer {
        for (new_messages.items) |*m| m.deinit(alloc);
        var nm_owned = new_messages;
        nm_owned.deinit(alloc);
    }

    const summary = new_messages.items[1].content.?;
    // Vision preview must contain the text-part content, NOT be empty.
    try testing.expect(std.mem.indexOf(u8, summary, "<preview>What is in this image?</preview>") != null);
}
```

### Chunk 5 — round-trip test in `llm_history_compacted_messages_test.zig`

**File:** `src/ai_workflow/tui/llm_history_compacted_messages_test.zig`

Add a test that proves the contract end-to-end:

```zig
test "compaction envelope ids are findable by read_compacted_messages" {
    // Regression: the envelope was using synthetic adhoc_N ids that
    // didn't exist in llm_history.id, so read_compacted_messages
    // returned 0 rows for every lookup. After this fix, the ids
    // embedded in the envelope MUST match real DB primary keys,
    // so the read tool can fetch full content for them.
    //
    // This test reproduces the bug on stashed (pre-fix) code: the
    // getCompactedMessages call with envelope ids returns 0 rows.
    // After the fix, it returns the original messages.

    var s = try setupDb();
    defer teardownDb(&s);
    const alloc = testing.allocator;

    // Insert 3 messages with known ids, mark them is_feed_to_llm=0.
    const ids = [_][]const u8{
        "1000000000000000001",
        "1000000000000000002",
        "1000000000000000003",
    };
    for (ids) |id| {
        try s.db.exec(alloc,
            \\INSERT INTO llm_history (id, session_id, model, response_content,
            \\    role, is_feed_to_llm, created_at)
            \\VALUES (?, 'sess_roundtrip', 'gpt-4o', ?, 'tool', 0, '2026-01-01 00:00:00')
        , &.{ id, "full tool result content" });
    }

    // Build an envelope with those ids as the in-memory message list.
    var messages: std.ArrayList(agent.AgentMessage) = .empty;
    try messages.append(alloc, .{ .role = .system, .content = try alloc.dupe(u8, "sys") });
    for (ids) |id| {
        try messages.append(alloc, .{
            .id = try alloc.dupe(u8, id),
            .role = .tool,
            .content = try alloc.dupe(u8, "preview text"),
            .tool_call_id = try alloc.dupe(u8, "tc_x"),
        });
    }

    var lg = logger_mod.Logger.init(alloc, std.testing.io, .{});
    defer lg.deinit();

    const new_messages = try workflow.compactMessageInMemoryNew(
        alloc, messages, "summary", "sess_roundtrip", "gpt-4o", "/tmp",
        &s.db, s.threaded.io(), &lg,
    );
    defer {
        for (new_messages.items) |*m| m.deinit(alloc);
        var nm_owned = new_messages;
        nm_owned.deinit(alloc);
    }

    const summary = new_messages.items[1].content.?;

    // Pull each id OUT of the envelope and verify it round-trips through
    // read_compacted_messages. With the synthetic-id bug, this returned
    // 0 rows; with real ids, it returns the original 3 messages.
    for (ids) |id| {
        const needle = try std.fmt.allocPrint(alloc, "<id>{s}</id>", .{id});
        defer alloc.free(needle);
        try testing.expect(std.mem.indexOf(u8, summary, needle) != null);

        const found = try llm_history.getCompactedMessages(alloc, &s.db,
            "sess_roundtrip",
            .{ .message_ids = &[_][]const u8{id}, .limit = 10 });
        defer {
            for (found) |m| {
                var copy = m;
                copy.deinit(alloc);
            }
            alloc.free(found);
        }
        try testing.expectEqual(@as(usize, 1), found.len);
        try testing.expectEqualStrings(id, found[0].id);
        try testing.expectEqualStrings("full tool result content", found[0].content);
    }
}
```

---

## Verification

After all chunks land, run the full suite:

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
timeout 180 zig build test --summary all 2>&1 | tail -n 10
# Expected: same pass count as before the change + 4 new tests
# (AgentMessage.id deinit × 2, transform populates id, role-aware preview,
#  vision preview, round-trip).

timeout 180 zig build install:linux:system 2>&1 | tail -n 10
# Expected: "Build Summary: 4/6 steps succeeded" — install:linux:system
# is the step that catches T → T parameter const-cast bugs that
# zig build test misses (see memory zig-0.16-t-to-t-param-becomes-const).
# The cp to /usr/local/bin/nalar fails harmlessly on permission.
```

Then exercise the fix end-to-end against the live session `task_1782027225831`:

```bash
# Start a fresh nalar on port 8080 (NEVER kill the one on 8081)
./zig-out/bin/nalar --port 8080 &

# In a browser, open the chat for session task_1782027225831.
# Send a message that requires the LLM to recall a previously-dropped
# tool result. Verify:
# 1. The agent sees a <compact_messages> envelope with REAL DB ids
#    (19-digit timestamps like 1782027251703514461), NOT adhoc_N.
# 2. When the agent calls read_compacted_messages(mode="full",
#    message_ids="1782027251703514461"), it returns the FULL tool
#    result, not an error or empty response.
# 3. Tool-result previews in the envelope are 500 chars, not 100.
```

Manual smoke test of the SQL contract:

```bash
sqlite3 ~/.config/nalar/agent.db "
SELECT h.id, h.role, length(h.response_content)
FROM llm_history h
WHERE h.session_id = 'task_1782027225831'
  AND h.is_feed_to_llm = 0
  AND h.id IN ('1782027251703514461', '1782027292873814871', '1782027292879102675');
"
# Expected: 3 rows, each with full response_content.
# Before the fix: 0 rows (because envelope used adhoc_* ids, not these).
```

---

## Risks and mitigations

**Risk 1 — Existing compacted envelopes still have `adhoc_N` ids.**
Old sessions (this one included) have envelopes in `llm_history` from
before the fix. The agent cannot recover their full content because
the adhoc_N ids don't exist. **Mitigation:** document this in the
changelog; future compaction runs will use real ids. No migration of
old envelopes is needed — those messages can still be inspected via
direct SQL or by triggering a re-compaction.

**Risk 2 — `transform_llm_history_to_agent_message` is called from
multiple places.** Adding `.id = try allocator.dupe(...)` requires the
allocator to outlive the resulting `AgentMessage`. All current
callers pass `ctx.allocator` (per-request arena) which is freed at
request end, so the lifetime is fine. The new field is owned by the
same allocator as the rest of the struct.

**Risk 3 — The `AgentMessage` struct's serialization (via `toJson` if
it exists) will now include the `id` field.** If any caller
serializes `AgentMessage` for transmission to the LLM, the id will
leak into the wire format. **Mitigation:** the LLM provider expects
`{role, content, content_parts, tool_calls, tool_call_id,
reasoning_content}` — adding a new optional field is forward-
compatible (unknown fields are ignored) per the OpenAI/Anthropic
JSON schema. Verify by sending one request after the fix and
checking the SSE stream — the response should still parse.

**Risk 4 — Test fixtures in `workflow_compaction_envelope_test.zig`
use synthetic `agent.AgentMessage` literals without `.id`.** After
the fix, those messages will fall through the `"unknown"` fallback.
The updated assertions check for real ids only where the test
fixture provides them; for fixture-only tests, add an explicit
`.id = try alloc.dupe(u8, "...")` to the literal so the assertions
can match deterministically.

---

## Out of scope (documented for follow-up)

- **Old compacted envelopes with `adhoc_N` ids.** No migration; users
  with old envelopes just get reduced recall. If this becomes a
  product issue, write a one-time SQL UPDATE that joins envelopes to
  dropped messages by `created_at` order and patches the `<id>`
  fields. Out of scope for this fix.
- **`read_compacted_messages` tool description rewrite.** The
  description at `read_compacted_messages.zig:54-72` mentions
  "100-char preview" — that is still true for the tool's OWN index
  mode (line 246), so the description stays accurate. No change.
- **Increasing the envelope's `tool_call_id` length limit or adding
  a `<tool_args>` field.** Useful for the agent to see what command
  was run without re-fetching — but adds 100s of bytes per entry.
  Out of scope; can be added later if users report "I had to call
  read_compacted_messages just to see what command I ran".

---

## Summary

- 3 root-cause bugs identified (synthetic ids, aggressive 100-char
  preview, vision content_parts ignored).
- Quantified impact on session `task_1782027225831`: 1.1 MB of
  dropped content reduced to 89 KB envelope, with **all 358 dropped
  messages inaccessible** via the documented retrieval tool.
- 5 surgical code changes across 5 files. No schema migration, no
  new dependencies, no breaking API changes.
- 5 new regression tests + 1 updated assertion. All tests red-green
  verified before commit (per project convention).
- End-to-end verification via `zig build test`,
  `zig build install:linux:system`, and a manual smoke test on the
  live session.