# Standardize Tool Output with `<tool>` Envelope (Helper in `tool_registry.zig`)

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every tool result is wrapped in a uniform XML envelope so the LLM, the frontend, and any future consumer can read a single consistent format. The helper that builds the envelope lives directly in `tool_registry.zig` (no separate module). Existing tool-specific inner XML is preserved verbatim inside `<data>` so the 13 `tool_outputs/*.vue` components and the 12 tool modules' `toXmlSuccess`/`toXmlError` functions continue to work unchanged.

**Architecture:**
- **Backend (Zig):** Add a single `pub fn wrapToolOutput(allocator, name, parameters, success, error_message, data)` helper to `tool_registry.zig`. Each of the 25 `execX` functions ends by calling it. The inner `<data>` field holds the existing tool-specific XML untouched — `<path>`, `<content>`, `<diff_view>`, `<error>`, `<loaded>`, etc. all preserved. `handle_tool.zig`'s dispatch-level error paths (catches at `dispatchTool` and `dispatchMCP`) call the same helper for consistency.
- **Frontend (Vue/TS):** New helper `src/apps/desktop/src/helpers/unwrapToolOutput.ts` parses the envelope and returns `{ name, parameters, success, error, data }`. `ChatView.vue` uses it to (a) pass `data` to the existing `tool_outputs/*.vue` components (which keep parsing their own inner tags unchanged), (b) display a consistent `tool_name → ✓ data preview` or `✗ error` summary in the fallback `renderResponse` branch, and (c) add a small status badge for tools without a dedicated component.

**Tech Stack:** Zig 0.15.2 (backend, `nalarcore`), Vue 3 + TypeScript (frontend, `apps/desktop`), Vite/Vitest.

---

## The envelope

```xml
<tool>
  <name>{name}</name>
  <parameters>{xml-escaped JSON args}</parameters>
  <success>true|false</success>
  <error>{xml-escaped error, omitted when success}</error>
  <data>{xml-escaped inner tool output, omitted when error}</data>
</tool>
```

**Rules:**
- `name` — tool name (e.g. `"read_file"`), XML-escaped for safety.
- `parameters` — raw JSON from `tc.function.arguments`, always emitted (even on error), XML-escaped.
- `success` — `"true"` or `"false"`.
- `error` — human-readable error message, XML-escaped. **Omitted** when `success=true` to keep successful output clean.
- `data` — existing tool-specific XML output, XML-escaped. **Omitted** when `success=false` (the error message is in `<error>`).

XML escaping handles `<`, `>`, `&`, `"`, `'` — same as the existing `llm_history.zig:762` `xmlEscape`. The wrapper re-implements it (private) to keep `tool_registry.zig` self-contained.

---

## File Structure

### New files
- `src/ai_workflow/tui/tool_registry_test.zig` — unit tests for `wrapToolOutput`.
- `src/apps/desktop/src/helpers/unwrapToolOutput.ts` — frontend TypeScript helper.
- `src/apps/desktop/src/helpers/unwrapToolOutput.spec.ts` — Vitest tests for the helper.

### Modified files
- `src/ai_workflow/tui/tool_registry.zig` — add `wrapToolOutput` + private `xmlEscape`. Refactor 25 `execX` functions to call it.
- `src/ai_workflow/tui/test_runner.zig` — register the new test file.
- `src/ai_workflow/tui/handle_tool.zig` — wrap the dispatch-level error paths with `wrapToolOutput` for consistency.
- `src/apps/desktop/src/components/ChatView.vue` — use the unwrap helper, pass `data` to tool components, add status badge in fallback.

### Out of scope
- Any change to the 12 tool modules' `toXmlSuccess`/`toXmlError` (their output goes inside `<data>` unchanged).
- Any change to the 13 `tool_outputs/*.vue` components (they receive `data` and parse their own inner tags unchanged — verified for `ReadFile.vue`, `TextReplace.vue`, `RemoveSkill.vue`).
- Memory-leak audit (existing leaks preserved).
- `set_agent_properties`'s closing-tag typo fix (the wrapper just encloses whatever the tool produced; the typo stays inside `<data>`).

---

# Chunk 1: Backend helper + tests

**Goal:** Add `wrapToolOutput` and private `xmlEscape` to `tool_registry.zig`. Write 7 unit tests covering success, error, escape, empty parameters, and round-trip parsing. No callsite changes yet.

### Task 1: Add the helper and tests

**Files:**
- Modify: `src/ai_workflow/tui/tool_registry.zig` (add helpers before the `// UNIFIED TOOL REGISTRY` section at line 957).
- Create: `src/ai_workflow/tui/tool_registry_test.zig`.
- Modify: `src/ai_workflow/tui/test_runner.zig` (register the new test).

- [ ] **Step 1.1: Write the failing test file**

Create `src/ai_workflow/tui/tool_registry_test.zig`:

```zig
const std = @import("std");
const testing = std.testing;
const tool_registry = @import("tool_registry.zig");

test "wrapToolOutput - success with all fields" {
    const allocator = testing.allocator;
    const out = try tool_registry.wrapToolOutput(
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

test "wrapToolOutput - error case omits data and emits error" {
    const allocator = testing.allocator;
    const out = try tool_registry.wrapToolOutput(
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

test "wrapToolOutput - empty parameters string is emitted" {
    const allocator = testing.allocator;
    const out = try tool_registry.wrapToolOutput(
        allocator,
        "list_skills",
        "",
        true,
        null,
        "<skills></skills>",
    );
    defer allocator.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "<parameters></parameters>") != null);
}

test "wrapToolOutput - data with special characters is escaped" {
    const allocator = testing.allocator;
    const out = try tool_registry.wrapToolOutput(
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

test "wrapToolOutput - error message is escaped" {
    const allocator = testing.allocator;
    const out = try tool_registry.wrapToolOutput(
        allocator,
        "bash",
        "{}",
        false,
        "bad <tag> & \"quote\"",
        null,
    );
    defer allocator.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "<error>bad &lt;tag&gt; &amp; &quot;quote&quot;</error>") != null);
}

test "wrapToolOutput - success and error are mutually exclusive" {
    const allocator = testing.allocator;
    const out = try tool_registry.wrapToolOutput(
        allocator,
        "bash",
        "{}",
        true,
        "ignored error msg",
        "<stdout>ok</stdout>",
    );
    defer allocator.free(out);

    // success=true should ignore error_message and emit <data>
    try testing.expect(std.mem.indexOf(u8, out, "<data><stdout>ok</stdout></data>") != null);
    try testing.expect(std.mem.indexOf(u8, out, "<error>") == null);
}

test "wrapToolOutput - allocates and caller owns" {
    const allocator = testing.allocator;
    const out = try tool_registry.wrapToolOutput(
        allocator,
        "bash",
        "{}",
        true,
        null,
        "ok",
    );
    defer allocator.free(out);
    try testing.expect(out.len > 0);
}
```

- [ ] **Step 1.2: Run tests to verify they fail**

Run: `cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox && timeout 180 zig build test 2>&1 | tail -n 30`
Expected: compilation error — `wrapToolOutput` does not exist in `tool_registry`.

- [ ] **Step 1.3: Implement the helper**

In `src/ai_workflow/tui/tool_registry.zig`, add this block immediately before the `// UNIFIED TOOL REGISTRY` section header (around line 957):

```zig
// ============================================================================
// STANDARDIZED TOOL OUTPUT ENVELOPE
// ============================================================================
//
// Every `execX` function below MUST end by calling `wrapToolOutput` so the
// LLM sees a single consistent envelope:
//
//   <tool>
//     <name>{name}</name>
//     <parameters>{xml-escaped JSON args}</parameters>
//     <success>true|false</success>
//     <error>{if failure}</error>
//     <data>{xml-escaped inner tool output, if success}</data>
//   </tool>
//
// The inner `<data>` field holds the existing tool-specific XML unchanged
// (e.g. read_file's `<path>`, text_replace's `<diff_view>`, get_skill's
// `<loaded>`, etc.) so the 12 tool modules' `toXmlSuccess`/`toXmlError`
// functions and the 13 frontend `tool_outputs/*.vue` components keep
// working unchanged.

/// XML-escape special characters. Identical to `llm_history.zig:762`
/// `xmlEscape` — re-implemented here to keep this module self-contained
/// (so callers don't pull in `llm_history.zig`'s sqlite/agent dependency
/// tree just to wrap tool output).
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
/// On success: emits `<data>` containing the inner tool-specific XML output.
/// On error: emits `<error>` containing a human-readable message and omits
/// `<data>`. The two are mutually exclusive — when `success=true`, the
/// `error_message` argument is ignored; when `success=false`, the `data`
/// argument is ignored.
///
/// `tool_name` — the registered tool name (e.g. `"read_file"`). XML-escaped.
/// `parameters` — the raw JSON arguments string from the tool call
///   (e.g. `{"path":"/foo"}`). Always emitted (even on error), XML-escaped.
/// `success` — `true` for a successful tool execution, `false` for a failure.
/// `error_message` — required when `success=false`; ignored when `success=true`.
/// `data` — the existing tool-specific XML output. Required when
///   `success=true`; ignored when `success=false`. Pass an empty string if
///   you have no data (the wrapper still emits an empty `<data></data>`).
///
/// The returned string is owned by the caller; free with `allocator.free`.
pub fn wrapToolOutput(
    allocator: std.mem.Allocator,
    tool_name: []const u8,
    parameters: []const u8,
    success: bool,
    error_message: ?[]const u8,
    data: []const u8,
) ![]u8 {
    const escaped_name = try xmlEscape(allocator, tool_name);
    defer allocator.free(escaped_name);
    const escaped_params = try xmlEscape(allocator, parameters);
    defer allocator.free(escaped_params);

    if (success) {
        const escaped_data = try xmlEscape(allocator, data);
        defer allocator.free(escaped_data);
        return try std.fmt.allocPrint(
            allocator,
            "<tool><name>{s}</name><parameters>{s}</parameters><success>true</success><data>{s}</data></tool>",
            .{ escaped_name, escaped_params, escaped_data },
        );
    } else {
        const msg = error_message orelse "unknown error";
        const escaped_err = try xmlEscape(allocator, msg);
        defer allocator.free(escaped_err);
        return try std.fmt.allocPrint(
            allocator,
            "<tool><name>{s}</name><parameters>{s}</parameters><success>false</success><error>{s}</error></tool>",
            .{ escaped_name, escaped_params, escaped_err },
        );
    }
}
```

- [ ] **Step 1.4: Register the test file**

Modify `src/ai_workflow/tui/test_runner.zig` — add the import after `save_skill_test.zig` (alphabetical order):

```zig
test {
    _ = @import("handle_tool_test.zig");
    _ = @import("inherited_context_test.zig");
    _ = @import("migration_performance_indexes_test.zig");
    _ = @import("notifications_test.zig");
    _ = @import("parse_diff_view_test.zig");
    _ = @import("save_agent_test.zig");
    _ = @import("save_skill_test.zig");
    _ = @import("tool_registry_test.zig"); // NEW
    _ = @import("http_handlers/nalar_config_put_test.zig");
    // ... (rest unchanged)
}
```

- [ ] **Step 1.5: Run tests to verify they pass**

Run: `cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox && timeout 180 zig build test 2>&1 | tail -n 30`
Expected: 7 new tests pass. Existing 304 tests untouched (helpers unused so far).

- [ ] **Step 1.6: Commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
git add src/ai_workflow/tui/tool_registry.zig \
        src/ai_workflow/tui/tool_registry_test.zig \
        src/ai_workflow/tui/test_runner.zig
git commit -m "feat(tool-registry): add wrapToolOutput envelope helper with round-trip tests"
```

---

# Chunk 2: Refactor all 25 `execX` functions in `tool_registry.zig`

**Goal:** Every `execX` function ends with `wrapToolOutput(...)` instead of returning raw inner XML. The pattern is the same for every function.

For each `execX`:
- **Success path**: `return ToolExecResult{ .output = try wrapToolOutput(ctx.allocator, "tool_name", tc.function.arguments, true, null, inner) }`
- **Error path (in the exec function)**: `return ToolExecResult{ .output = try wrapToolOutput(ctx.allocator, "tool_name", tc.function.arguments, false, err_msg, "") }`

Set `output_allocated = true` consistently (the wrap always allocates).

### Task 2: Refactor each `execX` function

**Files:**
- Modify: `src/ai_workflow/tui/tool_registry.zig` (lines 176-925, 25 functions).

- [ ] **Step 2.1: `execBash` (line 176)**

```zig
pub fn execBash(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    const inner = try runWithContext(ctx.allocator, ctx.io, tc, ctx.db, ctx.session_id);
    const output = try wrapToolOutput(ctx.allocator, "bash", tc.function.arguments, true, null, inner);
    return ToolExecResult{ .output = output, .output_allocated = true };
}
```

- [ ] **Step 2.2: `execReadFile` (line 181)**

Add a catch on `readFile` to wrap the error:

```zig
pub fn execReadFile(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    _ = ctx.db;
    _ = ctx.session_id;

    const parsed = std.json.parseFromSlice(
        tool_models.ReadFileInput,
        ctx.allocator,
        tc.function.arguments,
        .{ .allocate = .alloc_always },
    ) catch |err| {
        const err_msg = try std.fmt.allocPrint(ctx.allocator, "read_file failed: {s}", .{@errorName(err)});
        const output = try wrapToolOutput(ctx.allocator, "read_file", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    defer parsed.deinit();

    const read_opts = read_file_mod.ReadFileOptions{
        .offset = parsed.value.offset,
        .limit = parsed.value.limit,
    };

    const read_result = read_file_mod.readFile(ctx.allocator, ctx.io, parsed.value.path, read_opts) catch |err| {
        const err_msg = try std.fmt.allocPrint(ctx.allocator, "read_file failed: {s}", .{@errorName(err)});
        const output = try wrapToolOutput(ctx.allocator, "read_file", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    defer read_result.deinit(ctx.allocator);

    const inner = try read_file_mod.toXMLSuccess(ctx.allocator, read_result, parsed.value.path);
    const output = try wrapToolOutput(ctx.allocator, "read_file", tc.function.arguments, true, null, inner);
    return ToolExecResult{ .output = output, .output_allocated = true };
}
```

- [ ] **Step 2.3: `execTextReplace` (line 207)**

Add catch on `std.json.parseFromSlice` and wrap the error path:

```zig
pub fn execTextReplace(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    const parsed = std.json.parseFromSlice(
        text_replace_mod.TextReplaceInput,
        ctx.allocator,
        tc.function.arguments,
        .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
    ) catch |err| {
        const err_msg = try std.fmt.allocPrint(ctx.allocator, "text_replace failed: {s}", .{@errorName(err)});
        const output = try wrapToolOutput(ctx.allocator, "text_replace", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    defer parsed.deinit();

    const result = text_replace_mod.executeTextReplace(
        ctx.allocator,
        ctx.io,
        parsed.value.path,
        parsed.value.old_str,
        parsed.value.new_str,
    ) catch |err| {
        const inner = text_replace_mod.toXmlError(
            ctx.allocator,
            err,
            parsed.value.path,
            parsed.value.old_str,
        );
        const err_msg = try std.fmt.allocPrint(ctx.allocator, "text_replace failed: {s}", .{@errorName(err)});
        const output = try wrapToolOutput(ctx.allocator, "text_replace", tc.function.arguments, false, err_msg, inner);
        return ToolExecResult{ .output = output, .output_allocated = true };
    };

    const inner = text_replace_mod.toXmlSuccess(ctx.allocator, result, parsed.value.path);
    const output = try wrapToolOutput(ctx.allocator, "text_replace", tc.function.arguments, true, null, inner);
    return ToolExecResult{ .output = output, .output_allocated = true };
}
```

- [ ] **Step 2.4: `execWriteFile` (line 239)**

Same pattern as `execTextReplace`. Catch on parse and on `writeFile`.

- [ ] **Step 2.5: `execListSkills` (line 258)**

```zig
pub fn execListSkills(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    _ = tc;
    const inner = list_skills_mod.execute_list_skills(ctx.allocator, ctx.io, ctx.cwd, ctx.environment) catch |err| {
        const err_msg = try std.fmt.allocPrint(ctx.allocator, "list_skills failed: {s}", .{@errorName(err)});
        const output = try wrapToolOutput(ctx.allocator, "list_skills", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    const output = try wrapToolOutput(ctx.allocator, "list_skills", tc.function.arguments, true, null, inner);
    return ToolExecResult{ .output = output, .output_allocated = true };
}
```

- [ ] **Step 2.6: `execListMemory` (line 271)**

Same pattern. Tool name `"list_memory"`.

- [ ] **Step 2.7: `execGetSkill` (line 282)**

This one is more complex because of the auto-save side effect. Update the success detection to look for `<success>true</success>` in the wrapped output (not the inner `<loaded>true</loaded>`):

```zig
pub fn execGetSkill(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    const parsed = try std.json.parseFromSlice(
        get_skill_mod.GetSkillInput,
        ctx.allocator,
        tc.function.arguments,
        .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
    );
    defer parsed.deinit();

    const inner = get_skill_mod.execute_get_skill_to_string(ctx.allocator, ctx.io, parsed.value, ctx.environment) catch |err| {
        const err_msg = try std.fmt.allocPrint(ctx.allocator, "get_skill failed: {s}", .{@errorName(err)});
        const output = try wrapToolOutput(ctx.allocator, "get_skill", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    const output = try wrapToolOutput(ctx.allocator, "get_skill", tc.function.arguments, true, null, inner);

    // Auto-save: detect <success>true</success> in the wrapped envelope.
    if (std.mem.indexOf(u8, output, "<success>true</success>") != null) {
        const name_start = std.mem.indexOf(u8, output, "<skill_name>") orelse {
            return ToolExecResult{ .output = output, .output_allocated = true };
        };
        const name_begin = name_start + "<skill_name>".len;
        const name_end = std.mem.indexOf(u8, output[name_begin..], "</skill_name>") orelse {
            return ToolExecResult{ .output = output, .output_allocated = true };
        };
        const skill_name = output[name_begin .. name_begin + name_end];

        const content_start = std.mem.indexOf(u8, output, "<content>") orelse {
            return ToolExecResult{ .output = output, .output_allocated = true };
        };
        const content_begin = content_start + "<content>".len;
        const content_end = std.mem.indexOf(u8, output[content_begin..], "</content>") orelse {
            return ToolExecResult{ .output = output, .output_allocated = true };
        };
        const skill_content = output[content_begin .. content_begin + content_end];

        return ToolExecResult{
            .output = output,
            .output_allocated = true,
            .skill_save = SkillSaveInfo{
                .name = skill_name,
                .content = skill_content,
            },
        };
    }

    return ToolExecResult{ .output = output, .output_allocated = true };
}
```

- [ ] **Step 2.8: `execViewSkill` (line 330)**

```zig
pub fn execViewSkill(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    const parsed = std.json.parseFromSlice(
        view_skill_mod.ViewSkillInput,
        ctx.allocator,
        tc.function.arguments,
        .{ .allocate = .alloc_always },
    ) catch |err| {
        const err_msg = try std.fmt.allocPrint(ctx.allocator, "view_skill failed: {s}", .{@errorName(err)});
        const output = try wrapToolOutput(ctx.allocator, "view_skill", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    defer parsed.deinit();

    const inner = view_skill_mod.execute_view_skill_to_string(ctx.allocator, ctx.io, parsed.value, ctx.environment) catch |err| {
        const err_msg = try std.fmt.allocPrint(ctx.allocator, "view_skill failed: {s}", .{@errorName(err)});
        const output = try wrapToolOutput(ctx.allocator, "view_skill", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };

    // Empty skill_name means "not found" → wrap as error.
    if (std.mem.indexOf(u8, inner, "<skill_name></skill_name>") != null) {
        const err_msg = try ctx.allocator.dupe(u8, "Skill not found");
        const output = try wrapToolOutput(ctx.allocator, "view_skill", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    }

    const output = try wrapToolOutput(ctx.allocator, "view_skill", tc.function.arguments, true, null, inner);
    return ToolExecResult{ .output = output, .output_allocated = true };
}
```

- [ ] **Step 2.9: `execRemoveSkill` (line 346)**

If the inner result contains `<error>...</error>`, re-extract the message and wrap as outer error:

```zig
pub fn execRemoveSkill(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    const parsed = try std.json.parseFromSlice(
        remove_skill_mod.RemoveSkillInput,
        ctx.allocator,
        tc.function.arguments,
        .{ .allocate = .alloc_always },
    );
    defer parsed.deinit();

    const inner = remove_skill_mod.execute_remove_skill_to_string(ctx.allocator, ctx.io, ctx.cwd, ctx.environment, parsed.value) catch |err| {
        const err_msg = try std.fmt.allocPrint(ctx.allocator, "remove_skill failed: {s}", .{@errorName(err)});
        const output = try wrapToolOutput(ctx.allocator, "remove_skill", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };

    // If inner has <error>...</error>, treat as failure
    if (std.mem.indexOf(u8, inner, "<error>") != null) {
        const err_start = (std.mem.indexOf(u8, inner, "<error>") orelse 0) + "<error>".len;
        const err_end = std.mem.indexOf(u8, inner[err_start..], "</error>") orelse inner.len;
        const err_msg = inner[err_start .. err_start + err_end];
        const output = try wrapToolOutput(ctx.allocator, "remove_skill", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    }

    const output = try wrapToolOutput(ctx.allocator, "remove_skill", tc.function.arguments, true, null, inner);
    return ToolExecResult{ .output = output, .output_allocated = true };
}
```

- [ ] **Step 2.10: `execAddSkill` (line 362)**

```zig
pub fn execAddSkill(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    const parsed = std.json.parseFromSlice(
        add_skill_mod.AddSkillInput,
        ctx.allocator,
        tc.function.arguments,
        .{ .allocate = .alloc_always },
    ) catch |err| {
        const err_msg = try std.fmt.allocPrint(ctx.allocator, "add_skill failed: {s}", .{@errorName(err)});
        const output = try wrapToolOutput(ctx.allocator, "add_skill", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    defer parsed.deinit();

    const inner = add_skill_mod.executeAddSkillToString(ctx.allocator, ctx.io, ctx.cwd, ctx.environment, parsed.value) catch |err| {
        const err_msg = try std.fmt.allocPrint(ctx.allocator, "add_skill failed: {s}", .{@errorName(err)});
        const output = try wrapToolOutput(ctx.allocator, "add_skill", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };

    if (std.mem.indexOf(u8, inner, "<error>") != null) {
        const err_start = (std.mem.indexOf(u8, inner, "<error>") orelse 0) + "<error>".len;
        const err_end = std.mem.indexOf(u8, inner[err_start..], "</error>") orelse inner.len;
        const err_msg = inner[err_start .. err_start + err_end];
        const output = try wrapToolOutput(ctx.allocator, "add_skill", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    }

    const output = try wrapToolOutput(ctx.allocator, "add_skill", tc.function.arguments, true, null, inner);
    return ToolExecResult{ .output = output, .output_allocated = true };
}
```

- [ ] **Step 2.11: `execEditSkill` (line 375)**

Same pattern as `execAddSkill` with tool name `"edit_skill"`.

- [ ] **Step 2.12: `execAddAgent` (line 391)**

Add catch on `std.json.parseFromSlice`:

```zig
pub fn execAddAgent(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    const parsed = std.json.parseFromSlice(
        add_agent_mod.AddAgentInput,
        ctx.allocator,
        tc.function.arguments,
        .{ .allocate = .alloc_always },
    ) catch |err| {
        const err_msg = try std.fmt.allocPrint(ctx.allocator, "add_agent failed: {s}", .{@errorName(err)});
        const output = try wrapToolOutput(ctx.allocator, "add_agent", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    defer parsed.deinit();

    const inner = add_agent_mod.executeAddAgentToString(ctx.allocator, parsed.value) catch |err| {
        const err_msg = try std.fmt.allocPrint(ctx.allocator, "add_agent failed: {s}", .{@errorName(err)});
        const output = try wrapToolOutput(ctx.allocator, "add_agent", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };

    if (std.mem.indexOf(u8, inner, "<error>") != null) {
        const err_start = (std.mem.indexOf(u8, inner, "<error>") orelse 0) + "<error>".len;
        const err_end = std.mem.indexOf(u8, inner[err_start..], "</error>") orelse inner.len;
        const err_msg = inner[err_start .. err_start + err_end];
        const output = try wrapToolOutput(ctx.allocator, "add_agent", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    }

    const output = try wrapToolOutput(ctx.allocator, "add_agent", tc.function.arguments, true, null, inner);
    return ToolExecResult{ .output = output, .output_allocated = true };
}
```

- [ ] **Step 2.13: `execRemoveAgent` (line 410)**

Same pattern with tool name `"remove_agent"`.

- [ ] **Step 2.14: `execRemoveFile` (line 426)**

```zig
pub fn execRemoveFile(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    const parsed = try std.json.parseFromSlice(
        remove_file_mod.RemoveFileInput,
        ctx.allocator,
        tc.function.arguments,
        .{ .allocate = .alloc_always },
    );
    defer parsed.deinit();

    const inner = remove_file_mod.executeRemoveFileToString(ctx.allocator, ctx.io, parsed.value) catch |err| {
        const err_msg = try std.fmt.allocPrint(ctx.allocator, "remove_file failed: {s}", .{@errorName(err)});
        const output = try wrapToolOutput(ctx.allocator, "remove_file", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };

    if (std.mem.indexOf(u8, inner, "<error>") != null) {
        const err_start = (std.mem.indexOf(u8, inner, "<error>") orelse 0) + "<error>".len;
        const err_end = std.mem.indexOf(u8, inner[err_start..], "</error>") orelse inner.len;
        const err_msg = inner[err_start .. err_start + err_end];
        const output = try wrapToolOutput(ctx.allocator, "remove_file", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    }

    const output = try wrapToolOutput(ctx.allocator, "remove_file", tc.function.arguments, true, null, inner);
    return ToolExecResult{ .output = output, .output_allocated = true };
}
```

- [ ] **Step 2.15: `execListAgents` (line 442)**

```zig
pub fn execListAgents(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    _ = tc;
    const inner = list_agents_mod.executeListAgents(ctx.allocator, ctx.io, ctx.environment) catch |err| {
        const err_msg = try std.fmt.allocPrint(ctx.allocator, "list_agents failed: {s}", .{@errorName(err)});
        const output = try wrapToolOutput(ctx.allocator, "list_agents", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    const output = try wrapToolOutput(ctx.allocator, "list_agents", tc.function.arguments, true, null, inner);
    return ToolExecResult{ .output = output, .output_allocated = true };
}
```

- [ ] **Step 2.16: `execChangeAgent` (line 452)**

```zig
pub fn execChangeAgent(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    const parsed = try std.json.parseFromSlice(
        change_agent_mod.ChangeAgentInput,
        ctx.allocator,
        tc.function.arguments,
        .{ .allocate = .alloc_always },
    );
    defer parsed.deinit();

    const inner = change_agent_mod.execute_change_agent_to_string(ctx.allocator, ctx.io, ctx.environment, parsed.value) catch |err| {
        const err_msg = try std.fmt.allocPrint(ctx.allocator, "change_agent failed: {s}", .{@errorName(err)});
        const output = try wrapToolOutput(ctx.allocator, "change_agent", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };

    if (std.mem.indexOf(u8, inner, "<error>") != null) {
        const err_start = (std.mem.indexOf(u8, inner, "<error>") orelse 0) + "<error>".len;
        const err_end = std.mem.indexOf(u8, inner[err_start..], "</error>") orelse inner.len;
        const err_msg = inner[err_start .. err_start + err_end];
        const output = try wrapToolOutput(ctx.allocator, "change_agent", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    }

    const output = try wrapToolOutput(ctx.allocator, "change_agent", tc.function.arguments, true, null, inner);
    return ToolExecResult{ .output = output, .output_allocated = true };
}
```

- [ ] **Step 2.17: `execLspDefinition` (line 468)**

```zig
pub fn execLspDefinition(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    const parsed = try std.json.parseFromSlice(
        lsp_definition_mod.LspDefinitionInput,
        ctx.allocator,
        tc.function.arguments,
        .{ .allocate = .alloc_always },
    );
    defer parsed.deinit();

    const result = lsp_definition_mod.execute_lsp_definition(ctx.allocator, ctx.io, ctx.environment, parsed.value) catch |err| {
        const err_msg = try std.fmt.allocPrint(ctx.allocator, "lsp_definition failed: {s}", .{@errorName(err)});
        const output = try wrapToolOutput(ctx.allocator, "lsp_definition", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    defer result.deinit(ctx.allocator);

    const inner = try lsp_definition_mod.lsp_definition_to_string(ctx.allocator, result);
    const output = try wrapToolOutput(ctx.allocator, "lsp_definition", tc.function.arguments, true, null, inner);
    return ToolExecResult{ .output = output, .output_allocated = true };
}
```

- [ ] **Step 2.18: `execSetAgentProperties` (line 488)**

Update `handleSetAgentProperties` (line 511-535) to use `wrapToolOutput` instead of the typo-laden format string. Replace the function body:

```zig
fn handleSetAgentProperties(
    allocator: std.mem.Allocator,
    tool_call: agent.ToolCall,
) !SetAgentPropertiesResult {
    const parsed = try std.json.parseFromSlice(
        set_agent_properties_mod.SetAgentPropertiesResult,
        allocator,
        tool_call.function.arguments,
        .{},
    );
    defer parsed.deinit();

    // The execX contract is "set these fields and return the wrapped output".
    // We use the standardized envelope so handle_tool sees the same shape as
    // every other tool. The typo in the closing tag (`<set_agent_properties>`
    // without the `/`) in the previous version is fixed.
    const wrapped = try wrapToolOutput(allocator, "set_agent_properties", tool_call.function.arguments, true, null, "");

    return SetAgentPropertiesResult{
        .temperature = parsed.value.temperature,
        .is_thinking = parsed.value.is_thinking,
        .tool_call_id = try allocator.dupe(u8, tool_call.id),
        .arguments = wrapped,
    };
}
```

`execSetAgentProperties` itself stays the same shape:

```zig
pub fn execSetAgentProperties(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    const result = try handleSetAgentProperties(ctx.allocator, tc);
    return ToolExecResult{
        .output = result.arguments,
        .temperature = result.temperature,
        .is_thinking = result.is_thinking,
    };
}
```

- [ ] **Step 2.19: `execUpdateActivity` (line 538)**

```zig
pub fn execUpdateActivity(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    ctx.logger.debugFmt("[update_activity] Starting for session {s}", .{ctx.session_id});

    const parsed = try std.json.parseFromSlice(
        update_activity_mod.UpdateActivityInput,
        ctx.allocator,
        tc.function.arguments,
        .{ .allocate = .alloc_always },
    );
    defer parsed.deinit();

    const worker_id = try ctx.allocator.dupe(u8, ctx.session_id);
    defer ctx.allocator.free(worker_id);

    if (llm_history.updateWorkerActivityWithDescription(ctx.allocator, ctx.db, worker_id, parsed.value.thought)) |_| {
        ctx.logger.infoFmt("[update_activity] Updated activity for {s}: {s}", .{ worker_id, parsed.value.thought });
        const inner = update_activity_mod.xmlSuccess(ctx.allocator, parsed.value.thought);
        const output = try wrapToolOutput(ctx.allocator, "update_activity", tc.function.arguments, true, null, inner);
        return ToolExecResult{ .output = output, .output_allocated = true };
    } else |err| {
        ctx.logger.errFmt("[update_activity] Failed to update worker activity for {s}: {}", .{ worker_id, err });
        const inner = update_activity_mod.xmlError(ctx.allocator, "Failed to update worker activity");
        const err_msg = "Failed to update worker activity";
        const output = try wrapToolOutput(ctx.allocator, "update_activity", tc.function.arguments, false, err_msg, inner);
        return ToolExecResult{ .output = output, .output_allocated = true };
    }
}
```

- [ ] **Step 2.20: `execSpawnSubAgent` (line 603)**

At the end of the existing `<results>...</results>` block (around line 705), replace the `return ToolExecResult{ .output = try results.toOwnedSlice(ctx.allocator) };` with the wrap:

```zig
const inner_owned = try results.toOwnedSlice(ctx.allocator);
const output = try wrapToolOutput(ctx.allocator, "spawn_sub_agent", tc.function.arguments, true, null, inner_owned);
return ToolExecResult{ .output = output, .output_allocated = true };
```

(Remove the `aw.toArrayList()` line that was previously called and unused.)

- [ ] **Step 2.21: LSP placeholders (lines 804-830)**

```zig
pub fn execLspReferences(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    _ = ctx;
    _ = tc;
    const output = try wrapToolOutput(ctx.allocator, "lsp_references", tc.function.arguments, false, "lsp_references not implemented", "");
    return ToolExecResult{ .output = output, .output_allocated = true };
}
```

Same for `execLspWorkspaceSymbol`, `execLspDocumentSymbol`, `execLspHover`.

- [ ] **Step 2.22: `execWebSearch` (line 832)**

```zig
pub fn execWebSearch(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    const parsed = try std.json.parseFromSlice(
        tool_models.WebSearchInput,
        ctx.allocator,
        tc.function.arguments,
        .{ .allocate = .alloc_always },
    );
    defer parsed.deinit();

    const result = web_search_mod.execute_web_search(ctx.allocator, ctx.io, parsed.value) catch |err| {
        const err_msg = try std.fmt.allocPrint(ctx.allocator, "web_search failed: {s}", .{@errorName(err)});
        const output = try wrapToolOutput(ctx.allocator, "web_search", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    defer result.deinit(ctx.allocator);

    const inner = try web_search_mod.web_search_result_to_string(ctx.allocator, result);
    const output = try wrapToolOutput(ctx.allocator, "web_search", tc.function.arguments, true, null, inner);
    return ToolExecResult{ .output = output, .output_allocated = true };
}
```

- [ ] **Step 2.23: `execCloakBrowser` (line 848)**

```zig
pub fn execCloakBrowser(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    const parsed = try std.json.parseFromSlice(
        cloak_browser_mod.CloakBrowserInput,
        ctx.allocator,
        tc.function.arguments,
        .{ .allocate = .alloc_always },
    );
    defer parsed.deinit();

    const result = try cloak_browser_mod.execute_cloak_browser(ctx.allocator, ctx.io, parsed.value);

    if (result.success) {
        const inner = try cloak_browser_mod.toXMLSuccess(ctx.allocator, result);
        const output = try wrapToolOutput(ctx.allocator, "cloak_browser", tc.function.arguments, true, null, inner);
        return ToolExecResult{ .output = output, .output_allocated = true };
    } else {
        const inner = try cloak_browser_mod.toXMLError(ctx.allocator, result, parsed.value.action);
        const err_msg = try std.fmt.allocPrint(ctx.allocator, "cloak_browser {s} failed", .{parsed.value.action});
        const output = try wrapToolOutput(ctx.allocator, "cloak_browser", tc.function.arguments, false, err_msg, inner);
        return ToolExecResult{ .output = output, .output_allocated = true };
    }
}
```

- [ ] **Step 2.24: `execGlob` (line 868)**

```zig
pub fn execGlob(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    const args = tc.function.arguments;
    const args_to_parse: []const u8 = if (args.len == 0) "{}" else args;

    const parsed = try std.json.parseFromSlice(
        glob_tool_mod.GlobInput,
        ctx.allocator,
        args_to_parse,
        .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
    );
    defer parsed.deinit();

    const glob_result = glob_tool_mod.executeGlob(ctx.allocator, ctx.io, parsed.value) catch |err| {
        const err_msg = try std.fmt.allocPrint(ctx.allocator, "glob failed: {s}", .{@errorName(err)});
        const output = try wrapToolOutput(ctx.allocator, "glob", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };

    const inner = try glob_tool_mod.toXmlSuccess(ctx.allocator, glob_result, parsed.value.pattern);
    glob_result.deinit(ctx.allocator);
    const output = try wrapToolOutput(ctx.allocator, "glob", tc.function.arguments, true, null, inner);
    return ToolExecResult{ .output = output, .output_allocated = true };
}
```

- [ ] **Step 2.25: `execSearch` (line 887)**

```zig
pub fn execSearch(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    const args = tc.function.arguments;
    const args_to_parse: []const u8 = if (args.len == 0) "{}" else args;

    const parsed = try std.json.parseFromSlice(
        search_tool_mod.SearchInput,
        ctx.allocator,
        args_to_parse,
        .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
    );
    defer parsed.deinit();

    const search_result = search_tool_mod.executeSearch(ctx.allocator, ctx.io, ctx.cwd, parsed.value) catch |err| {
        if (err == error.StdoutStreamTooLong) {
            const err_msg = "Search output exceeded max_output limit. Use a larger max_output value (e.g. 5242880 for 5MB), narrow your search path, or use a more specific pattern.";
            const output = try wrapToolOutput(ctx.allocator, "search", tc.function.arguments, false, err_msg, "");
            return ToolExecResult{ .output = output, .output_allocated = true };
        }
        const err_msg = try std.fmt.allocPrint(ctx.allocator, "search failed: {s}", .{@errorName(err)});
        const output = try wrapToolOutput(ctx.allocator, "search", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };

    if (search_result.matches.items.len == 0) {
        const inner = try ctx.allocator.dupe(u8, search_result.content);
        search_result.deinit(ctx.allocator);
        const output = try wrapToolOutput(ctx.allocator, "search", tc.function.arguments, true, null, inner);
        return ToolExecResult{ .output = output, .output_allocated = true };
    }

    const inner = try search_tool_mod.search_result_to_string_grouped(
        ctx.allocator,
        search_result,
        parsed.value.pattern,
        parsed.value.path,
    );
    const output = try wrapToolOutput(ctx.allocator, "search", tc.function.arguments, true, null, inner);
    return ToolExecResult{ .output = output, .output_allocated = true };
}
```

- [ ] **Step 2.26: Build and run tests**

Run: `cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox && timeout 240 zig build 2>&1 | tail -n 30`
Expected: clean build.

Run: `cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox && timeout 180 zig build test 2>&1 | tail -n 30`
Expected: 311+ tests pass (304 existing + 7 new wrap tests). The existing tool-specific test files (parse_diff_view_test.zig, etc.) continue to pass because their assertions are on inner content that's now inside `<data>`.

- [ ] **Step 2.27: Commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
git add src/ai_workflow/tui/tool_registry.zig
git commit -m "refactor(tool-registry): wrap every execX output with <tool> envelope"
```

---

# Chunk 3: Update `handle_tool.zig` dispatch error paths

**Goal:** The dispatch-level error paths in `handle_tool.zig` (catches at `dispatchTool` and `dispatchMCP`) produce raw `<error>...</error>` strings — convert them to the wrapped envelope for consistency.

### Task 3: Update error paths

**Files:**
- Modify: `src/ai_workflow/tui/handle_tool.zig` (lines 406-413 and 419-427).

- [ ] **Step 3.1: Update the MCP error path (lines 406-413)**

Replace the error block body:

```zig
} catch |err| {
    const err_msg = try std.fmt.allocPrint(allocator, "MCP tool {s} failed: {s}", .{
        tool_call.function.name,
        @errorName(err),
    });
    tool_result = try tool_registry.wrapToolOutput(allocator, tool_call.function.name, tool_call.function.arguments, false, err_msg, "");
    errdefer allocator.free(tool_result);
    try saveAndSendToolResult(allocator, io, db, session_id, parent_session_id, model, cwd, loop_counter, tool_call, tool_result, toolAgentTemp, toolIsThinking, current_agent_for_save);
    allocator.free(tool_result);
    continue;
};
```

- [ ] **Step 3.2: Update the `dispatchTool` error path (lines 419-427)**

Replace the error block body:

```zig
const exec_result = dispatchTool(ctx, tool_call) catch |err| {
    std.debug.print("DEBUG: dispatchTool failed with error: {s}\n", .{@errorName(err)});
    const err_msg = try std.fmt.allocPrint(allocator, "{s} failed: {s}", .{
        tool_call.function.name,
        @errorName(err),
    });
    tool_result = try tool_registry.wrapToolOutput(allocator, tool_call.function.name, tool_call.function.arguments, false, err_msg, "");
    errdefer allocator.free(tool_result);
    try saveAndSendToolResult(allocator, io, db, session_id, parent_session_id, model, cwd, loop_counter, tool_call, tool_result, toolAgentTemp, toolIsThinking, current_agent_for_save);
    allocator.free(tool_result);
    continue;
};

tool_result = exec_result.output;
```

- [ ] **Step 3.3: Verify `parseDiffViewFromResult` still works**

The substring search for `<diff_view>` inside `saveAndSendToolResult` still works (the diff_view tag is now inside `<data>`, but substring search is position-independent). **No change needed** to that function.

- [ ] **Step 3.4: Build and run tests**

Run: `cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox && timeout 240 zig build 2>&1 | tail -n 30`
Expected: clean build.

Run: `cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox && timeout 180 zig build test 2>&1 | tail -n 30`
Expected: 311+ tests pass.

- [ ] **Step 3.5: Commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
git add src/ai_workflow/tui/handle_tool.zig
git commit -m "refactor(handle-tool): use wrapToolOutput for dispatch error paths"
```

---

# Chunk 4: Frontend unwrap helper + ChatView update

**Goal:** The frontend parses the envelope once in `ChatView.vue`, passes the inner `<data>` content to the existing `tool_outputs/*.vue` components (which continue to parse their own inner tags unchanged), and displays a consistent summary in the fallback branch.

### Task 4: Create the unwrap helper and update ChatView

**Files:**
- Create: `src/apps/desktop/src/helpers/unwrapToolOutput.ts`
- Create: `src/apps/desktop/src/helpers/unwrapToolOutput.spec.ts`
- Modify: `src/apps/desktop/src/components/ChatView.vue`

- [ ] **Step 4.1: Write the failing test file**

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
    expect(() => unwrapToolOutput('<tool><name>foo</name>')).toThrow()
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

- [ ] **Step 4.2: Implement the helper**

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
 * Reverse the XML escaping applied by the backend's `wrapToolOutput`.
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
 * The backend produces this envelope in `tool_registry.wrapToolOutput`.
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

- [ ] **Step 4.3: Run the test to verify it passes**

Run: `cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/src/apps/desktop && timeout 60 bunx vitest run helpers/unwrapToolOutput.spec.ts 2>&1 | tail -n 20`
Expected: 5 tests pass.

- [ ] **Step 4.4: Update `ChatView.vue` — import and helpers**

In the `<script setup>` block, add the import (around line 14):

```ts
import { tryUnwrapToolOutput, type UnwrappedToolOutput } from '@/helpers/unwrapToolOutput'
```

Add a computed map and helper function (after the existing `messageGroups` computed, around line 580):

```ts
// Per-message envelope unwrap lookup. Keyed by message id; value is the
// parsed envelope or null if the content is not a <tool> envelope (legacy
// or non-tool content). Computed once when messages change so the
// template can do a cheap O(1) lookup per tool component.
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

- [ ] **Step 4.5: Update the template — pass `innerToolData(msg)` to tool components**

In the template (lines 1777-1859), change every `:content="msg.content"` to `:content="innerToolData(msg)"`. The components affected: `ReadFile`, `WriteFile`, `UpdateActivity`, `Search`, `Glob`, `TextReplace`, `Bash`, `GetSkill`, `ViewSkill`, `ListSkills`, `AddSkill`, `EditSkill`, `RemoveSkill`, `RemoveFile`, `SpawnSubAgent`.

- [ ] **Step 4.6: Update `renderResponse` fallback for the new envelope**

Replace the fallback at line 204 of `ChatView.vue`:

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

Add CSS for the new classes (after the existing `.tool-inline` rules around line 2402):

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

- [ ] **Step 4.7: Build and run frontend tests**

Run: `cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/src/apps/desktop && timeout 120 bun run build 2>&1 | tail -n 20`
Expected: clean. No `vue-tsc` errors.

Run: `cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/src/apps/desktop && timeout 60 bunx vitest run 2>&1 | tail -n 20`
Expected: 36 tests pass (31 existing + 5 new unwrap tests).

- [ ] **Step 4.8: Manual smoke test on port 8080**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
./zig-out/bin/nalar --port 8080
```

In the desktop app (port 8080):
1. Ask the agent to `read_file /etc/hostname`. Verify the `ReadFile.vue` bubble renders the file content (the inner `<data>` is what it parses).
2. Ask the agent to `bash echo hello`. Verify the `Bash.vue` bubble renders the stdout.
3. Ask the agent to `read_file /nonexistent`. Verify the error is shown.
4. Ask the agent to `list_skills`. Verify the `ListSkills.vue` bubble shows the skills.

- [ ] **Step 4.9: Commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
git add src/apps/desktop/src/helpers/unwrapToolOutput.ts \
        src/apps/desktop/src/helpers/unwrapToolOutput.spec.ts \
        src/apps/desktop/src/components/ChatView.vue
git commit -m "feat(desktop): unwrap <tool> envelope in ChatView, pass <data> to tool components"
```

---

# Verification (final)

1. **Backend tests** — `timeout 180 zig build test 2>&1 | tail -n 30` → 311+ tests pass.
2. **Backend build** — `timeout 240 zig build 2>&1 | tail -n 20` → clean.
3. **Frontend type-check** — `timeout 120 bun run build 2>&1 | tail -n 20` → clean.
4. **Frontend tests** — `timeout 60 bunx vitest run 2>&1 | tail -n 20` → 36 tests pass.
5. **End-to-end smoke** (manual step 4.8) — every tool type renders correctly with the new envelope.

---

# Pitfalls (cumulative)

1. **The `output_allocated` flag is set inconsistently in the existing code.** After the refactor, set it to `true` consistently (the wrap always allocates). Existing leaks of inner allocations (e.g. `runWithContext` returns an allocated string) are preserved for now — fixing them is a separate task.

2. **The `set_agent_properties` tool's current output has a typo**: it emits `<set_agent_properties>\n...\n<set_agent_properties>` (missing `/` in the closing tag). The refactor fixes this by using the standardized envelope (the typo'd content is gone, replaced by the clean envelope).

3. **`execGetSkill` auto-save detection.** The exec function looks for `<success>true</success>` in the output to decide whether to trigger `SkillSaveInfo`. After the refactor, the wrapper always emits the success tag at position 0, so the detection works.

4. **`execSpawnSubAgent` is the most complex refactor** because it builds its own XML block via `std.Io.Writer`. The wrap with `wrapToolOutput` happens at the very end, after the existing block is built. The previous `aw.toArrayList()` call is no longer needed (replace with `try results.toOwnedSlice(ctx.allocator)`).

5. **Tool modules do NOT need changes.** Their `toXmlSuccess`/`toXmlError` outputs go inside `<data>` unchanged. The frontend tool components receive `<data>` via `innerToolData(msg)` and parse the same inner tags they always have.

6. **`parseDiffViewFromResult` in `handle_tool.zig` is substring-based** — it works regardless of the surrounding wrapper, so no change is needed.

7. **Memory: `runWithContext` returns a `[]const u8` that is leaked today** (the existing code doesn't set `output_allocated`). The refactor preserves this leak. Fixing it is out of scope.

8. **The `<data>` may contain nested `<data>` if a tool's inner XML has a `<data>` tag.** None of the existing tools produce a `<data>` tag in their inner output (verified by grep), so this is not a current problem. If a future tool does, the unwrap parser will need a depth-aware `findTag`. The current implementation uses the first match.
