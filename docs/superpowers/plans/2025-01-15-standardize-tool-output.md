# Standardize Tool Output XML

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Wrap every tool result (success or error) in a uniform XML envelope — `<tool><name>...</name><parameters>...</parameters><success>true|false</success><error>...</error><data>...</data></tool>` — so the LLM, the frontend display, and any future consumer can read a single consistent format. Existing tool-specific inner XML is preserved verbatim inside `<data>` so the 13 `tool_outputs/*.vue` components and the existing `toXmlSuccess`/`toXmlError` helpers in each tool module continue to work unchanged.

**Architecture:**
- **Backend (Zig):** New module `tool_output_wrapper.zig` exposes `wrapToolResult` (the envelope builder) and `unwrapToolResult` (a parser, useful for tests and re-import scenarios). `handle_tool.zig` wraps every tool output (including Zig errors caught at `dispatchTool` and MCP errors caught at `dispatchMCP`) before passing it to `saveAndSendToolResult`. The inner `<data>` field holds the existing tool-specific XML untouched — `<path>`, `<content>`, `<error>`, `<loaded>`, `<diff_view>`, etc. are all preserved.
- **Frontend (Vue/TS):** New helper `helpers/unwrapToolOutput.ts` parses the envelope and returns `{ name, parameters, success, error, data }`. `ChatView.vue` uses the helper to (a) pass `data` to the existing `tool_outputs/*.vue` components (so they keep parsing their own tags unchanged), (b) display a consistent `tool_name → ✓ data preview` or `tool_name → ✗ error` summary in the fallback `renderResponse` branch, and (c) add a small status badge in the new template slot.

**Tech Stack:** Zig 0.15.2 (backend, `nalarcore`), Vue 3 + TypeScript (frontend, `apps/desktop`), Vite/Vitest.

---

## File Structure

### New files
- `src/ai_workflow/tui/tool_output_wrapper.zig` — envelope builder + parser.
- `src/ai_workflow/tui/tool_output_wrapper_test.zig` — unit tests for the wrapper.
- `src/apps/desktop/src/helpers/unwrapToolOutput.ts` — frontend TypeScript helper.
- `src/apps/desktop/src/helpers/unwrapToolOutput.spec.ts` — Vitest unit tests for the helper.

### Modified files
- `src/ai_workflow/tui/handle_tool.zig` — wrap every tool result before saving (Chunk 2).
- `src/ai_workflow/tui/test_runner.zig` — register the new test file (Chunk 1).
- `src/apps/desktop/src/components/ChatView.vue` — use the unwrap helper and add a status badge slot (Chunk 3).
- `src/apps/desktop/src/components/tool_outputs/*.vue` — **no changes** required (the inner `<data>` content is what they already receive). Verified by reading the 5 most-used components: `ReadFile.vue`, `TextReplace.vue`, `RemoveSkill.vue`, `WriteFile.vue`, `SpawnSubAgent.vue`.

### Out of scope
- Rewriting the inner XML format of any individual tool (e.g. `read_file`'s `<path>`, `text_replace`'s `<diff_view>`). The inner format is preserved exactly so all downstream parsers keep working.
- The `set_agent_properties` and `update_activity` tools already have their own custom inner formats — they get wrapped the same way.
- Changing how tool results are stored in the DB (`response_content` column remains the wrapped XML, exactly as it stored the unwrapped XML before).

---

## Data Flow (before / after)

### Before
```
LLM ── tool_call(name, arguments) ──> dispatchTool(ctx, tool_call)
                                          │
                                          ├─> execReadFile / execBash / ...
                                          │      │
                                          │      └─> ToolExecResult.output = "<path>/foo</path>..."
                                          │
                                          └─> saveAndSendToolResult(...)
                                                  │
                                                  └─> llm_history.saveMessage(content: "<path>/foo</path>...")

Frontend ──> SSE "full" event { content: "<path>/foo</path>..." }
       ──> ChatView.vue: renderResponse() parses with regex
       ──> tool_outputs/ReadFile.vue: parses with regex again
```

### After
```
LLM ── tool_call(name, arguments) ──> dispatchTool(ctx, tool_call)
                                          │
                                          ├─> execReadFile / execBash / ...
                                          │      │
                                          │      └─> ToolExecResult.output = "<path>/foo</path>..."
                                          │
                                          └─> saveAndSendToolResult(..., wrap_with(name, arguments, "<path>/foo</path>..."))
                                                  │
                                                  └─> llm_history.saveMessage(content: "<tool><name>read_file</name><parameters>{...}</parameters><success>true</success><data><path>/foo</path>...</data></tool>")

Frontend ──> SSE "full" event { content: "<tool>...</tool>" }
       ──> ChatView.vue: unwrapToolOutput(content) → { name, parameters, success, error, data }
       ──> tool_outputs/ReadFile.vue: receives `data` = "<path>/foo</path>..." (unchanged from before)
```

---

## Wrapper XML Format

```xml
<tool>
  <name>{name}</name>
  <parameters>{xml-escaped JSON arguments}</parameters>
  <success>{true|false}</success>
  <error>{xml-escaped error message, omitted when success=true}</error>
  <data>{xml-escaped existing tool output, omitted when error is present}</data>
</tool>
```

**Rules:**
- `name` is a fixed known tool name; not user input, so no escaping needed (but call `xmlEscape` for safety).
- `parameters` is the raw JSON string from `tool_call.function.arguments`; always present even on error; XML-escaped.
- `success` is `"true"` or `"false"`.
- `error` is the human-readable error message (XML-escaped). Omit the tag entirely when `success=true` to keep successful output clean.
- `data` is the existing tool-specific XML output (XML-escaped). Omit the tag entirely on error (the error message is in `<error>`).

XML escaping is the same as `llm_history.zig:762` `xmlEscape` (handles `<`, `>`, `&`, `"`, `'`) — reuse that exact function so the codebase has one canonical escape implementation.

**Why XML-escape `<data>` instead of using CDATA:** CDATA would break if any tool ever produces `]]>` in its output (e.g. an LLM-generated string in a future tool). XML escape is safe for any input and matches the existing convention in the codebase.

---

# Chunk 1: Backend wrapper module + tests

**Goal:** Create the new `tool_output_wrapper.zig` module with `wrapToolResult` and `unwrapToolResult` (for tests), and unit tests proving round-trip and escape behavior. No callsite changes yet — this is just the building block.

### Task 1: Create the wrapper module

**Files:**
- Create: `src/ai_workflow/tui/tool_output_wrapper.zig`

- [ ] **Step 1.1: Write the failing test file**

Create `src/ai_workflow/tui/tool_output_wrapper_test.zig`:

```zig
const std = @import("std");
const testing = std.testing;
const tool_output_wrapper = @import("tool_output_wrapper.zig");

test "wrapToolResult - success with all fields" {
    const allocator = testing.allocator;
    const out = try tool_output_wrapper.wrapToolResult(
        allocator,
        "read_file",
        "{\"path\":\"/foo/bar.txt\"}",
        true,
        null,
        "<path>/foo/bar.txt</path><content>hello</content>",
    );
    defer allocator.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "<tool>") != null);
    try testing.expect(std.mem.indexOf(u8, out, "<name>read_file</name>") != null);
    try testing.expect(std.mem.indexOf(u8, out, "<parameters>{&quot;path&quot;:&quot;/foo/bar.txt&quot;}</parameters>") != null);
    try testing.expect(std.mem.indexOf(u8, out, "<success>true</success>") != null);
    try testing.expect(std.mem.indexOf(u8, out, "<data>") != null);
    try testing.expect(std.mem.indexOf(u8, out, "&lt;path&gt;/foo/bar.txt&lt;/path&gt;") != null);
    try testing.expect(std.mem.indexOf(u8, out, "</tool>") != null);
    try testing.expect(std.mem.indexOf(u8, out, "<error>") == null);
}

test "wrapToolResult - error case omits data and emits error" {
    const allocator = testing.allocator;
    const out = try tool_output_wrapper.wrapToolResult(
        allocator,
        "read_file",
        "{\"path\":\"/missing\"}",
        false,
        "File not found",
        null,
    );
    defer allocator.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "<success>false</success>") != null);
    try testing.expect(std.mem.indexOf(u8, out, "<error>File not found</error>") != null);
    try testing.expect(std.mem.indexOf(u8, out, "<data>") == null);
}

test "wrapToolResult - empty parameters string is emitted" {
    const allocator = testing.allocator;
    const out = try tool_output_wrapper.wrapToolResult(
        allocator,
        "list_skills",
        "",
        true,
        null,
        "<skills><skill>...</skill></skills>",
    );
    defer allocator.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "<parameters></parameters>") != null);
}

test "wrapToolResult - data with special characters is escaped" {
    const allocator = testing.allocator;
    const out = try tool_output_wrapper.wrapToolResult(
        allocator,
        "bash",
        "{\"command\":\"echo \\\"<hi>\\\"\"}",
        true,
        null,
        "<stdout><hi> & \"world\"</stdout>",
    );
    defer allocator.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "<stdout>&lt;hi&gt; &amp; &quot;world&quot;</stdout>") != null);
}

test "unwrapToolResult - round-trip" {
    const allocator = testing.allocator;
    const original = "<path>/foo</path><content>hello world</content>";
    const wrapped = try tool_output_wrapper.wrapToolResult(
        allocator,
        "read_file",
        "{\"path\":\"/foo\"}",
        true,
        null,
        original,
    );
    defer allocator.free(wrapped);

    const parsed = try tool_output_wrapper.unwrapToolResult(allocator, wrapped);
    defer parsed.deinit(allocator);

    try testing.expectEqualStrings("read_file", parsed.name);
    try testing.expectEqualStrings("{\"path\":\"/foo\"}", parsed.parameters);
    try testing.expect(parsed.success);
    try testing.expect(parsed.error_message == null);
    try testing.expectEqualStrings(original, parsed.data.?);
}

test "unwrapToolResult - error case round-trip" {
    const allocator = testing.allocator;
    const wrapped = try tool_output_wrapper.wrapToolResult(
        allocator,
        "read_file",
        "{\"path\":\"/missing\"}",
        false,
        "File not found: /missing",
        null,
    );
    defer allocator.free(wrapped);

    const parsed = try tool_output_wrapper.unwrapToolResult(allocator, wrapped);
    defer parsed.deinit(allocator);

    try testing.expectEqualStrings("read_file", parsed.name);
    try testing.expect(!parsed.success);
    try testing.expectEqualStrings("File not found: /missing", parsed.error_message.?);
    try testing.expect(parsed.data == null);
}

test "wrapToolResult - allocates and caller owns" {
    const allocator = testing.allocator;
    const out = try tool_output_wrapper.wrapToolResult(
        allocator,
        "bash",
        "{}",
        true,
        null,
        "ok",
    );
    defer allocator.free(out);
    // The result must be a fresh allocation (not a static string)
    try testing.expect(out.len > 0);
}
```

- [ ] **Step 1.2: Run tests to verify they fail**

Run: `cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox && timeout 180 zig build test 2>&1 | tail -n 30`
Expected: compilation error — `tool_output_wrapper.zig` does not exist.

- [ ] **Step 1.3: Implement the wrapper module**

Create `src/ai_workflow/tui/tool_output_wrapper.zig`:

```zig
const std = @import("std");

/// Parsed result of unwrapping a `<tool>...</tool>` envelope.
/// All fields are owned by the caller; call `deinit` to free.
pub const Unwrapped = struct {
    name: []const u8,
    parameters: []const u8,
    success: bool,
    error_message: ?[]const u8 = null,
    data: ?[]const u8 = null,

    pub fn deinit(self: Unwrapped, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.parameters);
        if (self.error_message) |em| allocator.free(em);
        if (self.data) |d| allocator.free(d);
    }
};

/// XML-escape special characters. Identical to `llm_history.zig:762`
/// `xmlEscape` — re-implemented here to keep this module self-contained
/// (so future imports of tool_output_wrapper don't pull in llm_history's
/// sqlite/agent dependencies).
fn xmlEscape(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    var result = std.ArrayList(u8).empty;
    errdefer result.deinit(allocator);

    for (s) |c| {
        switch (c) {
            '<' => try result.appendSlice(allocator, "&lt;"),
            '>' => try result.appendSlice(allocator, "&gt;"),
            '&' => try result.appendSlice(allocator, "&amp;"),
            '"' => try result.appendSlice(allocator, "&quot;"),
            '\'' => try result.appendSlice(allocator, "&apos;"),
            else => try result.append(allocator, c),
        }
    }

    return try result.toOwnedSlice(allocator);
}

/// Wrap a tool result in the standardized `<tool>...</tool>` envelope.
///
/// On success: emits `<data>` (the existing tool-specific XML output).
/// On error: emits `<error>` (a human-readable message) and omits `<data>`.
///
/// `parameters` is the raw JSON arguments string from the tool call
/// (e.g. `{"path":"/foo"}`). It is XML-escaped and always emitted.
///
/// The returned string is owned by the caller; free with `allocator.free`.
pub fn wrapToolResult(
    allocator: std.mem.Allocator,
    name: []const u8,
    parameters: []const u8,
    success: bool,
    error_message: ?[]const u8,
    data: ?[]const u8,
) ![]u8 {
    const escaped_name = try xmlEscape(allocator, name);
    defer allocator.free(escaped_name);
    const escaped_params = try xmlEscape(allocator, parameters);
    defer allocator.free(escaped_params);

    const success_str = if (success) "true" else "false";

    if (success) {
        const data_or_empty = data orelse "";
        const escaped_data = try xmlEscape(allocator, data_or_empty);
        defer allocator.free(escaped_data);
        return try std.fmt.allocPrint(
            allocator,
            "<tool><name>{s}</name><parameters>{s}</parameters><success>{s}</success><data>{s}</data></tool>",
            .{ escaped_name, escaped_params, success_str, escaped_data },
        );
    } else {
        const err_or_empty = error_message orelse "unknown error";
        const escaped_err = try xmlEscape(allocator, err_or_empty);
        defer allocator.free(escaped_err);
        return try std.fmt.allocPrint(
            allocator,
            "<tool><name>{s}</name><parameters>{s}</parameters><success>{s}</success><error>{s}</error></tool>",
            .{ escaped_name, escaped_params, success_str, escaped_err },
        );
    }
}

/// Parse a `<tool>...</tool>` envelope back into its parts.
/// Returns `error.MalformedToolEnvelope` if the input doesn't start with
/// `<tool>` and end with `</tool>`, or if required fields are missing.
///
/// The returned `Unwrapped` is owned by the caller; call `.deinit(allocator)`.
pub fn unwrapToolResult(allocator: std.mem.Allocator, content: []const u8) !Unwrapped {
    if (!std.mem.startsWith(u8, content, "<tool>")) return error.MalformedToolEnvelope;
    if (!std.mem.endsWith(u8, content, "</tool>")) return error.MalformedToolEnvelope;

    // Strip the outer <tool>...</tool>
    const inner = content["<tool>".len .. content.len - "</tool>".len];

    // Helper: find the first occurrence of `<tag>` and its matching `</tag>`.
    const findTag = struct {
        fn run(haystack: []const u8, tag: []const u8) ?[]const u8 {
            const open_seq = std.fmt.allocPrint(allocator, "<{s}>", .{tag}) catch return null;
            defer allocator.free(open_seq);
            const close_seq = std.fmt.allocPrint(allocator, "</{s}>", .{tag}) catch return null;
            defer allocator.free(close_seq);
            const open_idx = std.mem.indexOf(u8, haystack, open_seq) orelse return null;
            const value_start = open_idx + open_seq.len;
            const close_idx = std.mem.indexOf(u8, haystack[value_start..], close_seq) orelse return null;
            return haystack[value_start .. value_start + close_idx];
        }
    }.run;

    const name_raw = findTag(inner, "name") orelse return error.MalformedToolEnvelope;
    const params_raw = findTag(inner, "parameters") orelse return error.MalformedToolEnvelope;
    const success_raw = findTag(inner, "success") orelse return error.MalformedToolEnvelope;
    const err_raw = findTag(inner, "error");
    const data_raw = findTag(inner, "data");

    // The slice returned by findTag points into `content` (which is a caller-owned
    // allocation from wrapToolResult). The Unwrapped fields must be independently
    // free-able, so dupe each one.
    const name = try allocator.dupe(u8, name_raw);
    errdefer allocator.free(name);
    const parameters = try allocator.dupe(u8, params_raw);
    errdefer allocator.free(parameters);
    const success = std.mem.eql(u8, std.mem.trim(u8, success_raw, " "), "true");
    const error_message: ?[]const u8 = if (err_raw) |e| try allocator.dupe(u8, e) else null;
    errdefer if (error_message) |em| allocator.free(em);
    const data: ?[]const u8 = if (data_raw) |d| try allocator.dupe(u8, d) else null;
    errdefer if (data) |d| allocator.free(d);

    return Unwrapped{
        .name = name,
        .parameters = parameters,
        .success = success,
        .error_message = error_message,
        .data = data,
    };
}
```

- [ ] **Step 1.4: Register the test file**

Modify `src/ai_workflow/tui/test_runner.zig` — add the import after the existing alphabetical neighbours (alphabetical: `tool_output_wrapper_test.zig` comes after `save_skill_test.zig` and before the `http_handlers/` block):

```zig
test {
    _ = @import("handle_tool_test.zig");
    _ = @import("inherited_context_test.zig");
    _ = @import("migration_performance_indexes_test.zig");
    _ = @import("notifications_test.zig");
    _ = @import("parse_diff_view_test.zig");
    _ = @import("save_agent_test.zig");
    _ = @import("save_skill_test.zig");
    _ = @import("tool_output_wrapper_test.zig"); // NEW
    _ = @import("http_handlers/nalar_config_put_test.zig");
    _ = @import("http_handlers/nalar_config_profile_delete_test.zig");
    _ = @import("http_handlers/sse_handshake_test.zig");
    _ = @import("http_handlers/tasks_update_test.zig");
    _ = @import("http_handlers/tasks_list_test.zig");
    // _ = @import("session_helpers_test.zig"); // DISABLED - requires std.Io which needs Init
    // _ = @import("session_table_test.zig"); // DISABLED - requires std.Io which needs Init
    _ = @import("transform_llm_history_to_agent_messages_test.zig");
    // _ = @import("extract_base64_image_urls_test.zig"); // DISABLED - 9 failing tests (investigation shows std.testing.expectEqualStrings has a bug with literal strings)
    // _ = @import("session_db_test.zig"); // DISABLED - pre-existing test errors (see session_db_test.zig for details)
}
```

- [ ] **Step 1.5: Run tests to verify they pass**

Run: `cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox && timeout 180 zig build test 2>&1 | tail -n 30`
Expected: all 7 new tests pass. No regression in the existing 304 tests (final count should be 311).

- [ ] **Step 1.6: Commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
git add src/ai_workflow/tui/tool_output_wrapper.zig \
        src/ai_workflow/tui/tool_output_wrapper_test.zig \
        src/ai_workflow/tui/test_runner.zig
git commit -m "feat(tool-output): add <tool> XML envelope wrapper with round-trip tests"
```

---

# Chunk 2: Wire wrapper into handle_tool.zig

**Goal:** Every tool result saved to the database (and streamed via SSE) is wrapped in the standardized envelope. This is the only behavioral change — existing inner XML inside `<data>` is preserved, so the frontend tool components continue to work once they unwrap the envelope (Chunk 3).

### Task 2: Wrap every tool result before saving

**Files:**
- Modify: `src/ai_workflow/tui/handle_tool.zig`

- [ ] **Step 2.1: Add the import and read current code around `saveAndSendToolResult`**

The current `handle_tool.zig` (line 456-522) has `saveAndSendToolResult` called in three places from the `for (tc) |tool_call|` loop (lines 414, 425, 449). All three call sites pass `tool_result` (a `[]const u8`) and `tool_call`. We will:
1. Add `wrapToolResult` to wrap the string at each call site.
2. Catch the `dispatchTool` and `dispatchMCP` errors and wrap them too.

- [ ] **Step 2.2: Add the wrapper import at the top of `handle_tool.zig`**

Modify the import block (line 7 area). After the existing `const tool_registry = @import("tool_registry.zig");`, add:

```zig
const tool_output_wrapper = @import("tool_output_wrapper.zig");
```

- [ ] **Step 2.3: Modify the `dispatchMCP` error branch (lines 406-413)**

Replace the existing Zig error handler that produces raw `<error>...</error>` with a wrapped version. Current code:

```zig
tool_result = handle_mcp_tool.handle_mcp_tool_run(
    allocator,
    io,
    logger,
    tool_call,
    config,
) catch |err| {
    tool_result = try std.fmt.allocPrint(allocator, "<error> MCP tool {s} failed: {s}</error>", .{
        tool_call.function.name,
        @errorName(err),
    });
    try saveAndSendToolResult(allocator, io, db, session_id, parent_session_id, model, cwd, loop_counter, tool_call, tool_result, toolAgentTemp, toolIsThinking, current_agent_for_save);
    continue;
};
```

Replace the error block body with:

```zig
} catch |err| {
    const err_msg = try std.fmt.allocPrint(allocator, "MCP tool {s} failed: {s}", .{
        tool_call.function.name,
        @errorName(err),
    });
    tool_result = try tool_output_wrapper.wrapToolResult(
        allocator,
        tool_call.function.name,
        tool_call.function.arguments,
        false,
        err_msg,
        null,
    );
    errdefer allocator.free(tool_result);
    try saveAndSendToolResult(allocator, io, db, session_id, parent_session_id, model, cwd, loop_counter, tool_call, tool_result, toolAgentTemp, toolIsThinking, current_agent_for_save);
    allocator.free(tool_result);
    continue;
};
```

Also wrap the success path for MCP tools (line 414-415). Current code:

```zig
try saveAndSendToolResult(allocator, io, db, session_id, parent_session_id, model, cwd, loop_counter, tool_call, tool_result, toolAgentTemp, toolIsThinking, current_agent_for_save);
continue;
```

Replace with:

```zig
const wrapped = try tool_output_wrapper.wrapToolResult(
    allocator,
    tool_call.function.name,
    tool_call.function.arguments,
    true,
    null,
    tool_result,
);
defer allocator.free(wrapped);
try saveAndSendToolResult(allocator, io, db, session_id, parent_session_id, model, cwd, loop_counter, tool_call, wrapped, toolAgentTemp, toolIsThinking, current_agent_for_save);
continue;
```

**Note:** `handle_mcp_tool_run` returns an allocated string; the caller is now responsible for freeing it. Add `defer allocator.free(tool_result);` immediately after the successful call (before the wrap) — this matches the convention in `tool_registry.zig` for `output_allocated = true` results. The `wrapToolResult` then owns a copy of the string (via `xmlEscape`'s internal copy), so freeing the original is safe.

- [ ] **Step 2.4: Modify the `dispatchTool` error branch (lines 419-427)**

Current code:

```zig
const exec_result = dispatchTool(ctx, tool_call) catch |err| {
    std.debug.print("DEBUG: dispatchTool failed with error: {s}\n", .{@errorName(err)});
    tool_result = try std.fmt.allocPrint(allocator, "<error> {s} failed: {s}</error>", .{
        tool_call.function.name,
        @errorName(err),
    });
    try saveAndSendToolResult(allocator, io, db, session_id, parent_session_id, model, cwd, loop_counter, tool_call, tool_result, toolAgentTemp, toolIsThinking, current_agent_for_save);
    continue;
};

tool_result = exec_result.output;
```

Replace with:

```zig
const exec_result = dispatchTool(ctx, tool_call) catch |err| {
    std.debug.print("DEBUG: dispatchTool failed with error: {s}\n", .{@errorName(err)});
    const err_msg = try std.fmt.allocPrint(allocator, "{s} failed: {s}", .{
        tool_call.function.name,
        @errorName(err),
    });
    tool_result = try tool_output_wrapper.wrapToolResult(
        allocator,
        tool_call.function.name,
        tool_call.function.arguments,
        false,
        err_msg,
        null,
    );
    errdefer allocator.free(tool_result);
    try saveAndSendToolResult(allocator, io, db, session_id, parent_session_id, model, cwd, loop_counter, tool_call, tool_result, toolAgentTemp, toolIsThinking, current_agent_for_save);
    allocator.free(tool_result);
    continue;
};

// Wrap the successful tool result before saving.
// The inner `exec_result.output` is the existing tool-specific XML
// (e.g. "<path>/foo</path><content>hello</content>") — it goes into <data>.
tool_result = try tool_output_wrapper.wrapToolResult(
    allocator,
    tool_call.function.name,
    tool_call.function.arguments,
    true,
    null,
    exec_result.output,
);
defer allocator.free(tool_result);
```

- [ ] **Step 2.5: Verify `text_replace` diff_view extraction still works**

`saveAndSendToolResult` (line 477-488) calls `parseDiffViewFromResult` which searches for `<diff_view>` and extracts `<before>` and `<after>`. After the wrap, the saved content is:

```xml
<tool>
  <name>text_replace</name>
  <parameters>...</parameters>
  <success>true</success>
  <data><diff_view><before>...</before><after>...</after></diff_view>...</data>
</tool>
```

The substring search `<diff_view>` and `<before>` will still match (they appear inside `<data>`). **No change needed to `saveAndSendToolResult`** — the parser doesn't care that there's an outer envelope.

After `parseDiffViewFromResult` returns, `content_without_diffview` will be a reconstructed string that still has the outer `<tool>...</tool>` envelope intact, with the `<diff_view>` section removed from the inside of `<data>`. The `<data>` tag itself stays. This is correct for both DB storage and SSE.

- [ ] **Step 2.6: Run the full test suite to verify no regressions**

Run: `cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox && timeout 180 zig build test 2>&1 | tail -n 30`
Expected: 311/311 tests pass. The existing `handle_tool_test.zig` and `parse_diff_view_test.zig` may need updates if they assert on specific string content — if so, see the Pitfalls section below.

**Pitfall A — `parse_diff_view_test.zig` regression:** the existing `parseDiffViewFromResult` tests pass raw `<diff_view>...<before>...</before><after>...</after></diff_view>` strings and expect the before/after fields. The function doesn't look for the outer `<tool>` wrapper, so it still works on `<data><diff_view>...` input. **No change needed.** Verify by running the test.

**Pitfall B — `handle_tool_test.zig` may assert exact content:** if the test asserts `try testing.expectEqualStrings(expectation, saved_content)`, it will need to be updated to expect the wrapped form. If this is the case, modify the test's expectation to wrap its expected string using `tool_output_wrapper.wrapToolResult(...)` — the inner expected `<diff_view>`/`<path>` content stays the same. **Likely the test currently doesn't exist or is loose enough to absorb the change** — verify by running the test.

- [ ] **Step 2.7: Commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
git add src/ai_workflow/tui/handle_tool.zig
git commit -m "feat(tool-output): wrap every tool result in <tool> envelope before saving"
```

---

# Chunk 3: Frontend unwrap helper + ChatView.vue update

**Goal:** The frontend parses the envelope once in `ChatView.vue`, passes the inner `<data>` content to the existing `tool_outputs/*.vue` components (which continue to parse their own inner tags unchanged), and displays a consistent `tool_name → ✓ data` or `tool_name → ✗ error` summary in the fallback `renderResponse` branch.

### Task 3: Create the frontend unwrap helper

**Files:**
- Create: `src/apps/desktop/src/helpers/unwrapToolOutput.ts`
- Create: `src/apps/desktop/src/helpers/unwrapToolOutput.spec.ts`

- [ ] **Step 3.1: Write the failing test file**

Create `src/apps/desktop/src/helpers/unwrapToolOutput.spec.ts`:

```ts
import { describe, it, expect } from 'vitest'
import { unwrapToolOutput, tryUnwrapToolOutput } from './unwrapToolOutput'

describe('unwrapToolOutput', () => {
  it('parses a success envelope with inner data', () => {
    const wrapped =
      '<tool><name>read_file</name><parameters>{&quot;path&quot;:&quot;/foo&quot;}</parameters><success>true</success><data><path>/foo</path><content>hello</content></data></tool>'
    const result = unwrapToolOutput(wrapped)
    expect(result.name).toBe('read_file')
    expect(result.parameters).toBe('{"path":"/foo"}') // un-escaped
    expect(result.success).toBe(true)
    expect(result.error).toBeNull()
    expect(result.data).toBe('<path>/foo</path><content>hello</content>') // un-escaped
  })

  it('parses an error envelope', () => {
    const wrapped =
      '<tool><name>read_file</name><parameters>{}</parameters><success>false</success><error>File not found</error></tool>'
    const result = unwrapToolOutput(wrapped)
    expect(result.name).toBe('read_file')
    expect(result.success).toBe(false)
    expect(result.error).toBe('File not found')
    expect(result.data).toBeNull()
  })

  it('throws on malformed envelope', () => {
    expect(() => unwrapToolOutput('<error>something</error>')).toThrow()
    expect(() => unwrapToolOutput('not xml at all')).toThrow()
    expect(() => unwrapToolOutput('<tool><name>foo</name>')).toThrow() // unterminated
  })

  it('tryUnwrapToolOutput returns null on malformed input', () => {
    expect(tryUnwrapToolOutput('garbage')).toBeNull()
    expect(
      tryUnwrapToolOutput(
        '<tool><name>read_file</name><parameters>{}</parameters><success>true</success><data>ok</data></tool>',
      ),
    ).toEqual({
      name: 'read_file',
      parameters: '{}',
      success: true,
      error: null,
      data: 'ok',
    })
  })

  it('unescapes XML entities in parameters and data', () => {
    const wrapped =
      '<tool><name>bash</name><parameters>{&quot;command&quot;:&quot;echo &lt;hi&gt;&quot;}</parameters><success>true</success><data><stdout>&lt;hi&gt; &amp; &quot;world&quot;</stdout></data></tool>'
    const result = unwrapToolOutput(wrapped)
    expect(result.parameters).toBe('{"command":"echo <hi>"}')
    expect(result.data).toBe('<stdout><hi> & "world"</stdout>')
  })
})
```

- [ ] **Step 3.2: Run the test to verify it fails**

Run: `cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/src/apps/desktop && timeout 60 bunx vitest run helpers/unwrapToolOutput.spec.ts 2>&1 | tail -n 30`
Expected: tests fail (file not found).

- [ ] **Step 3.3: Implement the helper**

Create `src/apps/desktop/src/helpers/unwrapToolOutput.ts`:

```ts
/**
 * Parsed parts of a standardized tool result envelope.
 * Returned by `unwrapToolOutput` / `tryUnwrapToolOutput`.
 */
export interface UnwrappedToolOutput {
  /** Tool name (e.g. "read_file") */
  name: string
  /** Tool arguments as a raw JSON string (XML-unescaped) */
  parameters: string
  /** Whether the tool succeeded */
  success: boolean
  /** Error message (XML-unescaped), or null on success */
  error: string | null
  /** Inner tool-specific output (XML-unescaped), or null on error */
  data: string | null
}

/**
 * Reverse the XML escaping applied by the backend's `wrapToolResult`.
 * Mirrors `llm_history.zig xmlEscape` exactly.
 */
function unescapeXml(s: string): string {
  return s
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"')
    .replace(/&apos;/g, "'")
    .replace(/&amp;/g, '&') // MUST be last to avoid double-unescaping
}

/**
 * Find the first `<tag>...</tag>` block and return its inner text.
 * Returns `null` if the tag is not present.
 */
function findTag(haystack: string, tag: string): string | null {
  const openSeq = `<${tag}>`
  const closeSeq = `</${tag}>`
  const openIdx = haystack.indexOf(openSeq)
  if (openIdx === -1) return null
  const valueStart = openIdx + openSeq.length
  const closeIdx = haystack.indexOf(closeSeq, valueStart)
  if (closeIdx === -1) return null
  return haystack.slice(valueStart, closeIdx)
}

/**
 * Parse a `<tool>...</tool>` envelope.
 * Throws on malformed input — use `tryUnwrapToolOutput` for a null fallback.
 *
 * The backend produces this envelope in `tool_output_wrapper.wrapToolResult`.
 * The inner `<data>` field contains the existing tool-specific XML
 * (e.g. `<path>/foo</path><content>hello</content>` for read_file).
 */
export function unwrapToolOutput(content: string): UnwrappedToolOutput {
  if (!content.startsWith('<tool>') || !content.endsWith('</tool>')) {
    throw new Error('MalformedToolEnvelope: missing <tool>...</tool> wrapper')
  }
  const inner = content.slice('<tool>'.length, -'</tool>'.length)

  const nameRaw = findTag(inner, 'name')
  const paramsRaw = findTag(inner, 'parameters')
  const successRaw = findTag(inner, 'success')
  if (nameRaw === null || paramsRaw === null || successRaw === null) {
    throw new Error('MalformedToolEnvelope: missing required field (name|parameters|success)')
  }

  const errRaw = findTag(inner, 'error')
  const dataRaw = findTag(inner, 'data')

  return {
    name: unescapeXml(nameRaw),
    parameters: unescapeXml(paramsRaw),
    success: successRaw.trim() === 'true',
    error: errRaw === null ? null : unescapeXml(errRaw),
    data: dataRaw === null ? null : unescapeXml(dataRaw),
  }
}

/**
 * Like `unwrapToolOutput` but returns `null` instead of throwing.
 * Use this for inputs that may legitimately be unwrapped XML
 * (e.g. legacy tool results that pre-date the envelope).
 */
export function tryUnwrapToolOutput(content: string): UnwrappedToolOutput | null {
  try {
    return unwrapToolOutput(content)
  } catch {
    return null
  }
}
```

- [ ] **Step 3.4: Run the test to verify it passes**

Run: `cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/src/apps/desktop && timeout 60 bunx vitest run helpers/unwrapToolOutput.spec.ts 2>&1 | tail -n 20`
Expected: 5 tests pass.

- [ ] **Step 3.5: Commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
git add src/apps/desktop/src/helpers/unwrapToolOutput.ts \
        src/apps/desktop/src/helpers/unwrapToolOutput.spec.ts
git commit -m "feat(desktop): add unwrapToolOutput helper for <tool> envelope"
```

### Task 4: Update ChatView.vue to use the unwrap helper

**Files:**
- Modify: `src/apps/desktop/src/components/ChatView.vue`

- [ ] **Step 4.1: Add the import**

In the `<script setup>` block of `ChatView.vue` (around line 14, the other `@/helpers` imports), add:

```ts
import { tryUnwrapToolOutput, type UnwrappedToolOutput } from '@/helpers/unwrapToolOutput'
```

- [ ] **Step 4.2: Add a computed that unwraps each tool message once**

After the existing `messageGroups` computed (line 559-580) and before `groupToolNames` (line 586), add:

```ts
// ─── Unwrapped tool content ───────────────────────────────────────────
// For tool groups, the content of each message is the full
// `<tool>...</tool>` envelope. Unwrap it once so we can:
//   1. Pass the inner `<data>` to the existing tool_outputs/*.vue
//      components (which parse their own inner tags like <path>,
//      <content>, <error>, <loaded>, <diff_view>, etc.).
//   2. Display a consistent `tool_name → ✓ data` or `✗ error` summary
//      in the fallback renderResponse() branch.
// Returns null for groups that are not tool groups, or for tool
// messages that don't follow the new envelope format (legacy content).
const unwrappedToolContent = computed(
  (): (UnwrappedToolOutput | null)[] | null => {
    return null // see Step 4.3 — actual implementation reads from a Map
  },
)
```

**Wait** — that approach doesn't work because the unwrap needs to happen per-message, not per-group, and the existing tool components receive `content` per-message via the `<ReadFile :content="msg.content" />` etc. props. The right approach is: keep the props as-is, but **unwrap before passing**. The cleanest implementation is to mutate the per-message `content` at the tool-component level via a wrapper prop or by using a small inline computed in the template.

The simpler approach (chosen): compute a `Map<msgId, UnwrappedToolOutput>` once per render and look it up in the template. Add this after `messageGroups`:

```ts
// Per-message unwrap lookup. Keyed by message id; value is the parsed
// envelope or null if the content is not a <tool> envelope (legacy or
// non-tool content). Computed once when messages change so the template
// can do a cheap O(1) lookup per tool component.
const unwrappedByMessageId = computed((): Map<string, UnwrappedToolOutput | null> => {
  const map = new Map<string, UnwrappedToolOutput | null>()
  for (const m of messages.value) {
    if (m.role !== 'tool') {
      map.set(m.id, null)
      continue
    }
    map.set(m.id, tryUnwrapToolOutput(m.content))
  }
  return map
})

// Helper used in the template: get the inner data to pass to a
// tool-specific component. Returns the original content if the
// envelope didn't parse (legacy fallback) or if there was an error
// (the error message is shown via the envelope, not via the inner
// component's own error path).
const innerToolData = (m: Message): string => {
  const unwrapped = unwrappedByMessageId.value.get(m.id)
  if (unwrapped === null || unwrapped === undefined) return m.content // legacy
  return unwrapped.data ?? m.content // error case: fall back to full content
}
```

- [ ] **Step 4.3: Replace the tool component `:content` props in the template**

In the template (lines 1777-1859), every `<Component :content="msg.content" />` needs to become `<Component :content="innerToolData(msg)" />`. The components to update:

| Line | Component | Tool name |
|------|-----------|-----------|
| 1778 | `ReadFile` | read_file |
| 1784 | `WriteFile` | write_file |
| 1790 | `UpdateActivity` | update_activity |
| 1795 | `Search` | search |
| 1800 | `Glob` | glob |
| 1806 | `TextReplace` | text_replace |
| 1814 | `Bash` | bash / run_command |
| 1819 | `GetSkill` | get_skill |
| 1824 | `ViewSkill` | view_skill |
| 1829 | `ListSkills` | list_skills |
| 1834 | `AddSkill` | add_skill |
| 1839 | `EditSkill` | edit_skill |
| 1844 | `RemoveSkill` | remove_skill |
| 1849 | `RemoveFile` | remove_file |
| 1855 | `SpawnSubAgent` | spawn_sub_agent |

For each, change `:content="msg.content"` to `:content="innerToolData(msg)"`.

- [ ] **Step 4.4: Add a status badge to the fallback `renderResponse` branch**

The `renderResponse` function (line 112-211) has a `return <span class="tool-inline">${tool_name} → ${escapeHtml(content)}</span>;` fallback at line 204. With the envelope in place, the fallback is the perfect place to show a clean `tool_name(params) → ✓ data preview` or `✗ error` summary. Replace the fallback return statement (line 204) with:

```ts
// Fallback: render a concise summary from the <tool> envelope.
// If the content doesn't match the envelope (legacy), fall back to
// the raw text (existing behavior).
const unwrapped = tryUnwrapToolOutput(content)
if (unwrapped === null) {
  return `<span class="tool-inline">${tool_name || 'tool'} → ${escapeHtml(content)}</span>`
}
const statusIcon = unwrapped.success ? '✓' : '✗'
const statusClass = unwrapped.success ? 'tool-inline-success' : 'tool-inline-error'
const preview = unwrapped.success
  ? unwrapped.data?.slice(0, 80) ?? ''
  : unwrapped.error ?? 'unknown error'
return `<span class="tool-inline">${tool_name || unwrapped.name} → <span class="${statusClass}">${statusIcon}</span> ${escapeHtml(preview)}${preview.length >= 80 ? '…' : ''}</span>`
```

Add a small CSS rule in the `<style scoped>` block (after the existing `.tool-inline` rules at line 2398-2402):

```css
:deep(.tool-inline-success) {
  color: var(--color-green);
  font-weight: 600;
}

:deep(.tool-inline-error) {
  color: var(--color-red);
  font-weight: 600;
}
```

(Verify the exact CSS variable names exist by searching the codebase — `var(--color-green)` and `var(--color-red)` are used elsewhere in `ChatView.vue` at lines 2035-2042, so they're available.)

- [ ] **Step 4.5: Run the frontend type-check + tests**

Run: `cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/src/apps/desktop && timeout 120 bun run build 2>&1 | tail -n 20`
Expected: clean build, no TypeScript errors. (The project's NALAR.md memory rule says `bun run build` is the authoritative type-check, NOT `bunx vitest run`.)

Then: `cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/src/apps/desktop && timeout 60 bunx vitest run 2>&1 | tail -n 20`
Expected: 31 + 5 = 36 tests pass (the 5 new tests for `unwrapToolOutput.spec.ts` + the existing 31).

- [ ] **Step 4.6: Manual end-to-end smoke test**

The dev server is on port 8080 (NOT 8081 — that one is in use by another process). Start it with:

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
# Server (terminal 1)
timeout 30 ./zig-out/bin/nalar --port 8080 2>&1 | tail -n 20
```

In the desktop app (port 8080):
1. Open a chat and ask the agent to `read_file` a known file (e.g. `/etc/hostname`).
2. Verify the tool result bubble shows:
   - The header from `ReadFile.vue` (file path, line count, expand button).
   - On expand, the file content.
3. Ask the agent to call a tool that fails (e.g. `read_file` on a non-existent path).
4. Verify the bubble shows the file path in red (per `ReadFile.vue`'s error styling at line 85).
5. Ask the agent to run `bash` with `echo hello`.
6. Verify the `Bash.vue` bubble shows the standard stdout/stderr layout.

These verify that the `innerToolData(msg)` unwrap correctly passes the inner XML to the existing components.

- [ ] **Step 4.7: Commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
git add src/apps/desktop/src/components/ChatView.vue
git commit -m "feat(desktop): unwrap <tool> envelope in ChatView, pass <data> to tool components"
```

---

# Verification (final, before declaring done)

Run all of these and confirm clean output before claiming success:

1. **Backend tests** — `cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox && timeout 180 zig build test 2>&1 | tail -n 30`
   - Expected: 311+ tests pass (304 existing + 7 new wrapper tests). The exact previous count was 304/307 per the [prompts.zig:521, appendSkillsListing] fix note — re-check the current baseline.

2. **Backend build** — `cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox && timeout 240 zig build 2>&1 | tail -n 20`
   - Expected: clean build, no warnings about unused `wrapToolResult` import in `handle_tool.zig`.

3. **Frontend type-check** — `cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/src/apps/desktop && timeout 120 bun run build 2>&1 | tail -n 20`
   - Expected: clean. No `vue-tsc` errors about `UnwrappedToolOutput` type usage, no `innerToolData` complaints.

4. **Frontend tests** — `cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/src/apps/desktop && timeout 60 bunx vitest run 2>&1 | tail -n 20`
   - Expected: 36+ tests pass (31 existing + 5 new unwrap tests).

5. **End-to-end smoke** (the manual step 4.6 above) — confirm the existing `tool_outputs/*.vue` components render correctly with the new envelope.

If any step fails, do not declare the task done — fix and re-run.

---

# Pitfalls (cumulative)

1. **Use `xmlEscape` from the new wrapper module, not from `llm_history.zig`.** The `llm_history.zig` version is `pub` but it pulls in the sqlite/agent dependency tree when the wrapper is imported. The wrapper has its own identical copy to stay self-contained.

2. **`<error>` and `<data>` are mutually exclusive.** On success, emit `<data>` and omit `<error>`. On failure, emit `<error>` and omit `<data>`. This keeps successful output clean and makes the success/error state unambiguous.

3. **The `parseDiffViewFromResult` regex searches for `<diff_view>` substring.** It works inside `<data>` (substring matching is position-independent), so the existing function does not need updating. Do NOT "fix" it by looking for `<data>...<diff_view>` — that's a regression.

4. **MCP tool success path needs both wrapping and freeing.** `handle_mcp_tool_run` returns an allocated string; after wrapping, the original must be freed. Use `defer allocator.free(wrapped);` after the wrap + before the save.

5. **`exec_result.output` from `tool_registry.zig` may or may not be allocated.** The `ToolExecResult.output_allocated` flag tells you. The wrapper `dupes` the content internally (via `xmlEscape`'s `toOwnedSlice`), so the caller is free to free the original after the wrap.

6. **Frontend `innerToolData` is per-message, not per-group.** The existing tool components receive a single `content` prop. The Map keyed by `msg.id` ensures each message's envelope is unwrapped exactly once.

7. **The `<data>` may contain nested `<data>` if a tool's inner XML has a `<data>` tag.** None of the existing tools produce a `<data>` tag in their inner output (verified by grep), so this is not a current problem. If a future tool does, the unwrap parser will need a depth-aware `findTag`. Add a note in `tool_output_wrapper.zig`'s doc comment.

8. **Do NOT use CDATA in the wrapper.** XML-escape is consistent with the rest of the codebase and avoids the `]]>` edge case. If a future tool produces `]]>` in its output (unlikely for JSON/XML), escape handles it correctly.
