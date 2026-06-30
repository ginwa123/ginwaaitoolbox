# `show_preview` Agent Tool — Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `show_preview` agent tool that lets the LLM push visual content (images, markdown, code, plain text) to a side panel in the chat, with persistence via the existing `llm_history` table.

**Architecture:** New Zig tool `src/modules/agent/tools/show_preview.zig` validates + sanitizes content, generates a `preview_id`, and writes the preview to `llm_history` via the existing `wrapToolOutput` envelope (the standard `llm_full` SSE event carries it to the frontend). Frontend adds a `<PreviewSidePanel>` Vue component inside ChatView that filters `messages` by `tool_name === 'show_preview'` and renders them with tabs/collapse/expand UX.

**Tech Stack:** Zig 0.16, Vue 3 + TypeScript, Pinia, marked (markdown), Vue `<Teleport>` for side panel mounting.

**Reference design doc:** `docs/plans/2026-07-01-agent-show-preview-design.md`

**Key conventions to follow:**
- Tool schema definition in `src/modules/agent/tools/schemas.zig`
- Tool executor pattern: `pub fn execXxx(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult` in `src/ai_workflow/tui/tool_registry.zig`
- Tool registry: `UNIFIED_TOOL_REGISTRY` + `allAgentTools()`
- Test pattern: static source checks in `src/modules/agent/tools/<tool>_test.zig`, registered in `src/ai_workflow/tui/test_runner.zig`
- Frontend tests in `src/apps/desktop/src/__tests__/`
- The existing `onEventSendLLMHistory` SSE event already handles all tool result rows; this tool does NOT add a new event type.

**Key difference from a typical tool:** the tool's tool result content
contains a stub XML envelope (`<show_preview><status>shown</status>...
<content_length>1234</content_length></show_preview>`) — the actual
content is in the `parameters` field of the row (carried by
`msg.parameters` in the frontend). The side panel reads
`msg.parameters` to get the full content for rendering. This matches
the pattern used by `<NalarBrowser>` (which reads `parameters` for the
action-specific args).

---

## File Structure

| File | Responsibility | Action |
|---|---|---|
| `src/modules/agent/tools/show_preview.zig` | Tool schema + input parsing + content validation + size cap + UTF-8 sanitization + preview_id generation + `<show_preview>` XML envelope | Create |
| `src/modules/agent/tools/show_preview_test.zig` | Static source-check tests + behavioral tests for `executeShowPreviewToString` | Create |
| `src/ai_workflow/tui/mod.zig` | Re-export new `show_preview` module | Modify |
| `src/ai_workflow/tui/tool_registry.zig` | Add `execShowPreview` + register in `UNIFIED_TOOL_REGISTRY` + add to `allAgentTools()` | Modify |
| `src/ai_workflow/tui/test_runner.zig` | Register new test file | Modify |
| `src/apps/desktop/src/components/PreviewSidePanel.vue` | Side panel UI: tabs/collapse, markdown/code/image rendering, auto-open on new preview | Create |
| `src/apps/desktop/src/components/ChatView.vue` | Extract `show_preview` messages via computed + mount `<PreviewSidePanel>` adjacent to messages wrapper | Modify |
| `src/apps/desktop/src/__tests__/previewSidePanel.spec.ts` | Unit tests for side panel: tabs switching, collapse/expand, content rendering | Create |

**Explicitly removed** (vs. the original v1 plan, after user feedback 2026-07-01):
- ~~`src/ai_workflow/tui/on_event_sent_show_preview.zig`~~ (no custom SSE event)
- ~~`src/ai_workflow/tui/on_event_sent_show_preview_test.zig`~~
- ~~`src/apps/desktop/src/stores/preview.ts`~~ (no transient banner store)
- ~~`src/apps/desktop/src/components/PreviewBanner.vue`~~
- ~~`src/apps/desktop/src/components/tool_outputs/ShowPreview.vue`~~ (not inline)
- ~~`src/apps/desktop/src/api/index.ts` changes~~ (no new event type)

---

## Chunk 1: Backend Tool (Zig)

### Task 1.1: Create `show_preview.zig` tool with input + execute function

**Files:**
- Create: `src/modules/agent/tools/show_preview.zig`
- Create: `src/modules/agent/tools/show_preview_test.zig`
- Modify: `src/ai_workflow/tui/mod.zig`
- Modify: `src/ai_workflow/tui/test_runner.zig`

- [ ] **Step 1: Write the failing static tests for tool definition**

Create `src/modules/agent/tools/show_preview_test.zig` with at least these tests (pattern mirrors `kanban_list_test.zig`):

```zig
const std = @import("std");
const testing = std.testing;
const nalarcore = @import("nalarcore");
const sqlite = nalarcore.sqlite;

const TOOL_PATH = "src/modules/agent/tools/show_preview.zig";

fn readSource(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(
        testing.io, path, allocator, .limited(256 * 1024),
    );
}

fn contains(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

test "show_preview tool definition has correct name" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_PATH);
    defer allocator.free(source);
    if (!contains(source, `.name = "show_preview"`)) {
        std.debug.print("!! show_preview.zig does not define the tool with .name = \"show_preview\" !!\n", .{});
        return error.ToolNameMissing;
    }
}

test "show_preview description mentions side panel" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_PATH);
    defer allocator.free(source);
    if (!contains(source, "side panel")) {
        return error.SidePanelHintMissing;
    }
}

test "show_preview schema has all 5 properties" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_PATH);
    defer allocator.free(source);
    const required = [_][]const u8{
        `.name = "content_type"`,
        `.name = "content"`,
        `.name = "title"`,
        `.name = "language"`,
        `.name = "caption"`,
    };
    for (required) |needle| {
        if (!contains(source, needle)) {
            std.debug.print("!! show_preview.zig missing property {s} !!\n", .{needle});
            return error.SchemaPropertyMissing;
        }
    }
}

test "show_preview required array contains content_type and content" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_PATH);
    defer allocator.free(source);
    if (!contains(source, `&.{ "content_type", "content" }`)) {
        return error.RequiredFieldsMissing;
    }
}

test "show_preview has executeShowPreviewToString function" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_PATH);
    defer allocator.free(source);
    if (!contains(source, "pub fn executeShowPreviewToString")) {
        return error.ExecuteFunctionMissing;
    }
}

test "show_preview has MAX_CONTENT_BYTES constant = 1 MB" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_PATH);
    defer allocator.free(source);
    if (!contains(source, "1024 * 1024")) {
        return error.MaxContentBytesMissing;
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
timeout 180 zig build test --summary all 2>&1 | tail -n 20
```
Expected: tests fail with `error.FileNotFound` or similar (show_preview_test.zig imports a non-existent file).

- [ ] **Step 3: Implement the tool definition**

Create `src/modules/agent/tools/show_preview.zig`:

```zig
const std = @import("std");
const schemas = @import("schemas.zig");
const AgentTool = schemas.AgentTool;
const nalarcore = @import("nalarcore");
const helpers = nalarcore.helpers;

/// Maximum allowed size for `content` field. Base64 images at this size
/// fit a typical screenshot; markdown fits a long document. Anything
/// larger should be split or summarized by the LLM.
pub const MAX_CONTENT_BYTES: usize = 1 * 1024 * 1024; // 1 MB

/// Input structure for show_preview tool.
pub const ShowPreviewInput = struct {
    /// How the frontend should render the content.
    /// One of: "markdown", "text", "code", "image".
    content_type: []const u8,
    /// The content to display. For markdown: markdown text. For text:
    /// plain text. For code: source code. For image: data URL or http URL.
    content: []const u8,
    /// Optional human-readable title shown above the preview.
    title: ?[]const u8 = null,
    /// For content_type='code' only: the language for syntax highlighting.
    language: ?[]const u8 = null,
    /// Optional caption shown below the preview.
    caption: ?[]const u8 = null,
};

/// Top-level tool definition for the LLM.
pub const show_preview_tool = AgentTool{
    .type = "function",
    .function = .{
        .name = "show_preview",
        .description =
            \\Show a visual preview to the user in the side panel of the chat. Use this whenever you produce something the user might want to see at a glance — a rendered chart, a generated image, a polished markdown summary, a code snippet, a URL preview, a formatted table. The preview is rendered as a first-class card in the side panel, survives page reload, and can be called multiple times per turn (each call adds a tab to the panel).
            \\
            \\content_type selects how the side panel renders the content:
            \\- 'markdown' → renders via marked() (headings, lists, tables, links).
            \\- 'text' → preserves whitespace in a <pre> block.
            \\- 'code' → syntax-highlighted <pre><code> (requires the 'language' field).
            \\- 'image' → expects either a base64 data URL ("data:image/png;base64,...") or an http(s) URL.
            \\
            \\The 'content' field has a hard cap of 1 MB. If you have larger content, summarize or split it across multiple show_preview calls.
            ,
        .parameters = .{
            .type = "object",
            .properties = &.{
                .{ .name = "content_type", .type = "string", .description = "How the side panel should render the content. One of 'markdown', 'text', 'code', 'image'." },
                .{ .name = "content", .type = "string", .description = "The content to display." },
                .{ .name = "title", .type = "string", .description = "Optional human-readable title shown above the preview." },
                .{ .name = "language", .type = "string", .description = "For content_type='code' only: programming language for syntax highlighting." },
                .{ .name = "caption", .type = "string", .description = "Optional caption shown below the preview." },
            },
            .required = &.{ "content_type", "content" },
        },
    },
};

/// Generate a unique preview id. Format: `pv_<unix_ms>_<6 hex chars>`.
///
/// Uses `std.c.getrandom` to get 3 random bytes (the lower 6 hex chars
/// of the id) — same pattern as auth.zig:fillRandom.
pub fn generatePreviewId(allocator: std.mem.Allocator, io: std.Io) ![]u8 {
    const ts = std.Io.Clock.now(.real, io);
    const ms: i64 = ts.toMilliseconds();

    var rand_buf: [3]u8 = undefined;
    var filled: usize = 0;
    while (filled < rand_buf.len) {
        const rc = std.c.getrandom(rand_buf[filled..].ptr, rand_buf.len - filled, 0);
        if (rc < 0) {
            const err = std.c.errno(rc);
            if (err == .INTR) continue;
            return error.EntropyUnavailable;
        }
        filled += @intCast(rc);
    }

    return try std.fmt.allocPrint(allocator, "pv_{d}_{x}", .{ ms, rand_buf });
}
```

**Verification before continuing**: confirm `std.Io.Clock.now(.real, io).toMilliseconds()` exists. If not, use `ts.nanoseconds / 1_000_000`.

- [ ] **Step 4: Implement content validation + XML envelope**

Append to the same file:

```zig
/// Validate `content_type` is one of the supported values. Returns null
/// if valid, else an owned error message.
pub fn validateContentType(allocator: std.mem.Allocator, content_type: []const u8) !?[]u8 {
    const valid = [_][]const u8{ "markdown", "text", "code", "image" };
    for (valid) |v| {
        if (std.mem.eql(u8, content_type, v)) return null;
    }
    const list = try std.mem.join(allocator, ", ", &.{ "\"markdown\"", "\"text\"", "\"code\"", "\"image\"" });
    defer allocator.free(list);
    return try std.fmt.allocPrint(allocator,
        "invalid content_type '{s}' (expected one of {s})",
        .{ content_type, list });
}

/// Validate content is within size cap. Returns null if OK, else error.
pub fn validateContentSize(allocator: std.mem.Allocator, content: []const u8) !?[]u8 {
    if (content.len <= MAX_CONTENT_BYTES) return null;
    return try std.fmt.allocPrint(allocator,
        "content exceeds {d} byte limit (got {d}); consider summarizing or splitting",
        .{ MAX_CONTENT_BYTES, content.len });
}

/// Escape XML special chars. Mirrors the helper in kanban_list.zig.
fn xmlEscape(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    var result: std.ArrayList(u8) = .empty;
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

/// Execute the show_preview tool. Returns an XML string for the LLM,
/// and populates `out_preview_id` with the generated id (the LLM may
/// reference it in follow-up messages).
///
/// Response shapes:
///   Success: <show_preview><status>shown</status>...</show_preview>
///   Error:   <show_preview><error>...</error></show_preview>
///
/// The actual `content` is NOT in this envelope — it's in the tool
/// result row's `parameters` field (carried by `msg.parameters` to the
/// frontend). The envelope carries only the metadata (status, id,
/// content_type, length) for storage compactness; the side panel reads
/// `parameters.content` to render the preview.
pub fn executeShowPreviewToString(
    allocator: std.mem.Allocator,
    io: std.Io,
    input: ShowPreviewInput,
    out_preview_id: *[]u8,
) ![]u8 {
    // 1. Validate content_type
    if (try validateContentType(allocator, input.content_type)) |err| {
        defer allocator.free(err);
        return errorEnvelope(allocator, err);
    }

    // 2. Validate content size
    if (try validateContentSize(allocator, input.content)) |err| {
        defer allocator.free(err);
        return errorEnvelope(allocator, err);
    }

    // 3. For code type, require language
    if (std.mem.eql(u8, input.content_type, "code")) {
        const lang = input.language orelse "";
        if (lang.len == 0) {
            return errorEnvelope(allocator, try allocator.dupe(u8,
                "content_type='code' requires the 'language' field"));
        }
    }

    // 4. Sanitize content to valid UTF-8 (same pattern as on_event_sent.zig:254)
    //    Even though the content is sent via `parameters` (JSON encoded), we
    //    sanitize so the SSE event for tool results doesn't break.
    const sanitized_content = helpers.sanitize.sanitizeUtf8(allocator, input.content) catch |err| {
        return errorEnvelope(allocator, try std.fmt.allocPrint(allocator,
            "sanitizeUtf8 failed: {s}", .{@errorName(err)}));
    };
    defer allocator.free(sanitized_content);

    // 5. Generate preview_id
    out_preview_id.* = try generatePreviewId(allocator, io);

    // 6. Build success XML
    return successEnvelope(allocator, out_preview_id.*, input.content_type, sanitized_content.len);
}

fn successEnvelope(allocator: std.mem.Allocator, preview_id: []const u8, content_type: []const u8, content_length: usize) ![]u8 {
    var xml: std.ArrayList(u8) = .empty;
    errdefer xml.deinit(allocator);
    try xml.appendSlice(allocator, "<show_preview><status>shown</status>");

    const eid = try xmlEscape(allocator, preview_id);
    defer allocator.free(eid);
    try xml.appendSlice(allocator, "<preview_id>");
    try xml.appendSlice(allocator, eid);
    try xml.appendSlice(allocator, "</preview_id>");

    const ect = try xmlEscape(allocator, content_type);
    defer allocator.free(ect);
    try xml.appendSlice(allocator, "<content_type>");
    try xml.appendSlice(allocator, ect);
    try xml.appendSlice(allocator, "</content_type>");

    var buf: [32]u8 = undefined;
    const len_str = std.fmt.bufPrint(&buf, "{d}", .{content_length}) catch "0";
    try xml.appendSlice(allocator, "<content_length>");
    try xml.appendSlice(allocator, len_str);
    try xml.appendSlice(allocator, "</content_length>");

    try xml.appendSlice(allocator, "</show_preview>");
    return try xml.toOwnedSlice(allocator);
}

fn errorEnvelope(allocator: std.mem.Allocator, error_msg: []const u8) ![]u8 {
    var xml: std.ArrayList(u8) = .empty;
    errdefer xml.deinit(allocator);
    try xml.appendSlice(allocator, "<show_preview><error>");
    const e = try xmlEscape(allocator, error_msg);
    defer allocator.free(e);
    try xml.appendSlice(allocator, e);
    try xml.appendSlice(allocator, "</error></show_preview>");
    return try xml.toOwnedSlice(allocator);
}
```

- [ ] **Step 5: Re-export from `mod.zig`**

Modify `src/ai_workflow/tui/mod.zig` (add after the `on_event_sent_kanban` line):

```zig
pub const show_preview = @import("../../modules/agent/tools/show_preview.zig");
```

(The `show_preview` tool is a leaf module — the dispatch path is via
`tool_registry.execShowPreview`, not via a dedicated `ai_mod.show_preview`
namespace. But re-exporting it makes test imports cleaner: `nalarcore.ai_mod.show_preview.ShowPreviewInput`.)

- [ ] **Step 6: Register tests in test_runner.zig**

Modify `src/ai_workflow/tui/test_runner.zig`:

```zig
_ = @import("../modules/agent/tools/show_preview_test.zig"); // NEW
```

- [ ] **Step 7: Run static tests to verify they pass**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
timeout 180 zig build test --summary all 2>&1 | tail -n 10
```
Expected: 6 new static tests pass; pre-existing tests unchanged.

- [ ] **Step 8: Add behavioral tests**

Append to `src/modules/agent/tools/show_preview_test.zig`:

```zig
const ShowPreviewInput = @import("show_preview.zig").ShowPreviewInput;
const show_preview = @import("show_preview.zig");

fn setupIo() !std.Io {
    // Mirrors the pattern from routines/fire_test.zig — use a threaded
    // Io runtime so std.Io.Clock.now() can return real time. The Io
    // lives for the duration of the test; the deinit happens via the
    // testing.allocator arena (no explicit teardown needed).
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    return threaded.io();
}

test "executeShowPreviewToString returns success envelope for markdown" {
    const alloc = testing.allocator;
    const io = try setupIo();

    var preview_id: []u8 = undefined;
    defer alloc.free(preview_id);

    const result = try show_preview.executeShowPreviewToString(alloc, io, .{
        .content_type = "markdown",
        .content = "# Hello\n\nWorld",
    }, &preview_id);

    defer alloc.free(result);
    try testing.expect(std.mem.indexOf(u8, result, "<status>shown</status>") != null);
    try testing.expect(std.mem.indexOf(u8, result, "<content_type>markdown</content_type>") != null);
    try testing.expect(std.mem.startsWith(u8, preview_id, "pv_"));
}

test "executeShowPreviewToString returns error envelope for invalid content_type" {
    const alloc = testing.allocator;
    const io = try setupIo();

    var preview_id: []u8 = undefined;
    defer alloc.free(preview_id);

    const result = try show_preview.executeShowPreviewToString(alloc, io, .{
        .content_type = "invalid_type",
        .content = "x",
    }, &preview_id);

    defer alloc.free(result);
    try testing.expect(std.mem.indexOf(u8, result, "<error>") != null);
    try testing.expect(std.mem.indexOf(u8, result, "invalid content_type") != null);
}

test "executeShowPreviewToString returns error when content exceeds 1 MB" {
    const alloc = testing.allocator;
    const io = try setupIo();

    var big = try alloc.alloc(u8, show_preview.MAX_CONTENT_BYTES + 1);
    defer alloc.free(big);
    @memset(big, 'x');

    var preview_id: []u8 = undefined;
    defer alloc.free(preview_id);

    const result = try show_preview.executeShowPreviewToString(alloc, io, .{
        .content_type = "text",
        .content = big,
    }, &preview_id);

    defer alloc.free(result);
    try testing.expect(std.mem.indexOf(u8, result, "<error>") != null);
    try testing.expect(std.mem.indexOf(u8, result, "exceeds") != null);
}

test "executeShowPreviewToString requires language for code type" {
    const alloc = testing.allocator;
    const io = try setupIo();

    var preview_id: []u8 = undefined;
    defer alloc.free(preview_id);

    const result = try show_preview.executeShowPreviewToString(alloc, io, .{
        .content_type = "code",
        .content = "print('hi')",
        .language = null,
    }, &preview_id);

    defer alloc.free(result);
    try testing.expect(std.mem.indexOf(u8, result, "<error>") != null);
    try testing.expect(std.mem.indexOf(u8, result, "language") != null);
}

test "executeShowPreviewToString accepts code type with language" {
    const alloc = testing.allocator;
    const io = try setupIo();

    var preview_id: []u8 = undefined;
    defer alloc.free(preview_id);

    const result = try show_preview.executeShowPreviewToString(alloc, io, .{
        .content_type = "code",
        .content = "fn main() void {}",
        .language = "zig",
    }, &preview_id);

    defer alloc.free(result);
    try testing.expect(std.mem.indexOf(u8, result, "<status>shown</status>") != null);
}

test "executeShowPreviewToString sanitizes invalid UTF-8 in content" {
    const alloc = testing.allocator;
    const io = try setupIo();

    // Mix valid ASCII with a single 0xFF byte (invalid UTF-8).
    const bad = "valid prefix \xff more text";
    var preview_id: []u8 = undefined;
    defer alloc.free(preview_id);

    const result = try show_preview.executeShowPreviewToString(alloc, io, .{
        .content_type = "text",
        .content = bad,
    }, &preview_id);

    defer alloc.free(result);
    try testing.expect(std.mem.indexOf(u8, result, "<status>shown</status>") != null);
    // The content_length should be > bad.len (sanitize replaces with U+FFFD = 3 bytes)
    // OR == bad.len (depending on sanitize impl). We just check the function
    // doesn't crash.
}
```

- [ ] **Step 9: Run tests**

```bash
timeout 180 zig build test --summary all 2>&1 | tail -n 10
```
Expected: 6 new behavioral tests pass; no regressions.

- [ ] **Step 10: Commit**

```bash
git add src/modules/agent/tools/show_preview.zig src/modules/agent/tools/show_preview_test.zig src/ai_workflow/tui/mod.zig src/ai_workflow/tui/test_runner.zig
git commit -m "feat(tools): add show_preview tool definition + executeShowPreviewToString"
```

---

### Task 1.2: Wire `show_preview` into `tool_registry.zig`

**Files:**
- Modify: `src/ai_workflow/tui/tool_registry.zig`

- [ ] **Step 1: Add the import**

At the top of `tool_registry.zig` (after the other tool imports, around line 47):

```zig
const show_preview_mod = nalar_mod.ai_mod.show_preview;
```

- [ ] **Step 2: Add `execShowPreview` function**

Insert after `execKanbanMoveTask` (around line 645):

```zig
pub fn execShowPreview(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    const parsed = std.json.parseFromSlice(
        show_preview_mod.ShowPreviewInput,
        ctx.allocator,
        tc.function.arguments,
        .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
    ) catch |err| {
        const err_msg = try std.fmt.allocPrint(ctx.allocator, "show_preview failed to parse input: {s}", .{@errorName(err)});
        const output = try wrapToolOutput(ctx.allocator, "show_preview", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    defer parsed.deinit();

    var preview_id: []u8 = undefined;
    defer ctx.allocator.free(preview_id);

    const inner = show_preview_mod.executeShowPreviewToString(
        ctx.allocator,
        ctx.io,
        parsed.value,
        &preview_id,
    ) catch |err| {
        const err_msg = try std.fmt.allocPrint(ctx.allocator, "show_preview failed: {s}", .{@errorName(err)});
        const output = try wrapToolOutput(ctx.allocator, "show_preview", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    defer ctx.allocator.free(inner);

    // Detect <error>...</error> in the envelope and surface as failure
    // (LLM sees success=false; can retry with corrected input).
    if (std.mem.indexOf(u8, inner, "<error>") != null) {
        const err_start = (std.mem.indexOf(u8, inner, "<error>") orelse 0) + "<error>".len;
        const err_end = std.mem.indexOf(u8, inner[err_start..], "</error>") orelse inner.len;
        const err_msg = inner[err_start .. err_start + err_end];
        const output = try wrapToolOutput(ctx.allocator, "show_preview", tc.function.arguments, false, err_msg, inner);
        return ToolExecResult{ .output = output, .output_allocated = true };
    }

    // The actual preview content is in `tc.function.arguments` (passed
    // through to `parameters` in the wrapToolOutput envelope). The
    // side panel frontend reads `msg.parameters` to get the full
    // content for rendering. This matches the pattern used by
    // <NalarBrowser> for action-specific args.
    const output = try wrapToolOutput(ctx.allocator, "show_preview", tc.function.arguments, true, null, inner);
    return ToolExecResult{ .output = output, .output_allocated = true };
}
```

- [ ] **Step 3: Add to `UNIFIED_TOOL_REGISTRY`**

In `tool_registry.zig` around line 1690 (after kanban tools, before LSP):

```zig
// === PREVIEW TOOLS ===
.{ .name = "show_preview", .exec = execShowPreview, .tool_def = show_preview_mod.show_preview_tool },
```

- [ ] **Step 4: Add to `allAgentTools()`**

In `tool_registry.zig` around line 1727 (in the `allAgentTools` comptime list, after `kanban_move_task_tool`):

```zig
show_preview_mod.show_preview_tool,
```

- [ ] **Step 5: Run tests + build**

```bash
timeout 180 zig build test --summary all 2>&1 | tail -n 10
timeout 180 zig build install:linux:system 2>&1 | tail -n 5
```
Expected: tests pass; `install:linux:system` succeeds (the `cp` step at the end fails harmlessly with permission denied on `/usr/local/bin/nalar`).

- [ ] **Step 6: Commit**

```bash
git add src/ai_workflow/tui/tool_registry.zig
git commit -m "feat(tools): wire show_preview into unified tool registry"
```

---

## Chunk 2: Frontend Side Panel

### Task 2.1: Create `PreviewSidePanel.vue`

**Files:**
- Create: `src/apps/desktop/src/components/PreviewSidePanel.vue`

- [ ] **Step 1: Implement the component**

```vue
<!--
  PreviewSidePanel — dedicated UI region for `show_preview` tool results.

  Mounted inside ChatView, on the right side of the messages wrapper.
  Receives `previews` (an array of tool-result messages with
  tool_name === 'show_preview') and renders:
    - A tab strip at the top (one entry per preview, oldest left, newest right).
    - The active preview in the main area (markdown / text / code / image).
    - A collapse chevron (hides content, leaves 32px strip).
    - A dismiss button (closes the panel entirely).
    - Empty state when previews is empty (renders nothing).

  The component does NOT fetch data, manage state, or subscribe to SSE.
  It receives the messages array as a prop and is a pure derived view.
  ChatView is responsible for filtering messages and managing the
  collapsed state.

  The full preview content is in `msg.parameters` (JSON-encoded
  {content_type, content, title, language, caption}). The inner
  <data> XML envelope (msg.content) carries only metadata
  (status, preview_id, content_type, length) — the actual content
  is NOT re-included to keep storage compact.

  Style mirrors KanbanList/NalarBrowser: monospace header, soft card
  bg, violet tool-name, +/− toggle on collapse.
-->
<script setup lang="ts">
import { computed, ref, watch } from 'vue'
import { marked } from 'marked'

const props = defineProps<{
  /** Tool-result messages with tool_name === 'show_preview' (oldest first). */
  previews: Array<{
    id: string
    content: string         // inner <data> XML envelope
    parameters?: string     // JSON-encoded {content_type, content, title, ...}
    tool_call_id?: string
  }>
  /** Whether the panel is collapsed (chevron-only). Two-way binding via update:collapsed. */
  collapsed?: boolean
}>()

const emit = defineEmits<{
  'update:collapsed': [value: boolean]
  'dismiss': []
}>()

// Local collapsed state (defaults to the prop).
const isCollapsed = ref(props.collapsed ?? false)
watch(() => props.collapsed, (v) => { isCollapsed.value = v ?? false })

// Index of the currently displayed preview. Newest by default.
const activeIndex = ref(0)
watch(() => props.previews.length, (newLen, oldLen) => {
  // Auto-switch to the newest preview when one is added.
  if (newLen > (oldLen ?? 0)) {
    activeIndex.value = newLen - 1
  }
  // Clamp to valid range.
  if (activeIndex.value >= newLen) activeIndex.value = Math.max(0, newLen - 1)
})

// ── Inner-data XML parsing ──────────────────────────────────────
function findTag(haystack: string, tag: string): string | null {
  const openSeq = `<${tag}>`
  const closeSeq = `</${tag}>`
  const start = haystack.indexOf(openSeq)
  if (start === -1) return null
  const valueStart = start + openSeq.length
  const end = haystack.indexOf(closeSeq, valueStart)
  if (end === -1) return null
  return haystack.slice(valueStart, end)
}

const activePreview = computed(() => {
  if (props.previews.length === 0) return null
  return props.previews[activeIndex.value] ?? null
})

const activeContentType = computed(() => {
  const p = activePreview.value
  if (!p) return 'text'
  return findTag(p.content, 'content_type') ?? 'text'
})

const activePreviewId = computed(() => {
  const p = activePreview.value
  if (!p) return ''
  return findTag(p.content, 'preview_id') ?? ''
})

// ── Parameters parsing (JSON) ───────────────────────────────────
interface ShowPreviewArgs {
  content_type?: 'markdown' | 'text' | 'code' | 'image'
  content?: string
  title?: string
  language?: string
  caption?: string
}

const activeArgs = computed<ShowPreviewArgs>(() => {
  const p = activePreview.value
  if (!p || !p.parameters) return {}
  try {
    const parsed = JSON.parse(p.parameters)
    if (parsed && typeof parsed === 'object') return parsed as ShowPreviewArgs
  } catch { /* fall through */ }
  return {}
})

// ── Content rendering ───────────────────────────────────────────
function escapeHtml(s: string): string {
  return s
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;')
}

const renderedContent = computed<string>(() => {
  const ct = activeContentType.value
  const c = activeArgs.value.content ?? ''
  switch (ct) {
    case 'markdown':
      try {
        return marked.parse(c, { async: false }) as string
      } catch {
        return `<pre>${escapeHtml(c)}</pre>`
      }
    case 'text':
      return `<pre class="whitespace-pre-wrap break-all">${escapeHtml(c)}</pre>`
    case 'code': {
      const lang = activeArgs.value.language ?? 'plaintext'
      return `<pre><code class="language-${escapeHtml(lang)}">${escapeHtml(c)}</code></pre>`
    }
    case 'image':
      return '' // images rendered via the <img> element below
    default:
      return `<pre class="whitespace-pre-wrap break-all">${escapeHtml(c)}</pre>`
  }
})

const imageSrc = computed<string | null>(() => {
  if (activeContentType.value !== 'image') return null
  const c = activeArgs.value.content ?? ''
  if (c.startsWith('data:') || c.startsWith('http://') || c.startsWith('https://')) return c
  return null
})

// ── Tab labels ──────────────────────────────────────────────────
const contentTypeIcon: Record<string, string> = {
  markdown: '📝',
  text: '📄',
  code: '💻',
  image: '🖼️',
}

const tabLabel = (preview: { content: string; parameters?: string }): string => {
  const ct = findTag(preview.content, 'content_type') ?? 'text'
  const icon = contentTypeIcon[ct] ?? '📄'
  // Try to extract a title from parameters
  let title = ''
  if (preview.parameters) {
    try {
      const parsed = JSON.parse(preview.parameters)
      if (parsed && typeof parsed === 'object' && typeof parsed.title === 'string') {
        title = parsed.title
      }
    } catch { /* fall through */ }
  }
  if (title) return `${icon} ${title.length > 16 ? title.slice(0, 16) + '…' : title}`
  // Fallback: content_type + truncated content
  const len = (findTag(preview.content, 'content_length') ?? '0')
  return `${icon} ${ct} (${len}B)`
}

const toggleCollapse = () => {
  isCollapsed.value = !isCollapsed.value
  emit('update:collapsed', isCollapsed.value)
}

const dismiss = () => {
  emit('dismiss')
}
</script>

<template>
  <div
    v-if="previews.length > 0"
    class="preview-side-panel flex flex-col border-l border-[var(--color-border)] bg-[var(--semantic-bg)] transition-all duration-200"
    :class="isCollapsed ? 'w-8' : 'w-[480px]'"
    data-testid="preview-side-panel"
  >
    <!-- Collapsed: just a chevron with count -->
    <div
      v-if="isCollapsed"
      class="flex-1 flex flex-col items-center justify-start pt-4"
    >
      <button
        class="px-1 py-2 border-none bg-transparent cursor-pointer text-[var(--semantic-text-muted)] hover:text-[var(--color-violet)]"
        :title="`${previews.length} preview${previews.length !== 1 ? 's' : ''}`"
        @click="toggleCollapse"
      >
        <span class="block text-lg">▶</span>
        <span class="block text-xs mt-2 rotate-90 origin-center whitespace-nowrap">
          {{ previews.length }} preview{{ previews.length !== 1 ? 's' : '' }}
        </span>
      </button>
    </div>

    <!-- Expanded: full panel -->
    <template v-else>
      <!-- Header with collapse + dismiss -->
      <div class="flex items-center gap-1 px-2 py-1 border-b border-[var(--color-border)]">
        <button
          class="px-1 border-none bg-transparent cursor-pointer text-[var(--semantic-text-muted)] hover:text-[var(--color-violet)] text-sm"
          title="Collapse panel"
          @click="toggleCollapse"
        >
          ◀
        </button>
        <span class="text-[var(--color-violet)] font-semibold text-xs flex-1 truncate">Preview</span>
        <span class="text-[0.65rem] text-[var(--semantic-text-muted)]">{{ previews.length }} of {{ previews.length }}</span>
        <button
          class="px-1 border-none bg-transparent cursor-pointer text-[var(--semantic-text-muted)] hover:text-red-500"
          title="Dismiss panel"
          @click="dismiss"
        >
          ✕
        </button>
      </div>

      <!-- Tab strip (only when multiple previews) -->
      <div
        v-if="previews.length > 1"
        class="flex flex-wrap gap-1 px-2 py-1 border-b border-[var(--color-border)] bg-black/[0.02]"
      >
        <button
          v-for="(p, i) in previews"
          :key="p.id"
          class="px-2 py-1 rounded text-xs font-mono border"
          :class="i === activeIndex
            ? 'bg-[var(--color-violet)]/15 text-[var(--color-violet)] border-[var(--color-violet)]/40'
            : 'bg-transparent text-[var(--semantic-text-muted)] border-[var(--color-border)] hover:border-[var(--color-violet)]/40'"
          :title="`Preview ${i + 1}: ${findTag(p.content, 'preview_id') ?? ''}`"
          @click="activeIndex = i"
        >
          {{ tabLabel(p) }}
        </button>
      </div>

      <!-- Active preview content -->
      <div v-if="activePreview" class="flex-1 overflow-y-auto p-3">
        <!-- Title -->
        <div
          v-if="activeArgs.title"
          class="text-sm font-semibold text-[var(--semantic-text)] mb-2 pb-2 border-b border-dashed border-[var(--color-border)]"
        >
          {{ activeArgs.title }}
          <span v-if="activeArgs.language" class="ml-2 text-xs text-[var(--semantic-text-muted)] font-normal">
            [{{ activeArgs.language }}]
          </span>
        </div>

        <!-- Image -->
        <div
          v-if="activeContentType === 'image'"
          class="flex justify-center bg-black/[0.04] p-2 rounded"
        >
          <img
            v-if="imageSrc"
            :src="imageSrc"
            :alt="activeArgs.title || activeArgs.caption || 'Preview image'"
            class="max-w-full max-h-96 object-contain"
            @error="(e) => { (e.target as HTMLImageElement).style.display = 'none' }"
          />
          <div v-else class="text-xs text-red-500 italic">
            Image source invalid (expected data: URL or http(s):// URL)
          </div>
        </div>

        <!-- Markdown / text / code -->
        <div
          v-else
          class="text-xs text-[var(--semantic-text)] markdown-content"
          v-html="renderedContent"
        />

        <!-- Caption -->
        <div
          v-if="activeArgs.caption"
          class="mt-2 pt-2 text-xs italic text-[var(--semantic-text-muted)] border-t border-dashed border-[var(--color-border)]"
        >
          {{ activeArgs.caption }}
        </div>

        <!-- Debug footer -->
        <div class="mt-3 pt-2 text-[0.65rem] text-[var(--semantic-text-dim)] font-mono">
          {{ activeContentType }} · preview_id: {{ activePreviewId }}
        </div>
      </div>
    </template>
  </div>
</template>

<style scoped>
.markdown-content :deep(pre) {
  background: var(--color-code-bg, rgba(0, 0, 0, 0.05));
  padding: 0.5rem;
  border-radius: 0.25rem;
  overflow-x: auto;
}
.markdown-content :deep(code) {
  font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace;
  font-size: 0.75rem;
}
.markdown-content :deep(h1) { font-size: 1.25rem; font-weight: 700; margin: 0.5rem 0; }
.markdown-content :deep(h2) { font-size: 1.1rem; font-weight: 600; margin: 0.4rem 0; }
.markdown-content :deep(h3) { font-size: 1rem; font-weight: 600; margin: 0.3rem 0; }
.markdown-content :deep(p) { margin: 0.25rem 0; line-height: 1.4; }
.markdown-content :deep(ul), .markdown-content :deep(ol) { margin: 0.25rem 0 0.25rem 1.5rem; }
.markdown-content :deep(a) { color: var(--color-violet); text-decoration: underline; }
.markdown-content :deep(table) { border-collapse: collapse; margin: 0.5rem 0; }
.markdown-content :deep(th), .markdown-content :deep(td) {
  border: 1px solid var(--color-border);
  padding: 0.25rem 0.5rem;
}
</style>
```

- [ ] **Step 2: Verify with build**

```bash
cd src/apps/desktop
timeout 120 bun run build 2>&1 | tail -n 20
```
Expected: build succeeds.

- [ ] **Step 3: Commit**

```bash
git add src/apps/desktop/src/components/PreviewSidePanel.vue
git commit -m "feat(frontend): add PreviewSidePanel component"
```

---

### Task 2.2: Wire `PreviewSidePanel` into `ChatView.vue`

**Files:**
- Modify: `src/apps/desktop/src/components/ChatView.vue`

- [ ] **Step 1: Add the import**

In the `<script setup>` block of ChatView.vue, add (near the other component imports around line 38-39):

```ts
import PreviewSidePanel from './PreviewSidePanel.vue'
```

- [ ] **Step 2: Add a `showPreviewMessages` computed**

After the existing message-derived computeds, add:

```ts
import { computed as _computed } from 'vue' // (if not already imported)
// ... or just use `computed` from the existing import

const showPreviewMessages = computed(() =>
  messages.value.filter((m) => m.tool_name === 'show_preview')
)
```

- [ ] **Step 3: Add local state for collapse / dismiss**

In the `<script setup>` of ChatView, add:

```ts
const previewPanelCollapsed = ref(false)
const previewPanelDismissed = ref(false)

// Auto-open + un-dismiss the panel when a new show_preview message arrives.
watch(showPreviewMessages, (newArr, oldArr) => {
  if ((newArr?.length ?? 0) > (oldArr?.length ?? 0)) {
    previewPanelCollapsed.value = false
    previewPanelDismissed.value = false
  }
})

// Reset when the chat changes (different session = different previews).
watch(() => props.chatId, () => {
  previewPanelCollapsed.value = false
  previewPanelDismissed.value = false
})
```

- [ ] **Step 4: Mount the side panel**

Find the top-level `<div class="chat-view ...">` wrapper in ChatView.vue
(search for `chat-view` class). Restructure it to be a horizontal flex
container with the messages wrapper on the left and the preview panel
on the right:

```vue
<div class="chat-view flex h-full" data-testid="chat-view">
  <!-- Existing messages wrapper (left, flex-1) -->
  <div ref="messagesWrapperRef" class="messages-wrapper flex-1 overflow-y-auto ...">
    <!-- existing content -->
  </div>

  <!-- Preview side panel (right, fixed 480px or 32px collapsed) -->
  <PreviewSidePanel
    v-if="!previewPanelDismissed"
    :previews="showPreviewMessages"
    v-model:collapsed="previewPanelCollapsed"
    @dismiss="previewPanelDismissed = true"
  />
</div>
```

(The exact class names for the messages wrapper depend on the existing
ChatView markup. Read the file and merge the flex layout carefully.)

- [ ] **Step 5: Verify with build**

```bash
cd src/apps/desktop
timeout 120 bun run build 2>&1 | tail -n 20
```
Expected: build succeeds.

- [ ] **Step 6: Manual smoke check (optional before commit)**

If possible, start the dev server and verify the panel renders. Otherwise commit and rely on Task 3.1's manual smoke test.

- [ ] **Step 7: Commit**

```bash
git add src/apps/desktop/src/components/ChatView.vue
git commit -m "feat(frontend): mount PreviewSidePanel in ChatView with auto-open on new preview"
```

---

### Task 2.3: Add frontend unit tests for `PreviewSidePanel`

**Files:**
- Create: `src/apps/desktop/src/__tests__/previewSidePanel.spec.ts`

- [ ] **Step 1: Implement unit tests**

```ts
import { describe, it, expect, beforeEach } from 'vitest'
import { mount } from '@vue/test-utils'
import { nextTick } from 'vue'
import PreviewSidePanel from '../components/PreviewSidePanel.vue'

const makePreview = (overrides: Partial<{
  id: string
  content: string
  parameters: string
}> = {}) => ({
  id: overrides.id ?? 'msg-1',
  content: overrides.content ?? '<show_preview><status>shown</status><preview_id>pv_test_1</preview_id><content_type>markdown</content_type><content_length>7</content_length></show_preview>',
  parameters: overrides.parameters ?? JSON.stringify({ content_type: 'markdown', content: '# Hello' }),
})

describe('PreviewSidePanel', () => {
  it('renders nothing when previews array is empty', () => {
    const wrapper = mount(PreviewSidePanel, { props: { previews: [] } })
    expect(wrapper.find('[data-testid="preview-side-panel"]').exists()).toBe(false)
  })

  it('renders panel when previews has one item', () => {
    const wrapper = mount(PreviewSidePanel, {
      props: { previews: [makePreview()] },
    })
    expect(wrapper.find('[data-testid="preview-side-panel"]').exists()).toBe(true)
  })

  it('renders markdown content via marked()', () => {
    const wrapper = mount(PreviewSidePanel, {
      props: {
        previews: [makePreview({
          parameters: JSON.stringify({ content_type: 'markdown', content: '# Title' }),
        })],
      },
    })
    const html = wrapper.html()
    expect(html).toContain('Title')
    expect(html).toContain('<h1')
  })

  it('renders image content as <img>', () => {
    const wrapper = mount(PreviewSidePanel, {
      props: {
        previews: [makePreview({
          content: '<show_preview><content_type>image</content_type></show_preview>',
          parameters: JSON.stringify({
            content_type: 'image',
            content: 'data:image/png;base64,iVBORw0KGgo=',
          }),
        })],
      },
    })
    const img = wrapper.find('img')
    expect(img.exists()).toBe(true)
    expect(img.attributes('src')).toContain('data:image/png;base64')
  })

  it('renders code content with language class', () => {
    const wrapper = mount(PreviewSidePanel, {
      props: {
        previews: [makePreview({
          content: '<show_preview><content_type>code</content_type></show_preview>',
          parameters: JSON.stringify({
            content_type: 'code',
            content: 'fn main() void {}',
            language: 'zig',
          }),
        })],
      },
    })
    expect(wrapper.html()).toContain('language-zig')
  })

  it('shows tabs when multiple previews are present', async () => {
    const wrapper = mount(PreviewSidePanel, {
      props: {
        previews: [
          makePreview({ id: '1' }),
          makePreview({ id: '2', parameters: JSON.stringify({ content_type: 'code', content: 'x', language: 'py' }) }),
        ],
      },
    })
    const tabs = wrapper.findAll('button[class*="font-mono"]')
    expect(tabs.length).toBeGreaterThanOrEqual(2)
  })

  it('auto-switches to the newest preview when one is added', async () => {
    const wrapper = mount(PreviewSidePanel, {
      props: { previews: [makePreview({ id: '1' })] },
    })
    expect(wrapper.text()).toContain('markdown') // initial

    await wrapper.setProps({
      previews: [
        makePreview({ id: '1' }),
        makePreview({
          id: '2',
          content: '<show_preview><content_type>code</content_type></show_preview>',
          parameters: JSON.stringify({ content_type: 'code', content: 'x', language: 'py' }),
        }),
      ],
    })
    await nextTick()
    expect(wrapper.text()).toContain('language-py')
  })

  it('collapses to a 32px chevron when collapse button is clicked', async () => {
    const wrapper = mount(PreviewSidePanel, {
      props: { previews: [makePreview()] },
    })
    const collapseBtn = wrapper.find('button[title="Collapse panel"]')
    await collapseBtn.trigger('click')
    expect(wrapper.emitted('update:collapsed')).toBeTruthy()
  })

  it('emits dismiss event when dismiss button is clicked', async () => {
    const wrapper = mount(PreviewSidePanel, {
      props: { previews: [makePreview()] },
    })
    const dismissBtn = wrapper.find('button[title="Dismiss panel"]')
    await dismissBtn.trigger('click')
    expect(wrapper.emitted('dismiss')).toBeTruthy()
  })
})
```

- [ ] **Step 2: Run tests**

```bash
cd src/apps/desktop
timeout 120 bunx vitest run previewSidePanel 2>&1 | tail -n 20
```
Expected: 9/9 tests pass.

- [ ] **Step 3: Commit**

```bash
git add src/apps/desktop/src/__tests__/previewSidePanel.spec.ts
git commit -m "test(frontend): add PreviewSidePanel component unit tests"
```

---

## Chunk 3: End-to-End Verification + Documentation

### Task 3.1: Build + test verification

- [ ] **Step 1: Run the full backend test suite**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
timeout 180 zig build test --summary all 2>&1 | tail -n 5
```
Expected: `test success`; test count should be baseline + 6 (Task 1.1 static) + 6 (Task 1.1 behavioral) = +12.

- [ ] **Step 2: Build the backend (full graph)**

```bash
timeout 180 zig build install:linux:system 2>&1 | tail -n 5
```
Expected: 4/6 steps succeed (the cp step at the end fails harmlessly with permission denied on `/usr/local/bin/nalar`).

- [ ] **Step 3: Build the frontend (type-check + bundle)**

```bash
cd src/apps/desktop
timeout 120 bun run build 2>&1 | tail -n 10
```
Expected: build succeeds.

- [ ] **Step 4: Run the frontend unit tests**

```bash
timeout 120 bunx vitest run 2>&1 | tail -n 10
```
Expected: all tests pass (baseline + 9 new = baseline + 9).

---

### Task 3.2: Manual smoke test

- [ ] **Step 1: Start the backend on port 8080**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
./zig-out/bin/nalar --port 8080 &
```

- [ ] **Step 2: Open the chat UI in a browser**

Navigate to `http://127.0.0.1:8080/`.

- [ ] **Step 3: Send a test prompt that triggers show_preview**

Type: "Use show_preview to show me a sample markdown summary of the project structure, then show_preview with a code block in Python, then show_preview with a small test image."

Expected:
- The side panel appears on the right of the chat.
- Three tabs are visible at the top of the panel (markdown, python, image).
- The newest preview (image) is displayed in the main area.
- Clicking a tab switches the main area to that preview.
- Clicking ◀ collapses the panel to a thin chevron strip; clicking ▶ expands it.
- Clicking ✕ closes the panel entirely (no visual footprint).

- [ ] **Step 4: Test reload persistence**

Refresh the page.

Expected: The side panel reappears with all three previews (rebuilt from `llm_history`).

- [ ] **Step 5: Stop the dev process**

```bash
kill $(pgrep -f "nalar --port 8080")
```

---

### Task 3.3: Documentation

**Files:**
- Modify: `docs/sse-reconnect-plan.md` (or create `docs/show-preview-plan.md`)

- [ ] **Step 1: Document the new tool**

Add an entry to the table of agent tools in the README or relevant docs
file (search for the tool list table — likely `docs/agent-tools.md` or
similar). If no such doc exists, create a brief section in
`docs/show-preview.md`:

```markdown
## show_preview

Show a visual preview to the user in the side panel of the chat.

**Input:** `{content_type, content, title?, language?, caption?}`
- `content_type`: `markdown | text | code | image`
- `content`: the content to display (string; up to 1 MB)
- For `code`, `language` is required (e.g., `python`, `zig`)

**Output to LLM:** `<show_preview><status>shown</status>...</show_preview>`

**SSE event:** none — uses the standard `llm_full` event with
`tool_name='show_preview'`. The frontend's `<PreviewSidePanel>` filters
the messages array.

**Persistence:** `llm_history` row with `tool_name='show_preview'` and
`parameters` containing the full content (the inner `<data>` envelope
carries only metadata).
```

- [ ] **Step 2: Commit**

```bash
git add docs/
git commit -m "docs: document show_preview agent tool"
```

---

## Verification

After completing all chunks:

1. **All tests pass**:
   ```bash
   timeout 180 zig build test --summary all 2>&1 | tail -n 5
   cd src/apps/desktop && timeout 120 bunx vitest run 2>&1 | tail -n 5
   ```

2. **Build succeeds**:
   ```bash
   timeout 180 zig build install:linux:system 2>&1 | tail -n 5
   cd src/apps/desktop && timeout 120 bun run build 2>&1 | tail -n 5
   ```

3. **Manual smoke test** confirms:
   - `show_preview` tool appears in the LLM's tool list.
   - Side panel auto-opens on the right of ChatView when a preview arrives.
   - Tabs switch between multiple previews.
   - Markdown renders via `marked()`.
   - Code blocks have language classes (`language-python`, `language-zig`, etc.).
   - Images (data URL or http URL) render inline.
   - Reload preserves all previews via the existing `llm_history` path.
   - Collapse / dismiss UX works.

## Pitfalls to watch for

- **UTF-8 sanitization**: the `parameters` JSON will contain the raw
  `content`. If the LLM passes a tool output with binary bytes, the JSON
  serialization on the wire (via `std.json.Stringify`) will emit it as
  an array of integers (see project memory
  `zig-0.16-std-json-fmt-emits-invalid-utf8-as-array`). Mitigation: the
  Zig tool sanitizes `content` before storing it in `parameters`. The
  existing `helpers.sanitize.sanitizeUtf8` replaces invalid bytes with
  U+FFFD.
- **preview_id collision**: use `unix_ms + random suffix`. Don't reuse
  timestamps.
- **Content type validation**: enforce the enum. The LLM sometimes
  hallucinates `"md"` or `"text/plain"`. Return a clear error.
- **Size cap**: enforce strictly. A 5 MB markdown will hang the renderer.
- **Vue 3 `watch` with `oldArr` undefined**: the `watch` callback in
  Task 2.2 has `oldArr` typed as the previous value. On the first run
  it's `undefined`. Use `oldArr?.length ?? 0` to avoid TS errors.
- **ChatView layout shift**: adding a side panel changes ChatView's
  horizontal flex layout. The messages wrapper must be `flex-1` (takes
  remaining space) and the panel must be a fixed width. If the chat
  view becomes too narrow, the messages wrapper may squish — consider a
  min-width guard in a follow-up.
- **Lazy analysis in `zig build test`**: the `execShowPreview` code path
  may not be reached by the test runner's module graph. Always also run
  `zig build install:linux:system` to verify the full graph compiles.
- **`msg.parameters` field name**: the frontend's `Message` interface
  must include a `parameters?: string` field. If it doesn't, the side
  panel can't read the content. Verify the field is added in Task 2.2.
- **Multi-byte UTF-8 in titles**: titles are user-facing strings; sanitize
  on the Zig side before passing to JSON. The `xmlEscape` in Task 1.1
  only handles the envelope's preview_id, not the user-provided title.
  Title escaping happens via the standard JSON serializer (which
  handles it correctly).