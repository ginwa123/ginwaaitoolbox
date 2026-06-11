# Standardize Inner Tool Output XML Shape (No Envelope)

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make every tool's output XML emit the same shape — `<success>true</success>` + tool-specific inner tags on success, or `<error>...</error>` on failure — so the LLM and the frontend can rely on one consistent format. **No outer envelope** (no `<tool>...</tool>` wrapper, no `<name>`, no `<parameters>`). The frontend `tool_outputs/*.vue` components and `ChatView.vue` are updated to parse the new shape.

**Architecture:**
- **Backend (Zig):** Add two private helpers in `tool_registry.zig` — `successOutput(allocator, inner)` and `errorOutput(allocator, err_msg, inner)` — that prepend `<success>true</success>` or `<error>...</error>` to the inner tool-specific XML. Each `execX` function ends with one of these calls instead of returning raw inner XML. Tool modules (`read_file.zig`, `text_replace.zig`, `write_file.zig`, `get_skill.zig`, `list_memory.zig`, `bash.zig`, `list_skills.zig`) are updated to emit **only their tool-specific inner data** — no `<success>`, no `<error>`, no `<loaded>` success flag. The frontend `Bash.vue` component (which currently expects raw text from `bash_result_to_string`) is updated to parse the new structured format.
- **Frontend (Vue/TS):** The 13 `tool_outputs/*.vue` components are updated to expect `<success>true</success>` at the start of every successful tool output and `<error>...</error>` on failure. `ChatView.vue`'s fallback `renderResponse()` is updated to parse the same shape. No new `unwrapToolOutput` helper is needed (there is no outer envelope to strip).

**Tech Stack:** Zig 0.15.2 (backend, `nalarcore`), Vue 3 + TypeScript (frontend, `apps/desktop`), Vite/Vitest.

---

## Target Output Shape

### Success
```xml
<success>true</success>
<tool-specific tags>
```
Examples:
- `read_file`: `<success>true</success><path>/foo</path><content>hello</content>`
- `text_replace`: `<success>true</success><result>...</result><diff_view>...</diff_view>`
- `write_file`: `<success>true</success><result>...</result>`
- `get_skill`: `<success>true</success><skill_name>...</skill_name><content>...</content>`
- `bash`: `<success>true</success><stdout>...</stdout><stderr>...</stderr><exit_code>0</exit_code>`

### Failure
```xml
<error>human-readable error message</error>
```
The inner tool-specific tags are omitted on failure (the error is the only data).

**XML escaping rules:** `<`, `>`, `&`, `"`, `'` are escaped in the error message and any tool-specific inner data the helper touches. Tool modules' own `toXmlSuccess`/`toXmlError` functions already escape their inner content, so the helper only needs to escape the error message.

---

## File Structure

### New files
- `src/ai_workflow/tui/tool_registry_test.zig` — unit tests for `successOutput` and `errorOutput`.

### Modified files (backend)
- `src/ai_workflow/tui/tool_registry.zig` — add `successOutput` and `errorOutput` helpers. Refactor 25 `execX` functions to call them.
- `src/ai_workflow/tui/test_runner.zig` — register the new test file.
- `src/ai_workflow/tui/handle_tool.zig` — update the dispatch-level error paths (`dispatchTool` and `dispatchMCP` catches) to produce the new shape instead of raw `<error>...</error>` strings. The `parseDiffViewFromResult` substring search continues to work (diff_view is still inside the output, just with a `<success>true</success>` prefix now).

### Modified files (tool modules — strip their existing success/error tags)
- `src/ai_workflow/tui/read_file.zig` — `toXMLSuccess` continues to emit `<path>...</path><content>...</content>` (no success tag, the helper adds it).
- `src/ai_workflow/tui/text_replace.zig` — `toXmlSuccess` removes the `<success>true</success>` line. `toXmlError` removes the `<success>false</success><error>...</error>` line and just emits the tool-specific error body.
- `src/ai_workflow/tui/write_file.zig` — same as `text_replace.zig`.
- `src/ai_workflow/tui/get_skill.zig` — replace `<loaded>true</loaded>` with no success indicator (the helper adds `<success>true</success>`). Replace `<loaded>false</loaded><error>...</error>` with no body on failure.
- `src/ai_workflow/tui/list_memory.zig` — emit `<memories>...</memories>` on success or no body on failure (the helper adds the wrapper).
- `src/ai_workflow/tui/list_skills.zig` — convert from JSON output to XML (mirrors the new shape).
- `src/ai_workflow/tui/bash.zig` — `bash_result_to_string` emits `<stdout>...</stdout><stderr>...</stderr><exit_code>...</exit_code>` instead of plain text. This is the largest backend change.
- `src/ai_workflow/tui/lsp_definition.zig` — minor: ensure output doesn't include its own `<success>` tag.
- `src/ai_workflow/tui/cloak_browser.zig` — `toXMLSuccess` and `toXMLError` strip their success/error tags (the helper adds them).

### Modified files (frontend)
- `src/apps/desktop/src/components/ChatView.vue` — `renderResponse()` fallback updated to parse the new shape. Existing tool-specific branches (`<path>`, `<file path=...`, `<agent name=...`) are adjusted to look inside the new success/error body.
- `src/apps/desktop/src/components/Bash.vue` — updated to parse `<success>...</success><stdout>...</stdout><stderr>...</stderr><exit_code>...</exit_code>` instead of the current plain-text format.
- `src/apps/desktop/src/components/tool_outputs/ListSkills.vue` — updated to expect XML instead of JSON.
- `src/apps/desktop/src/components/tool_outputs/ReadFile.vue` — already has `isSuccess` parsing; updated to read the new `<success>true</success>` location.
- `src/apps/desktop/src/components/tool_outputs/WriteFile.vue` — same.
- `src/apps/desktop/src/components/tool_outputs/TextReplace.vue` — already has `isSuccess` parsing; updated for the new location.
- `src/apps/desktop/src/components/tool_outputs/GetSkill.vue` — `loaded` check updated to `success` check.
- `src/apps/desktop/src/components/tool_outputs/ViewSkill.vue` — same.
- `src/apps/desktop/src/components/tool_outputs/AddSkill.vue` — same.
- `src/apps/desktop/src/components/tool_outputs/EditSkill.vue` — same.
- `src/apps/desktop/src/components/tool_outputs/RemoveSkill.vue` — replaces `removed` check with `success` check.
- `src/apps/desktop/src/components/tool_outputs/RemoveFile.vue` — same.
- `src/apps/desktop/src/components/tool_outputs/SpawnSubAgent.vue` — minor; the `<agent name="..." success="...">` parsing stays (it's an inner agent-result tag, not the outer success indicator).

### Out of scope
- The outer `<tool>...</tool>` envelope (rejected — user said "no wrapper").
- Adding `<name>` or `<parameters>` to the output (those are tool-call metadata, not output).
- `set_agent_properties` and `update_activity` (these have their own inner formats; they get the same wrapper via the helper).
- The `lsp_references`/`lsp_workspace_symbol`/`lsp_document_symbol`/`lsp_hover` placeholder exec functions (they return hardcoded strings, no XML).
- The `execSpawnSubAgent` XML format (it already has a clear shape: `<results>...</results>` with per-agent tags; just add `<success>true</success>` prefix via the helper).

---

# Chunk 1: Backend helpers + tests

**Goal:** Add `successOutput` and `errorOutput` to `tool_registry.zig`, write unit tests for them, register the tests. No callsite changes yet.

### Task 1: Add the helpers and tests

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

test "successOutput - prepends <success>true</success> to inner XML" {
    const allocator = testing.allocator;
    const out = try tool_registry.successOutput(allocator, "<path>/foo</path><content>hello</content>");
    defer allocator.free(out);
    try testing.expectEqualStrings("<success>true</success><path>/foo</path><content>hello</content>", out);
}

test "successOutput - empty inner produces just the success tag" {
    const allocator = testing.allocator;
    const out = try tool_registry.successOutput(allocator, "");
    defer allocator.free(out);
    try testing.expectEqualStrings("<success>true</success>", out);
}

test "errorOutput - emits <error>msg</error> on failure, omits inner" {
    const allocator = testing.allocator;
    const out = try tool_registry.errorOutput(allocator, "File not found", "");
    defer allocator.free(out);
    try testing.expectEqualStrings("<error>File not found</error>", out);
}

test "errorOutput - XML-escapes the error message" {
    const allocator = testing.allocator;
    const out = try tool_registry.errorOutput(allocator, "bad <tag> & \"quote\"", "");
    defer allocator.free(out);
    try testing.expectEqualStrings("<error>bad &lt;tag&gt; &amp; &quot;quote&quot;</error>", out);
}

test "errorOutput - empty error message becomes 'unknown error'" {
    const allocator = testing.allocator;
    const out = try tool_registry.errorOutput(allocator, "", "");
    defer allocator.free(out);
    try testing.expectEqualStrings("<error>unknown error</error>", out);
}

test "successOutput and errorOutput are allocated (caller owns)" {
    const allocator = testing.allocator;
    const s = try tool_registry.successOutput(allocator, "x");
    defer allocator.free(s);
    const e = try tool_registry.errorOutput(allocator, "y", "");
    defer allocator.free(e);
    try testing.expect(s.len > 0);
    try testing.expect(e.len > 0);
}
```

- [ ] **Step 1.2: Run tests to verify they fail**

Run: `cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox && timeout 180 zig build test 2>&1 | tail -n 30`
Expected: compilation error — `successOutput` and `errorOutput` do not exist in `tool_registry`.

- [ ] **Step 1.3: Implement the helpers**

In `src/ai_workflow/tui/tool_registry.zig`, add this block immediately before the `// UNIFIED TOOL REGISTRY` section header (around line 957):

```zig
// ============================================================================
// STANDARDIZED TOOL OUTPUT SHAPE
// ============================================================================
//
// Every `execX` function below MUST end with one of:
//   - `successOutput(allocator, inner)` → `<success>true</success>` + inner
//   - `errorOutput(allocator, err_msg, inner)` → `<error>...</error>`
//
// Tool modules (`read_file.zig`, `text_replace.zig`, etc.) emit only their
// tool-specific inner data — no `<success>`, no `<error>`, no `<loaded>`
// flag. The two helpers below add the standardized wrapper so the LLM and
// the frontend see one consistent shape across every tool.

/// XML-escape special characters. Identical to `llm_history.zig:762`
/// `xmlEscape` — re-implemented here to keep this module self-contained
/// (so callers don't pull in `llm_history.zig`'s sqlite/agent dependency
/// tree just to build a success/error output).
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

/// Build a success output: `<success>true</success>` followed by the
/// tool-specific inner XML. The inner is NOT XML-escaped here — the
/// tool module is responsible for escaping its own inner data.
///
/// Caller owns the returned slice; free with `allocator.free`.
pub fn successOutput(allocator: std.mem.Allocator, inner: []const u8) ![]u8 {
    return try std.fmt.allocPrint(allocator, "<success>true</success>{s}", .{inner});
}

/// Build a failure output: `<error>...</error>` with the error message
/// XML-escaped. The `inner` argument is reserved for future tool-specific
/// error context (e.g. `<stdout>...</stdout>` for bash); pass `""` if
/// the tool has no extra error context to surface.
///
/// Caller owns the returned slice; free with `allocator.free`.
pub fn errorOutput(allocator: std.mem.Allocator, err_msg: []const u8, inner: []const u8) ![]u8 {
    const msg = if (err_msg.len == 0) "unknown error" else err_msg;
    const escaped = try xmlEscape(allocator, msg);
    defer allocator.free(escaped);
    if (inner.len == 0) {
        return try std.fmt.allocPrint(allocator, "<error>{s}</error>", .{escaped});
    }
    const escaped_inner = try xmlEscape(allocator, inner);
    defer allocator.free(escaped_inner);
    return try std.fmt.allocPrint(allocator, "<error>{s}</error>{s}", .{ escaped, escaped_inner });
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
Expected: 6 new tests pass; existing tests untouched (helpers are unused so far).

- [ ] **Step 1.6: Commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
git add src/ai_workflow/tui/tool_registry.zig \
        src/ai_workflow/tui/tool_registry_test.zig \
        src/ai_workflow/tui/test_runner.zig
git commit -m "feat(tool-registry): add successOutput/errorOutput helpers for standardized tool output shape"
```

---

# Chunk 2: Refactor `execX` functions in `tool_registry.zig`

**Goal:** Each `execX` function ends with `successOutput(...)` or `errorOutput(...)` instead of returning raw inner XML. This is purely a change in the `execX` functions — the tool modules' `toXmlSuccess`/`toXmlError` changes happen in Chunk 3.

For each `execX`, the pattern is:
- **Success path**: `return ToolExecResult{ .output = try successOutput(ctx.allocator, inner) }`
- **Error path (in the exec function)**: `return ToolExecResult{ .output = try errorOutput(ctx.allocator, err_msg, "") }`

### Task 2: Refactor each `execX` function

**Files:**
- Modify: `src/ai_workflow/tui/tool_registry.zig` (25 `execX` functions, lines 176-925).

- [ ] **Step 2.1: Refactor `execBash` (line 176)**

Current:
```zig
pub fn execBash(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    const output = try runWithContext(ctx.allocator, ctx.io, tc, ctx.db, ctx.session_id);
    return ToolExecResult{ .output = output };
}
```

Change to (note: `bash_result_to_string` will be updated in Chunk 3 to emit `<stdout>...</stdout><stderr>...</stderr><exit_code>...</exit_code>` instead of plain text, but the exec function shape stays the same):

```zig
pub fn execBash(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    const inner = try runWithContext(ctx.allocator, ctx.io, tc, ctx.db, ctx.session_id);
    const output = try successOutput(ctx.allocator, inner);
    return ToolExecResult{ .output = output, .output_allocated = true };
}
```

- [ ] **Step 2.2: Refactor `execReadFile` (line 181)**

Change to:
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
        const output = try errorOutput(ctx.allocator, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    defer parsed.deinit();

    const read_opts = read_file_mod.ReadFileOptions{
        .offset = parsed.value.offset,
        .limit = parsed.value.limit,
    };

    const read_result = read_file_mod.readFile(ctx.allocator, ctx.io, parsed.value.path, read_opts) catch |err| {
        const err_msg = try std.fmt.allocPrint(ctx.allocator, "read_file failed: {s}", .{@errorName(err)});
        const output = try errorOutput(ctx.allocator, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    defer read_result.deinit(ctx.allocator);

    // toXMLSuccess emits <path>...</path><content>...</content> (no success tag)
    const inner = try read_file_mod.toXMLSuccess(ctx.allocator, read_result, parsed.value.path);
    const output = try successOutput(ctx.allocator, inner);
    return ToolExecResult{ .output = output, .output_allocated = true };
}
```

- [ ] **Step 2.3: Refactor `execTextReplace` (line 207)**

Change to (note: `text_replace_mod.toXmlSuccess` will be updated in Chunk 3 to drop its own `<success>true</success>` line; `toXmlError` will be updated to drop its own success/error tags):

```zig
pub fn execTextReplace(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    const parsed = std.json.parseFromSlice(
        text_replace_mod.TextReplaceInput,
        ctx.allocator,
        tc.function.arguments,
        .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
    ) catch |err| {
        const err_msg = try std.fmt.allocPrint(ctx.allocator, "text_replace failed: {s}", .{@errorName(err)});
        const output = try errorOutput(ctx.allocator, err_msg, "");
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
        const output = try errorOutput(ctx.allocator, err_msg, inner);
        return ToolExecResult{ .output = output, .output_allocated = true };
    };

    const inner = text_replace_mod.toXmlSuccess(ctx.allocator, result, parsed.value.path);
    const output = try successOutput(ctx.allocator, inner);
    return ToolExecResult{ .output = output, .output_allocated = true };
}
```

- [ ] **Step 2.4: Refactor `execWriteFile` (line 239)**

Same pattern as `execTextReplace`. Success path: `successOutput`. Error path: `errorOutput` with the inner error body from `toXmlError`.

- [ ] **Step 2.5: Refactor `execListSkills` (line 258)**

Current:
```zig
pub fn execListSkills(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    _ = tc;
    const output = list_skills_mod.execute_list_skills(ctx.allocator, ctx.io, ctx.cwd, ctx.environment) catch blk: {
        break :blk try std.fmt.allocPrint(ctx.allocator, "{{\"error\": \"Failed to list skills\"}}", .{});
    };
    return ToolExecResult{ .output = output, .output_allocated = true };
}
```

Change to:
```zig
pub fn execListSkills(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    _ = tc;
    const inner = list_skills_mod.execute_list_skills(ctx.allocator, ctx.io, ctx.cwd, ctx.environment) catch |err| {
        const err_msg = try std.fmt.allocPrint(ctx.allocator, "list_skills failed: {s}", .{@errorName(err)});
        const output = try errorOutput(ctx.allocator, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    const output = try successOutput(ctx.allocator, inner);
    return ToolExecResult{ .output = output, .output_allocated = true };
}
```

- [ ] **Step 2.6: Refactor `execListMemory` (line 271)**

Current:
```zig
pub fn execListMemory(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    _ = tc;
    const output = list_memory_mod.execute_list_memory(ctx.allocator, ctx.io, ctx.environment) catch blk: {
        break :blk try ctx.allocator.dupe(u8, "<memories><error>Failed to list memories</error></memories>");
    };
    return ToolExecResult{ .output = output, .output_allocated = true };
}
```

Change to:
```zig
pub fn execListMemory(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    _ = tc;
    const inner = list_memory_mod.execute_list_memory(ctx.allocator, ctx.io, ctx.environment) catch |err| {
        const err_msg = try std.fmt.allocPrint(ctx.allocator, "list_memory failed: {s}", .{@errorName(err)});
        const output = try errorOutput(ctx.allocator, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    const output = try successOutput(ctx.allocator, inner);
    return ToolExecResult{ .output = output, .output_allocated = true };
}
```

- [ ] **Step 2.7: Refactor `execGetSkill` (line 282)**

This one is more complex because the success path triggers a `SkillSaveInfo` side effect. The output structure stays the same; only the wrapping changes. The auto-save detection needs to look for the new `<success>true</success>` tag instead of `<loaded>true</loaded>`:

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
        const output = try errorOutput(ctx.allocator, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    const output = try successOutput(ctx.allocator, inner);

    // Auto-save: detect <success>true</success> + extract skill_name and content.
    // (Previously checked <loaded>true</loaded>; that tag has been removed in
    // favor of the standardized <success>true</success> wrapper.)
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

- [ ] **Step 2.8: Refactor `execViewSkill` (line 330)**

Current pattern returns `<skill_name></skill_name><description></description><found>false</found><error>Failed to view skill</error>` on error. After the refactor, the `view_skill_mod.execute_view_skill_to_string` (Chunk 3) will emit just `<skill_name>...</skill_name><description>...</description>` (no `<found>` flag). The exec function decides success/error based on whether the inner content is non-empty:

```zig
pub fn execViewSkill(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    const parsed = std.json.parseFromSlice(
        view_skill_mod.ViewSkillInput,
        ctx.allocator,
        tc.function.arguments,
        .{ .allocate = .alloc_always },
    ) catch |err| {
        const err_msg = try std.fmt.allocPrint(ctx.allocator, "view_skill failed: {s}", .{@errorName(err)});
        const output = try errorOutput(ctx.allocator, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    defer parsed.deinit();

    const inner = view_skill_mod.execute_view_skill_to_string(ctx.allocator, ctx.io, parsed.value, ctx.environment) catch |err| {
        const err_msg = try std.fmt.allocPrint(ctx.allocator, "view_skill failed: {s}", .{@errorName(err)});
        const output = try errorOutput(ctx.allocator, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };

    // Treat empty skill_name as failure (skill not found)
    if (std.mem.indexOf(u8, inner, "<skill_name></skill_name>") != null) {
        const err_msg = try ctx.allocator.dupe(u8, "Skill not found");
        const output = try errorOutput(ctx.allocator, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    }

    const output = try successOutput(ctx.allocator, inner);
    return ToolExecResult{ .output = output, .output_allocated = true };
}
```

- [ ] **Step 2.9: Refactor `execRemoveSkill` (line 346)**

The `remove_skill_mod.execute_remove_skill_to_string` (Chunk 3) will return just `<skill_name>...</skill_name><path>...</path>` on success. The exec function decides success vs. error:

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
        const output = try errorOutput(ctx.allocator, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };

    // If the inner result contains <error>...</error>, treat as failure
    if (std.mem.indexOf(u8, inner, "<error>") != null) {
        // Extract the error message and re-emit via the standard helper
        const err_start = (std.mem.indexOf(u8, inner, "<error>") orelse 0) + "<error>".len;
        const err_end = std.mem.indexOf(u8, inner[err_start..], "</error>") orelse inner.len;
        const err_msg = inner[err_start .. err_start + err_end];
        const output = try errorOutput(ctx.allocator, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    }

    const output = try successOutput(ctx.allocator, inner);
    return ToolExecResult{ .output = output, .output_allocated = true };
}
```

- [ ] **Step 2.10: Refactor `execAddSkill` (line 362)**

Same pattern. Inner from `add_skill_mod.executeAddSkillToString` (which will be updated in Chunk 3 to drop its own success tag) gets wrapped via `successOutput`. Error path uses `errorOutput`.

- [ ] **Step 2.11: Refactor `execEditSkill` (line 375)**

Same pattern as `execAddSkill`.

- [ ] **Step 2.12: Refactor `execAddAgent` (line 391)**

Same pattern. Wrap `add_agent_mod.executeAddAgentToString` output with `successOutput`. Error path uses `errorOutput`.

- [ ] **Step 2.13: Refactor `execRemoveAgent` (line 410)**

Same pattern.

- [ ] **Step 2.14: Refactor `execRemoveFile` (line 426)**

Same pattern.

- [ ] **Step 2.15: Refactor `execListAgents` (line 442)**

Current returns a JSON error string. After Chunk 3, `list_agents_mod.executeListAgents` returns XML. Wrap with `successOutput` or `errorOutput`.

- [ ] **Step 2.16: Refactor `execChangeAgent` (line 452)**

Same pattern.

- [ ] **Step 2.17: Refactor `execLspDefinition` (line 468)**

Same pattern. Inner from `lsp_definition_mod.lsp_definition_to_string` (Chunk 3 will strip its own success tag if any).

- [ ] **Step 2.18: Refactor `execSetAgentProperties` (line 488)**

Current returns a custom `<set_agent_properties>\n{args}\n<set_agent_properties>` (note: typo in the current code — the closing tag is wrong). Replace with the standardized shape:

```zig
pub fn execSetAgentProperties(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    const result = try handleSetAgentProperties(ctx.allocator, tc);
    return ToolExecResult{
        .output = result.arguments, // already a wrapped XML string built below
        .temperature = result.temperature,
        .is_thinking = result.is_thinking,
    };
}
```

And update `handleSetAgentProperties` (line 511-535) to use `successOutput` instead of the typo-laden format string:

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

    const inner = try std.fmt.allocPrint(allocator, "<temperature>{?}</temperature><is_thinking>{?}</is_thinking>", .{
        parsed.value.temperature,
        parsed.value.is_thinking,
    });
    const wrapped = try successOutput(allocator, inner);

    return SetAgentPropertiesResult{
        .temperature = parsed.value.temperature,
        .is_thinking = parsed.value.is_thinking,
        .tool_call_id = try allocator.dupe(u8, tool_call.id),
        .arguments = wrapped,
    };
}
```

- [ ] **Step 2.19: Refactor `execUpdateActivity` (line 538)**

Current uses `update_activity_mod.xmlSuccess` and `xmlError` (which produce their own success/error tags). After Chunk 3, those return just the inner body. The exec function wraps via the helper:

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
        const output = try successOutput(ctx.allocator, inner);
        return ToolExecResult{ .output = output, .output_allocated = true };
    } else |err| {
        ctx.logger.errFmt("[update_activity] Failed to update worker activity for {s}: {}", .{ worker_id, err });
        const inner = update_activity_mod.xmlError(ctx.allocator, "Failed to update worker activity");
        const output = try errorOutput(ctx.allocator, "Failed to update worker activity", inner);
        return ToolExecResult{ .output = output, .output_allocated = true };
    }
}
```

- [ ] **Step 2.20: Refactor `execSpawnSubAgent` (line 603)**

The current code builds a `<results>...</results>` block with per-agent tags. After the refactor, this block is the "inner" — wrap it with `successOutput` (or `errorOutput` if all agents failed). Read the existing code (lines 681-705) and add the wrap at the very end:

```zig
// After the existing <results>...</results> block
const inner = aw.toArrayList();
const inner_owned = try results.toOwnedSlice(ctx.allocator);
const output = try successOutput(ctx.allocator, inner_owned);
return ToolExecResult{ .output = output, .output_allocated = true };
```

(Free the unused `inner` from `aw.toArrayList()` — exact teardown will need care; mirror the existing `var results = std.ArrayList(u8).empty;` / `defer results.deinit(ctx.allocator);` pattern but use the toOwnedSlice version.)

- [ ] **Step 2.21: Refactor the LSP placeholders (line 804-830)**

Current:
```zig
pub fn execLspReferences(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    _ = ctx;
    _ = tc;
    const output = "lsp_references not implemented";
    return ToolExecResult{ .output = output };
}
```

Change to:
```zig
pub fn execLspReferences(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    _ = ctx;
    _ = tc;
    const output = try errorOutput(ctx.allocator, "lsp_references not implemented", "");
    return ToolExecResult{ .output = output, .output_allocated = true };
}
```

(Same for `execLspWorkspaceSymbol`, `execLspDocumentSymbol`, `execLspHover`.)

- [ ] **Step 2.22: Refactor `execWebSearch` (line 832)**

Wrap `web_search_mod.web_search_result_to_string` output with `successOutput`. Error path uses `errorOutput`.

- [ ] **Step 2.23: Refactor `execCloakBrowser` (line 848)**

Current:
```zig
if (result.success) {
    const output = try cloak_browser_mod.toXMLSuccess(ctx.allocator, result);
    return ToolExecResult{ .output = output, .output_allocated = true };
} else {
    const output = try cloak_browser_mod.toXMLError(ctx.allocator, result, parsed.value.action);
    return ToolExecResult{ .output = output, .output_allocated = true };
}
```

Change to (the tool module's `toXMLSuccess`/`toXMLError` will be updated in Chunk 3 to drop their own success/error tags):

```zig
if (result.success) {
    const inner = try cloak_browser_mod.toXMLSuccess(ctx.allocator, result);
    const output = try successOutput(ctx.allocator, inner);
    return ToolExecResult{ .output = output, .output_allocated = true };
} else {
    const inner = try cloak_browser_mod.toXMLError(ctx.allocator, result, parsed.value.action);
    const err_msg = try std.fmt.allocPrint(ctx.allocator, "cloak_browser {s} failed", .{parsed.value.action});
    const output = try errorOutput(ctx.allocator, err_msg, inner);
    return ToolExecResult{ .output = output, .output_allocated = true };
}
```

- [ ] **Step 2.24: Refactor `execGlob` (line 868)**

Wrap `glob_tool_mod.toXmlSuccess` output with `successOutput`. Error path uses `errorOutput`.

- [ ] **Step 2.25: Refactor `execSearch` (line 887)**

Current has special-cased handling for `StdoutStreamTooLong` and zero matches. After the refactor:

```zig
const inner = search_tool_mod.executeSearch(ctx.allocator, ctx.io, ctx.cwd, parsed.value) catch |err| {
    if (err == error.StdoutStreamTooLong) {
        const output = try errorOutput(ctx.allocator, "Search output exceeded max_output limit. Use a larger max_output value (e.g. 5242880 for 5MB), narrow your search path, or use a more specific pattern.", "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    }
    const err_msg = try std.fmt.allocPrint(ctx.allocator, "search failed: {s}", .{@errorName(err)});
    const output = try errorOutput(ctx.allocator, err_msg, "");
    return ToolExecResult{ .output = output, .output_allocated = true };
};

if (search_result.matches.items.len == 0) {
    const inner_empty = try ctx.allocator.dupe(u8, search_result.content);
    search_result.deinit(ctx.allocator);
    const output = try successOutput(ctx.allocator, inner_empty);
    return ToolExecResult{ .output = output, .output_allocated = true };
}

const inner = try search_tool_mod.search_result_to_string_grouped(
    ctx.allocator,
    search_result,
    parsed.value.pattern,
    parsed.value.path,
);
const output = try successOutput(ctx.allocator, inner);
return ToolExecResult{ .output = output, .output_allocated = true };
```

- [ ] **Step 2.26: Build and run tests**

Run: `cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox && timeout 240 zig build 2>&1 | tail -n 30`
Expected: clean build (the `successOutput`/`errorOutput` helpers exist; each `execX` uses them).

Run: `cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox && timeout 180 zig build test 2>&1 | tail -n 30`
Expected: tests pass. Note: at this point the tool modules still emit their old shapes (with `<success>`, `<loaded>`, etc.), so the LLM will see DUPLICATE success indicators in some outputs (e.g. text_replace output will be `<success>true</success><result>...</result><success>true</success>...`). This is intentional — the tool modules are cleaned up in Chunk 3. Tests don't assert on the exact output shape, so they pass.

- [ ] **Step 2.27: Commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
git add src/ai_workflow/tui/tool_registry.zig
git commit -m "refactor(tool-registry): wrap every execX output with successOutput/errorOutput"
```

---

# Chunk 3: Update tool modules to strip their own success/error tags

**Goal:** Each tool module's `toXmlSuccess`/`toXmlError` (or equivalent) emits only its tool-specific inner data — no `<success>`, no `<error>`, no `<loaded>` flag. This is the cleanup so the LLM doesn't see duplicate indicators.

### Task 3: Update each tool module

For each tool module listed below, find the function that produces the success/error XML and remove the redundant success/error tags. **The shape of the tool-specific inner data stays the same** — only the wrapper tags change.

- [ ] **Step 3.1: `read_file.zig` — `toXMLSuccess`**

Current emits `<path>...</path>...<content>...</content>`. No change needed (it doesn't have a success tag).

- [ ] **Step 3.2: `text_replace.zig` — `toXmlSuccess` and `toXmlError`**

Current `toXmlSuccess` ends with a `<success>true</success>` line. Remove that line.
Current `toXmlError` returns `<success>false</success><error>...</error>`. Replace with just the error body (the helper will add `<error>...</error>`).

- [ ] **Step 3.3: `write_file.zig` — `toXmlSuccess` and `toXmlError`**

Same as `text_replace.zig`.

- [ ] **Step 3.4: `get_skill.zig` — `execute_get_skill_to_string`**

Current returns `<skill_name>...</skill_name><content>...</content><loaded>true</loaded>` on success, or `<skill_name></skill_name><content></content><loaded>false</loaded><error>...</error>` on failure. After:
- Success: `<skill_name>...</skill_name><content>...</content>` (no `<loaded>`).
- Failure: `<skill_name></skill_name><content></content><error>...</error>` (no `<loaded>`, but still has the inner `<error>` for backward compat — the outer wrapper will also have `<error>`, which is fine).

- [ ] **Step 3.5: `list_memory.zig` — `execute_list_memory`**

Current emits `<memories>...</memories>` on success or `<memories><error>...</error></memories>` on failure. After:
- Success: `<memories>...</memories>` (unchanged).
- Failure: returns `""` (empty) — the exec function in Chunk 2 detects empty inner and produces `<error>unknown error</error>`.

- [ ] **Step 3.6: `list_skills.zig` — `execute_list_skills`**

Current returns a JSON object. Convert to XML:
- Success: `<skills>...</skills>` (each skill as a `<skill>...</skill>` child).
- Failure: returns `""` (empty).

- [ ] **Step 3.7: `bash.zig` — `bash_result_to_string`**

Current returns plain text like `PID: {pid}\nLog: {path}\n{stdout}`. Convert to:
- Success (foreground): `<stdout>{stdout}</stdout><stderr>{stderr}</stderr><exit_code>0</exit_code>`
- Success (background): `<stdout>{stdout}</stdout><stderr>{stderr}</stderr><exit_code>0</exit_code><background>true</background>`
- Failure: same as success but with non-zero `<exit_code>...</exit_code>`.

The plain text format is currently used for parsing `PID:` and `Log:` paths in `runWithContext` (lines 132-166). Update that parsing logic to read from the new XML format (parse `<stdout>...</stdout>` to extract the `PID: ...` and `Log: ...` lines for the background case).

- [ ] **Step 3.8: `cloak_browser.zig` — `toXMLSuccess` and `toXMLError`**

Current emit their own `<success>...</success>` or `<error>...</error>` tags. Strip those — the helper adds them. The inner content stays the same.

- [ ] **Step 3.9: `lsp_definition.zig` — `lsp_definition_to_string`**

If it emits `<success>true</success>`, strip it.

- [ ] **Step 3.10: `update_activity.zig` — `xmlSuccess` and `xmlError`**

Current emit their own success/error tags. Strip them.

- [ ] **Step 3.11: `add_skill.zig`, `edit_skill.zig`, `remove_skill.zig`, `view_skill.zig`, `add_agent.zig`, `remove_agent.zig`, `list_agents.zig`, `change_agent.zig`, `remove_file.zig`, `glob.zig`, `search.zig`, `web_search.zig`**

For each, find the function that produces the tool's output XML and strip any `<success>`, `<error>`, `<loaded>`, or `<removed>` tags it emits. The tool-specific inner data stays the same.

- [ ] **Step 3.12: Build and run tests**

Run: `cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox && timeout 240 zig build 2>&1 | tail -n 30`
Expected: clean build.

Run: `cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox && timeout 180 zig build test 2>&1 | tail -n 30`
Expected: tests pass.

- [ ] **Step 3.13: Commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
git add src/ai_workflow/tui/read_file.zig \
        src/ai_workflow/tui/text_replace.zig \
        src/ai_workflow/tui/write_file.zig \
        src/ai_workflow/tui/get_skill.zig \
        src/ai_workflow/tui/list_memory.zig \
        src/ai_workflow/tui/list_skills.zig \
        src/ai_workflow/tui/bash.zig \
        src/ai_workflow/tui/cloak_browser.zig \
        src/ai_workflow/tui/lsp_definition.zig \
        src/ai_workflow/tui/update_activity.zig
git commit -m "refactor(tools): strip redundant success/error tags from tool module outputs"
```

---

# Chunk 4: Update `handle_tool.zig` error paths

**Goal:** The dispatch-level error paths in `handle_tool.zig` (catches at lines 406-413 and 419-427) produce raw `<error>...</error>` strings — convert them to the new standardized shape.

### Task 4: Update `handle_tool.zig`

**Files:**
- Modify: `src/ai_workflow/tui/handle_tool.zig`

- [ ] **Step 4.1: Update the MCP error path (lines 406-413)**

Current:
```zig
} catch |err| {
    tool_result = try std.fmt.allocPrint(allocator, "<error> MCP tool {s} failed: {s}</error>", .{...});
    try saveAndSendToolResult(...);
    continue;
};
```

Change to:
```zig
} catch |err| {
    const err_msg = try std.fmt.allocPrint(allocator, "MCP tool {s} failed: {s}", .{...});
    tool_result = try tool_registry.errorOutput(allocator, err_msg, "");
    try saveAndSendToolResult(...);
    continue;
};
```

- [ ] **Step 4.2: Update the `dispatchTool` error path (lines 419-427)**

Current:
```zig
const exec_result = dispatchTool(ctx, tool_call) catch |err| {
    std.debug.print("DEBUG: dispatchTool failed with error: {s}\n", .{@errorName(err)});
    tool_result = try std.fmt.allocPrint(allocator, "<error> {s} failed: {s}</error>", .{...});
    try saveAndSendToolResult(...);
    continue;
};
```

Change to:
```zig
const exec_result = dispatchTool(ctx, tool_call) catch |err| {
    std.debug.print("DEBUG: dispatchTool failed with error: {s}\n", .{@errorName(err)});
    const err_msg = try std.fmt.allocPrint(allocator, "{s} failed: {s}", .{...});
    tool_result = try tool_registry.errorOutput(allocator, err_msg, "");
    try saveAndSendToolResult(...);
    continue;
};
```

- [ ] **Step 4.3: Verify `parseDiffViewFromResult` still works**

After the refactor, `text_replace` output looks like:
```xml
<success>true</success><result>...</result><diff_view><before>...</before><after>...</after></diff_view>
```

The substring search for `<diff_view>` in `parseDiffViewFromResult` still finds it. **No change needed** to that function.

- [ ] **Step 4.4: Build and run tests**

Run: `cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox && timeout 240 zig build 2>&1 | tail -n 30`
Expected: clean build.

Run: `cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox && timeout 180 zig build test 2>&1 | tail -n 30`
Expected: tests pass.

- [ ] **Step 4.5: Commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
git add src/ai_workflow/tui/handle_tool.zig
git commit -m "refactor(handle-tool): use tool_registry.errorOutput for dispatch error paths"
```

---

# Chunk 5: Update frontend to parse the new shape

**Goal:** The 13 `tool_outputs/*.vue` components and `ChatView.vue`'s `renderResponse` are updated to expect the new shape: `<success>true</success>` at the start of every successful tool output and `<error>...</error>` on failure.

### Task 5: Update Vue components

**Files:**
- Modify: `src/apps/desktop/src/components/ChatView.vue`
- Modify: `src/apps/desktop/src/components/Bash.vue`
- Modify: `src/apps/desktop/src/components/tool_outputs/*.vue` (12 files)

- [ ] **Step 5.1: Update `Bash.vue` — parse the new structured format**

Read the current `Bash.vue` and `src/ai_workflow/tui/bash.zig`'s new `bash_result_to_string` to understand the field names. Update `Bash.vue` to:
- Parse `<success>...</success>` for the success indicator.
- Parse `<stdout>...</stdout>` and `<stderr>...</stderr>` instead of raw text.
- Parse `<exit_code>...</exit_code>` for the exit code.
- Parse `<background>true</background>` to show a "background process started" indicator.

- [ ] **Step 5.2: Update `tool_outputs/ListSkills.vue` — parse XML instead of JSON**

Read the current `ListSkills.vue` (parses JSON) and the new `list_skills_mod.execute_list_skills` (emits XML). Update `ListSkills.vue` to:
- Parse `<success>...</success>` for the success indicator.
- Parse `<skills>...</skills>` and iterate over `<skill>...</skill>` children.
- On failure, parse the outer `<error>...</error>` from the wrapper.

- [ ] **Step 5.3: Update `tool_outputs/ReadFile.vue` — read `<success>` from the new location**

Current parses `<success>...</success>`. The new format has `<success>true</success>` at the very start of the content. **No change needed** to the regex (it just looks for the tag). The `<path>` and `<content>` parsing stays the same.

- [ ] **Step 5.4: Update `tool_outputs/TextReplace.vue` — same as ReadFile**

No change to the regexes (they look for the tags anywhere in the content).

- [ ] **Step 5.5: Update `tool_outputs/WriteFile.vue` — same as ReadFile**

No change to the regexes.

- [ ] **Step 5.6: Update `tool_outputs/GetSkill.vue` — replace `<loaded>` with `<success>`**

Current parses `<loaded>...</loaded>`. Change to parse `<success>...</success>`.

- [ ] **Step 5.7: Update `tool_outputs/ViewSkill.vue`, `AddSkill.vue`, `EditSkill.vue`, `RemoveSkill.vue`, `RemoveFile.vue` — same as GetSkill**

Replace any `<loaded>`, `<removed>`, or `<found>` parsing with `<success>...</success>`.

- [ ] **Step 5.8: Update `tool_outputs/SpawnSubAgent.vue` — minor**

The `<agent name="..." success="...">` inner parsing stays (it's an inner agent-result tag, not the outer wrapper). The outer `<success>...</success>` indicates the overall tool execution. If all agents succeeded, the outer is success; if any failed, the outer is still success (the tool itself ran, just had failures inside). The frontend's existing display logic stays.

- [ ] **Step 5.9: Update `ChatView.vue`'s `renderResponse` — parse the new shape**

Current (lines 132-204) has tool-specific branches for `read_file`, `search`, `glob`, `web_search`, `mcp_*`, `list_skills`/`get_skill`/`add_skill`/`edit_skill`/`view_skill`, `spawn_sub_agent`. Update each to:
- Check for `<error>...</error>` first (if present, show the error message and return).
- Then check for `<success>true</success>` (if present, parse the tool-specific inner tags as before).
- For tools without a dedicated branch (the `else` at line 204), extract the inner content from after `<success>true</success>` and display it.

- [ ] **Step 5.10: Build and run frontend tests**

Run: `cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/src/apps/desktop && timeout 120 bun run build 2>&1 | tail -n 30`
Expected: clean. No `vue-tsc` errors.

Run: `cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/src/apps/desktop && timeout 60 bunx vitest run 2>&1 | tail -n 20`
Expected: 31 existing tests pass.

- [ ] **Step 5.11: Manual smoke test on port 8080**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
./zig-out/bin/nalar --port 8080
```

In the desktop app (port 8080):
1. Ask the agent to `read_file /etc/hostname`. Verify the `ReadFile.vue` bubble shows the file path and content.
2. Ask the agent to `bash echo hello`. Verify the `Bash.vue` bubble shows the stdout.
3. Ask the agent to `read_file /nonexistent`. Verify the error is shown.
4. Ask the agent to `list_skills`. Verify the `ListSkills.vue` bubble shows the skill list.

- [ ] **Step 5.12: Commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
git add src/apps/desktop/src/components/ChatView.vue \
        src/apps/desktop/src/components/Bash.vue \
        src/apps/desktop/src/components/tool_outputs/
git commit -m "refactor(desktop): update tool output components to parse <success>/<error> shape"
```

---

# Verification (final)

1. **Backend tests** — `timeout 180 zig build test 2>&1 | tail -n 30` → 304+ tests pass.
2. **Backend build** — `timeout 240 zig build 2>&1 | tail -n 20` → clean.
3. **Frontend type-check** — `timeout 120 bun run build 2>&1 | tail -n 20` → clean.
4. **Frontend tests** — `timeout 60 bunx vitest run 2>&1 | tail -n 20` → 31 tests pass.
5. **End-to-end smoke** (manual step 5.11) — every tool type renders correctly with the new shape.

---

# Pitfalls (cumulative)

1. **The `output_allocated` flag is set inconsistently in the existing code.** After the refactor, set it to `true` consistently (the wrap helpers always allocate). Existing leaks of inner allocations (e.g. `runWithContext` returns an allocated string) are preserved for now — fixing them is a separate task.

2. **The `set_agent_properties` tool's current output has a typo**: it emits `<set_agent_properties>\n...\n<set_agent_properties>` (missing `/` in the closing tag). The refactor fixes this by using `successOutput`.

3. **`execGetSkill` auto-save detection.** The exec function looks for `<success>true</success>` in the output to decide whether to trigger `SkillSaveInfo`. After the refactor, that detection works (the helper always emits the success tag at position 0).

4. **`execSpawnSubAgent` is the most complex refactor** because it builds its own XML block and threads it through a custom `std.Io.Writer`. The wrap with `successOutput` happens at the very end, after the existing block is built.

5. **Tool module updates must happen in lockstep with the exec function refactor.** If a tool module still emits its own `<success>true</success>` after the exec function wraps with `successOutput`, the LLM sees DUPLICATE success indicators. This is fine for Chunk 2 (tests pass), but the cleanup in Chunk 3 is required before declaring done.

6. **`parseDiffViewFromResult` in `handle_tool.zig` is substring-based** — it works regardless of the surrounding wrapper, so no change is needed.

7. **Memory: `runWithContext` returns a `[]const u8` that is leaked today** (the existing code doesn't set `output_allocated`). The refactor preserves this leak. Fixing it is out of scope.

8. **`Bash.vue` change is the largest frontend impact.** It currently parses plain text; the new format is structured XML. Read both `bash.zig`'s new `bash_result_to_string` and the current `Bash.vue` carefully before editing.

9. **The `<success>true</success>` regex in the existing tool components will match the new format** because they look for the tag anywhere in the content. Only components that used `<loaded>`, `<removed>`, or `<found>` need updating (those tags are gone).
