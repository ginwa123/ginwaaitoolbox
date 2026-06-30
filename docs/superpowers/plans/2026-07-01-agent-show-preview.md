# `show_preview` Agent Tool — Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `show_preview` agent tool that lets the LLM push visual content (images, markdown, code, plain text) directly to the user's chat UI in real time, with persistence via the existing `llm_history` table.

**Architecture:** New Zig tool `src/modules/agent/tools/show_preview.zig` validates + sanitizes content, emits a new `show_preview` SSE event via a sibling `on_event_sent_show_preview.zig`, and writes the preview to `llm_history` via the existing `wrapToolOutput` envelope. Frontend adds a `<ShowPreview>` Vue component for the persistent tool-result row plus a transient Pinia-driven banner for live SSE signals.

**Tech Stack:** Zig 0.16, Vue 3 + TypeScript, Pinia, marked (markdown), highlight.js (code syntax), SSE.

**Reference design doc:** `docs/plans/2026-07-01-agent-show-preview-design.md`

**Key conventions to follow:**
- Tool schema definition in `src/modules/agent/tools/schemas.zig`
- Tool executor pattern: `pub fn execXxx(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult` in `src/ai_workflow/tui/tool_registry.zig`
- Tool registry: `UNIFIED_TOOL_REGISTRY` + `allAgentTools()`
- SSE pattern: `src/ai_workflow/tui/on_event_sent_kanban.zig` (sibling module, not modifying `on_event_sent.zig`)
- Frontend pattern: `src/apps/desktop/src/components/tool_outputs/<ToolName>.vue` (e.g. `<KanbanList>`, `<NalarBrowser>`)
- Test pattern: static source checks in `src/modules/agent/tools/<tool>_test.zig`, registered in `src/ai_workflow/tui/test_runner.zig`
- Frontend tests in `src/apps/desktop/src/__tests__/`

---

## File Structure

| File | Responsibility | Action |
|---|---|---|
| `src/modules/agent/tools/show_preview.zig` | Tool schema + input parsing + content validation + size cap + UTF-8 sanitization + preview_id generation + `<show_preview>` XML envelope | Create |
| `src/modules/agent/tools/show_preview_test.zig` | Static source-check tests (tool name, schema fields, error handling) + behavioral test for executeShowPreviewToString | Create |
| `src/ai_workflow/tui/on_event_sent_show_preview.zig` | `onEventSendShowPreview` function emitting `show_preview` SSE event via existing event_bus | Create |
| `src/ai_workflow/tui/on_event_sent_show_preview_test.zig` | Static tests asserting event name + payload fields | Create |
| `src/ai_workflow/tui/mod.zig` | Re-export new `on_event_sent_show_preview` module | Modify |
| `src/ai_workflow/tui/tool_registry.zig` | Add `execShowPreview` + register in `UNIFIED_TOOL_REGISTRY` + add to `allAgentTools()` | Modify |
| `src/ai_workflow/tui/test_runner.zig` | Register new test files | Modify |
| `src/apps/desktop/src/api/index.ts` | Add `ShowPreviewEvent` interface + register `'show_preview'` in `additionalEventTypes` | Modify |
| `src/apps/desktop/src/stores/preview.ts` | Pinia store for transient previews (current + recent list) | Create |
| `src/apps/desktop/src/components/ChatView.vue` | Wire `<ShowPreview>` component into tool-name switch; subscribe to live `show_preview` bus events → push to previewStore; render transient banner | Modify |
| `src/apps/desktop/src/components/tool_outputs/ShowPreview.vue` | Render the persistent preview row (markdown / text / code / image) | Create |
| `src/apps/desktop/src/components/PreviewBanner.vue` | Transient "Previewing: X" banner at top of chat, auto-dismiss after 5s | Create |
| `src/apps/desktop/src/__tests__/showPreview.spec.ts` | Unit tests for `<ShowPreview>` rendering + `<PreviewBanner>` auto-dismiss | Create |

---

## Chunk 1: Backend Tool + SSE Event (Zig)

### Task 1.1: Create `show_preview.zig` tool with input + execute function

**Files:**
- Create: `src/modules/agent/tools/show_preview.zig`

- [ ] **Step 1: Write the failing static tests for tool definition**

Create `src/modules/agent/tools/show_preview_test.zig` with at least these tests:
- Tool file defines `show_preview_tool` constant
- Tool name is `"show_preview"` (string literal)
- Schema has all 5 properties: `content_type`, `content`, `title`, `language`, `caption`
- `required` array contains `"content_type"` and `"content"`
- `description` mentions "first-class card" or similar inline-rendering hint
- A function named `executeShowPreviewToString` exists

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
timeout 180 zig build test --summary all 2>&1 | tail -n 20
```
Expected: tests fail with `error.FileNotFound` or similar (show_preview_test.zig imports a non-existent file).

- [ ] **Step 3: Implement the tool definition**

Create `src/modules/agent/tools/show_preview.zig` with the constants:

```zig
const std = @import("std");
const schemas = @import("schemas.zig");
const AgentTool = schemas.AgentTool;
const nalarcore = @import("nalarcore");
const sqlite = nalarcore.sqlite;
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
            \\Show a visual preview to the user inline in the chat. Use this whenever you produce something the user might want to see at a glance — a rendered chart, a generated image, a polished markdown summary, a code snippet, a URL preview, a formatted table. The preview is rendered as a first-class card in the chat history (not a collapsed XML tool result), survives page reload, and can be called multiple times per turn.
            \\
            \\content_type selects how the frontend renders the content:
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
                .{
                    .name = "content_type",
                    .type = "string",
                    .description = "How the frontend should render the content. One of 'markdown', 'text', 'code', 'image'.",
                },
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
pub fn generatePreviewId(allocator: std.mem.Allocator) ![]u8 {
    const ts = std.Io.Clock.now(.real, allocator)... ; // see Step 3a
}
```

**Step 3a — IO clock pattern**: Use the established Zig 0.16 pattern. Reference `src/ai_workflow/tui/background_process.zig:178-179`:
```zig
const ts = std.Io.Clock.now(.real, io);
const started_at: i64 = ts.toSeconds();
```

For the preview_id we want milliseconds. Wrap the call:
```zig
pub fn generatePreviewId(allocator: std.mem.Allocator, io: std.Io) ![]u8 {
    const ts = std.Io.Clock.now(.real, io);
    const ms: i64 = ts.toMilliseconds(); // verify in stdlib or compute manually
    var rand_buf: [3]u8 = undefined;
    // ... fill from c.getrandom or std.crypto
    return try std.fmt.allocPrint(allocator, "pv_{d}_{x}", .{ ms, rand_buf });
}
```

**Verification before continuing**: read `/usr/local/lib/zig/std/Io/Clock.zig` to confirm the `toMilliseconds` method exists. If not, use `ts.nanoseconds` directly.

- [ ] **Step 4: Implement content validation + XML envelope**

In the same file, add:

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
/// and optionally populates `out_preview_id` with the generated id (the
/// SSE event emitter needs this).
///
/// Response shapes:
///   Success: <show_preview><status>shown</status>...</show_preview>
///   Error:   <show_preview><error>...</error></show_preview>
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
    if (std.mem.eql(u8, input.content_type, "code") and (input.language == null or input.language.?.len == 0)) {
        return errorEnvelope(allocator, try allocator.dupe(u8, "content_type='code' requires the 'language' field"));
    }

    // 4. Sanitize content to valid UTF-8 (same pattern as on_event_sent.zig:254)
    const sanitized_content = helpers.sanitize.sanitizeUtf8(allocator, input.content) catch |err| blk: {
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

- [ ] **Step 5: Run static tests to verify they pass**

```bash
timeout 180 zig build test --summary all 2>&1 | tail -n 10
```
Expected: All show_preview_test.zig tests pass; pre-existing tests unchanged.

- [ ] **Step 6: Add behavioral tests**

Append to `src/modules/agent/tools/show_preview_test.zig`:

```zig
const ShowPreviewInput = @import("show_preview.zig").ShowPreviewInput;

test "executeShowPreviewToString returns success envelope for markdown" {
    // ... call with content_type="markdown", content="# Hello"
    // assert output contains <status>shown</status>
    // assert preview_id starts with "pv_"
}

test "executeShowPreviewToString returns error for invalid content_type" {
    // ... call with content_type="invalid"
    // assert output contains <error> and "invalid content_type"
}

test "executeShowPreviewToString returns error when content exceeds 1 MB" {
    // ... call with content.len > MAX_CONTENT_BYTES
    // assert output contains <error> and "exceeds"
}

test "executeShowPreviewToString requires language for code type" {
    // ... call with content_type="code" and no language
    // assert output contains <error> and "language"
}

test "executeShowPreviewToString sanitizes invalid UTF-8 in content" {
    // ... pass content with invalid UTF-8 byte (0xFF)
    // assert the returned preview_id is generated (sanitize succeeded)
}
```

For the Io parameter in tests, follow the pattern from `src/ai_workflow/tui/routines/fire_test.zig`:
```zig
var threaded = std.Io.Threaded.init(testing.allocator, .{});
defer threaded.deinit();
const io = threaded.io();
```

- [ ] **Step 7: Register tests in test_runner.zig**

Modify `src/ai_workflow/tui/test_runner.zig`:

```zig
_ = @import("show_preview_test.zig");           // ADD
_ = @import("on_event_sent_show_preview_test.zig"); // ADD (next task)
```

- [ ] **Step 8: Commit**

```bash
git add src/modules/agent/tools/show_preview.zig src/modules/agent/tools/show_preview_test.zig src/ai_workflow/tui/test_runner.zig
git commit -m "feat(tools): add show_preview tool definition + executeShowPreviewToString"
```

---

### Task 1.2: Create `on_event_sent_show_preview.zig` SSE emitter

**Files:**
- Create: `src/ai_workflow/tui/on_event_sent_show_preview.zig`
- Create: `src/ai_workflow/tui/on_event_sent_show_preview_test.zig`

- [ ] **Step 1: Implement the SSE emitter**

Create `src/ai_workflow/tui/on_event_sent_show_preview.zig`:

```zig
//! SSE event for show_preview tool invocations.
//!
//! Emitted from `tool_registry.execShowPreview` on every successful
//! show_preview call. The frontend listener renders a transient banner
//! ("Previewing: <title>") and the persistent tool-result row (which
//! arrives later via the standard `llm_full` event).
//!
//! SSE wire-format contract (`event:` line name):
//!   - show_preview: emitted once per show_preview call
//!
//! Pattern mirrors `on_event_sent_kanban.zig`: this file lives in its
//! own module so the show_preview event types are co-located with the
//! tool, and `on_event_sent.zig` stays untouched. Re-exported as
//! `nalarcore.ai_mod.on_event_sent_show_preview` from
//! `src/ai_workflow/tui/mod.zig`.

const std = @import("std");
const nalarcore = @import("nalarcore");
const on_event_sent = nalarcore.ai_mod.on_event_sent;
const SseEvent = on_event_sent.SseEvent;

/// JSON payload for a `show_preview` SSE event. Field names match the
/// frontend's `ShowPreviewEvent` interface (snake_case — see
/// `src/apps/desktop/src/api/index.ts`).
pub const ShowPreviewEventPayload = struct {
    preview_id: []const u8,
    session_id: []const u8,
    tool_call_id: ?[]const u8 = null,
    content_type: []const u8,
    content: []const u8,
    title: ?[]const u8 = null,
    language: ?[]const u8 = null,
    caption: ?[]const u8 = null,
};

/// Emit a `show_preview` SSE event. Called from
/// `tool_registry.execShowPreview` on every successful invocation.
///
/// Allocates a JSON-safe copy of every payload field via
/// `std.json.Stringify.valueAlloc`; the caller passes raw slices and
/// may free them after this function returns.
///
/// The `event_bus` is fetched from the singleton (`di.event_bus`),
/// same pattern as `onEventSendKanbanColumn` in
/// `on_event_sent_kanban.zig`. When no SSE client is subscribed,
/// `event_bus.emit` is a no-op — so the tool can call this
/// unconditionally without guarding for "is an SSE subscriber connected".
pub fn onEventSendShowPreview(
    allocator: std.mem.Allocator,
    payload: ShowPreviewEventPayload,
) !void {
    const json_payload = try std.json.Stringify.valueAlloc(
        allocator,
        payload,
        .{},
    );
    defer allocator.free(json_payload);

    const event = SseEvent{
        .session_id = payload.session_id,
        .data = json_payload,
        .event_type = "show_preview",
    };

    const di = nalarcore.getSingleton() catch return;
    di.event_bus.emit(SseEvent, "show_preview", event);
}
```

- [ ] **Step 2: Add static tests**

Create `src/ai_workflow/tui/on_event_sent_show_preview_test.zig`:

```zig
const std = @import("std");
const testing = std.testing;

const FILE_PATH = "src/ai_workflow/tui/on_event_sent_show_preview.zig";

fn readSource(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(
        testing.io,
        path,
        allocator,
        .limited(256 * 1024),
    );
}

test "emits 'show_preview' named event" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, FILE_PATH);
    defer allocator.free(source);
    if (std.mem.indexOf(u8, source, `.event_type = "show_preview"`) == null) {
        return error.ShowPreviewEventTypeMissing;
    }
}

test "payload has preview_id field" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, FILE_PATH);
    defer allocator.free(source);
    if (std.mem.indexOf(u8, source, "preview_id: []const u8") == null) {
        return error.ShowPreviewPayloadPreviewIdMissing;
    }
}

test "payload has content + content_type + title + language + caption" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, FILE_PATH);
    defer allocator.free(source);
    const required = [_][]const u8{
        "content_type: []const u8",
        "content: []const u8",
        "title: ?[]const u8",
        "language: ?[]const u8",
        "caption: ?[]const u8",
    };
    for (required) |needle| {
        if (std.mem.indexOf(u8, source, needle) == null) {
            std.debug.print("!! payload missing field {s} !!\n", .{needle});
            return error.ShowPreviewPayloadFieldMissing;
        }
    }
}

test "emits via event_bus.emit (not direct SSE)" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, FILE_PATH);
    defer allocator.free(source);
    // The emitter must use the shared event_bus (same as kanban events)
    // so it works whether or not an SSE client is connected.
    if (std.mem.indexOf(u8, source, "event_bus.emit") == null) {
        return error.EventBusEmitMissing;
    }
}
```

- [ ] **Step 3: Re-export from `mod.zig`**

Modify `src/ai_workflow/tui/mod.zig` (add after `on_event_sent_kanban`):

```zig
pub const on_event_sent_show_preview = @import("on_event_sent_show_preview.zig");
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
timeout 180 zig build test --summary all 2>&1 | tail -n 10
```
Expected: 4 new tests pass; no regressions.

- [ ] **Step 5: Commit**

```bash
git add src/ai_workflow/tui/on_event_sent_show_preview.zig src/ai_workflow/tui/on_event_sent_show_preview_test.zig src/ai_workflow/tui/mod.zig src/ai_workflow/tui/test_runner.zig
git commit -m "feat(sse): add show_preview SSE event emitter"
```

---

### Task 1.3: Wire `show_preview` into `tool_registry.zig`

**Files:**
- Modify: `src/ai_workflow/tui/tool_registry.zig`

- [ ] **Step 1: Add the import**

At the top of `tool_registry.zig` (after the other tool imports, around line 47):

```zig
const show_preview_mod = nalar_mod.show_preview;
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

    var preview_id_buf: [32]u8 = undefined;
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

    // Sanitize input.content for the live SSE event (same pattern as
    // on_event_sent.zig:254). The inner XML envelope already passes the
    // sanitized length back, but we need the full sanitized content for
    // the SSE payload.
    const sanitized_content = helpers.sanitize.sanitizeUtf8(ctx.allocator, parsed.value.content) catch parsed.value.content;
    defer if (sanitized_content.ptr != parsed.value.content.ptr) ctx.allocator.free(sanitized_content);

    // Emit the live SSE event (transient banner).
    const show_preview_events = nalar_mod.ai_mod.on_event_sent_show_preview;
    show_preview_events.onEventSendShowPreview(ctx.allocator, .{
        .preview_id = preview_id,
        .session_id = ctx.session_id,
        .tool_call_id = tc.id,
        .content_type = parsed.value.content_type,
        .content = sanitized_content,
        .title = parsed.value.title,
        .language = parsed.value.language,
        .caption = parsed.value.caption,
    }) catch |err| {
        ctx.logger.warnFmt("show_preview SSE emit failed: {s}", .{@errorName(err)});
    };

    // Detect <error>...</error> in the envelope and surface as failure.
    if (std.mem.indexOf(u8, inner, "<error>") != null) {
        const err_start = (std.mem.indexOf(u8, inner, "<error>") orelse 0) + "<error>".len;
        const err_end = std.mem.indexOf(u8, inner[err_start..], "</error>") orelse inner.len;
        const err_msg = inner[err_start .. err_start + err_end];
        const output = try wrapToolOutput(ctx.allocator, "show_preview", tc.function.arguments, false, err_msg, inner);
        return ToolExecResult{ .output = output, .output_allocated = true };
    }

    const output = try wrapToolOutput(ctx.allocator, "show_preview", tc.function.arguments, true, null, inner);
    return ToolExecResult{ .output = output, .output_allocated = true };
}
```

**IMPORTANT GOTCHA — pointer comparison**: the `sanitized_content.ptr != parsed.value.content.ptr` check distinguishes "sanitize made a copy" from "sanitize returned the input unchanged" (e.g., when content is already valid UTF-8). If they're the same, don't double-free.

- [ ] **Step 3: Add to `UNIFIED_TOOL_REGISTRY`**

In `tool_registry.zig` around line 1690 (after kanban tools, before LSP):

```zig
// === PREVIEW TOOLS ===
.{ .name = "show_preview", .exec = execShowPreview, .tool_def = show_preview_mod.show_preview_tool },
```

- [ ] **Step 4: Add to `allAgentTools()`**

In `tool_registry.zig` around line 1727 (in the `allAgentTools` comptime list, after kanban_move_task_mod.kanban_move_task_tool):

```zig
show_preview_mod.show_preview_tool,
```

- [ ] **Step 5: Run tests + build**

```bash
timeout 180 zig build test --summary all 2>&1 | tail -n 10
timeout 180 zig build install:linux:system 2>&1 | tail -n 5
```
Expected: tests pass; install:linux:system succeeds (the `cp` step at the end fails harmlessly with permission denied on `/usr/local/bin/nalar`).

- [ ] **Step 6: Commit**

```bash
git add src/ai_workflow/tui/tool_registry.zig
git commit -m "feat(tools): wire show_preview into unified tool registry"
```

---

### Task 1.4: Add behavioral test for `execShowPreview` end-to-end

**Files:**
- Modify: `src/modules/agent/tools/show_preview_test.zig`

- [ ] **Step 1: Add end-to-end behavioral test**

The behavioral test exercises the tool through the registry (same
pattern as `tool_registry_test.zig`). For a minimal test:

```zig
const tool_registry = @import("../../ai_workflow/tui/tool_registry.zig");
const agent = nalarcore.agent;

test "execShowPreview returns success envelope for valid markdown input" {
    const alloc = testing.allocator;

    // Use the same SQLite setup pattern as kanban_list_test.zig:
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var db: sqlite.SqliteBackend = .{};
    defer db.deinit();
    try db.init(io, ":memory:");

    // Minimal schema setup (sessions + workers for the ctx).
    try db.exec(alloc,
        \\CREATE TABLE IF NOT EXISTS sessions (id TEXT PRIMARY KEY, cwd TEXT)
    , &.{});
    try db.exec(alloc, "INSERT INTO sessions VALUES ('test_sid', '/tmp')", &.{});

    // Build a minimal ToolExecContext — fields not relevant to
    // show_preview can be left zero-initialized.
    var temperature: f32 = 0.7;
    var is_thinking: bool = false;
    var logger_buf: [4096]u8 = undefined;
    var logger_writer = std.fs.File.stderr().writer(&logger_buf);
    _ = &logger_writer;

    const args = try std.json.Stringify.valueAlloc(alloc, .{
        .content_type = "markdown",
        .content = "# Hello\n\nThis is a test.",
        .title = "Test Title",
        .language = null,
        .caption = "Test caption",
    }, .{});
    defer alloc.free(args);

    const tc = agent.ToolCall{
        .id = "call_test_1",
        .type = "function",
        .function = .{
            .name = "show_preview",
            .arguments = args,
        },
    };

    const result = try tool_registry.execShowPreview(.{
        .allocator = alloc,
        .io = io,
        .db = &db,
        .logger = undefined, // see logger setup
        .session_id = "test_sid",
        .model = "test-model",
        .cwd = "/tmp",
        .api_key = "test-key",
        .base_url = "https://api.test",
        .config = undefined, // see config setup
        .agent_temperature = &temperature,
        .is_thinking = &is_thinking,
        .environment = null,
        .active_loops = undefined,
    }, tc);
    defer alloc.free(result.output);

    // Assert output contains <success>true</success> and the preview_id
    if (std.mem.indexOf(u8, result.output, "<success>true</success>") == null) {
        return error.ExpectedSuccessEnvelope;
    }
    if (std.mem.indexOf(u8, result.output, "<show_preview>") == null) {
        return error.ExpectedShowPreviewEnvelope;
    }
}
```

**NOTE**: The exact `Logger` and `LlmConfig` setup depends on the project's
existing test helpers. Look at `src/ai_workflow/tui/tool_registry_test.zig`
for the canonical pattern (it likely initializes both). If init is too
complex, fall back to a static source-check that verifies the function
signature matches.

- [ ] **Step 2: Run tests**

```bash
timeout 180 zig build test --summary all 2>&1 | tail -n 10
```
Expected: new behavioral test passes.

- [ ] **Step 3: Commit**

```bash
git add src/modules/agent/tools/show_preview_test.zig
git commit -m "test(tools): add behavioral test for execShowPreview"
```

---

## Chunk 2: Frontend SSE Wiring + Pinia Store

### Task 2.1: Add `ShowPreviewEvent` interface + register SSE event type

**Files:**
- Modify: `src/apps/desktop/src/api/index.ts`

- [ ] **Step 1: Add the TS interface**

Add after the existing event interfaces (search for `KanbanColumnEvent`
or `KanbanTaskEvent` — add `ShowPreviewEvent` nearby):

```ts
/**
 * Event payload for the `show_preview` SSE event. Emitted by the
 * backend every time the agent calls `show_preview`. Carries the
 * preview_id (stable across reloads), session_id (routing key for
 * cross-session fan-out), the content to display, and the rendering
 * instructions.
 *
 * Mirrors the Zig `ShowPreviewEventPayload` struct in
 * `src/ai_workflow/tui/on_event_sent_show_preview.zig`. Field names
 * are snake_case to match the JSON wire format emitted by
 * `std.json.Stringify.valueAlloc`.
 */
export interface ShowPreviewEvent {
  preview_id: string
  session_id: string
  tool_call_id?: string
  content_type: 'markdown' | 'text' | 'code' | 'image'
  content: string
  title?: string
  language?: string
  caption?: string
}
```

- [ ] **Step 2: Register the named event in `createUnifiedSseConnection`**

Around line 1685 (where `kanban_column` and `kanban_task` are registered),
add `show_preview` to the `additionalEventTypes` list.

**Search pattern** in `api/index.ts`:
```ts
      'kanban_column',
      'kanban_task',
```
becomes:
```ts
      'kanban_column',
      'kanban_task',
      'show_preview',
```

Also add a `case` in the event-type switch (around line 1707 where
`eventType === 'kanban_column' || eventType === 'kanban_task'` is
handled) — add a sibling branch that parses the payload as a
`ShowPreviewEvent` and routes it to the bus callback.

- [ ] **Step 3: Verify with build**

```bash
cd src/apps/desktop
timeout 120 bun run build 2>&1 | tail -n 20
```
Expected: build succeeds; no new TS errors.

- [ ] **Step 4: Commit**

```bash
git add src/apps/desktop/src/api/index.ts
git commit -m "feat(frontend): add ShowPreviewEvent interface + SSE registration"
```

---

### Task 2.2: Create `previewStore` Pinia store for transient previews

**Files:**
- Create: `src/apps/desktop/src/stores/preview.ts`

- [ ] **Step 1: Implement the store**

```ts
import { defineStore } from 'pinia'
import { ref, computed } from 'vue'
import type { ShowPreviewEvent } from '../api'

/**
 * Pinia store for transient (live) preview banners shown in the chat
 * during an active agent turn.
 *
 * Persistent previews (the tool-result rows that survive reload) are
 * NOT stored here — they live in `llm_history` and are rendered by
 * `<ShowPreview>` from the message stream.
 *
 * This store only holds the **current** preview (auto-dismissed after
 * `BANNER_TIMEOUT_MS`) and the **recent** list (for the "view past
 * previews" feature, future scope). The recent list is capped at
 * `MAX_RECENT` to bound memory.
 */
const BANNER_TIMEOUT_MS = 5000
const MAX_RECENT = 20

export const usePreviewStore = defineStore('preview', () => {
  /** Current preview driving the banner. null when nothing to show. */
  const current = ref<ShowPreviewEvent | null>(null)

  /** Recent previews (newest first). Capped at MAX_RECENT. */
  const recent = ref<ShowPreviewEvent[]>([])

  /** Timer for auto-dismissing the current banner. */
  let dismissTimer: ReturnType<typeof setTimeout> | null = null

  function clearDismissTimer() {
    if (dismissTimer !== null) {
      clearTimeout(dismissTimer)
      dismissTimer = null
    }
  }

  function pushPreview(event: ShowPreviewEvent) {
    current.value = event

    // Add to recent (capped). Newest first.
    recent.value = [event, ...recent.value].slice(0, MAX_RECENT)

    // Auto-dismiss after timeout.
    clearDismissTimer()
    dismissTimer = setTimeout(() => {
      current.value = null
      dismissTimer = null
    }, BANNER_TIMEOUT_MS)
  }

  function dismissCurrent() {
    current.value = null
    clearDismissTimer()
  }

  function clearAll() {
    current.value = null
    recent.value = []
    clearDismissTimer()
  }

  const hasCurrent = computed(() => current.value !== null)

  return {
    current,
    recent,
    hasCurrent,
    pushPreview,
    dismissCurrent,
    clearAll,
  }
})
```

- [ ] **Step 2: Verify with build**

```bash
cd src/apps/desktop
timeout 120 bun run build 2>&1 | tail -n 20
```
Expected: build succeeds.

- [ ] **Step 3: Commit**

```bash
git add src/apps/desktop/src/stores/preview.ts
git commit -m "feat(frontend): add previewStore Pinia store for transient banners"
```

---

### Task 2.3: Wire bus listener in `ChatView.vue`

**Files:**
- Modify: `src/apps/desktop/src/components/ChatView.vue`

- [ ] **Step 1: Add the import + setup**

In the `<script setup>` block of ChatView.vue, add:

```ts
import { usePreviewStore } from '../stores/preview'

// ... inside setup, after other stores:
const previewStore = usePreviewStore()
```

- [ ] **Step 2: Add the bus subscription in `connectSse`**

In the `connectSse` function (search for `bus.on('llm'` or
`bus.subscribeSessionChannels`), add the show_preview listener:

```ts
// Register the show_preview listener (transient banner signal).
bus.on('show_preview', (event: ShowPreviewEvent) => {
  // Only react to previews for the active session.
  if (event.session_id !== sessionId.value) return
  previewStore.pushPreview(event)
})
```

Add `showPreview` to the `bus.off()` cleanup in `disconnectSse()` so
the listener is removed when the chat unmounts.

- [ ] **Step 3: Verify build**

```bash
cd src/apps/desktop
timeout 120 bun run build 2>&1 | tail -n 20
```
Expected: build succeeds.

- [ ] **Step 4: Commit**

```bash
git add src/apps/desktop/src/components/ChatView.vue
git commit -m "feat(frontend): subscribe ChatView to show_preview SSE events"
```

---

## Chunk 3: Frontend Renderer Component

### Task 3.1: Create `ShowPreview.vue` (persistent tool-result row)

**Files:**
- Create: `src/apps/desktop/src/components/tool_outputs/ShowPreview.vue`

- [ ] **Step 1: Implement the component**

```vue
<!--
  ShowPreview — tool output component for the `show_preview` agent tool.

  Renders the persistent preview row in the chat tool sequence.
  Receives:
    - `content`: inner <data> XML from the wrapToolOutput envelope.
      Shape: <show_preview><status>...</status><preview_id>...</preview_id>
             <content_type>...</content_type><content_length>...</content_length>
             [optional <error>...</error>]
    - `parameters`: raw JSON arguments (used to recover the original
      content + content_type, which the persistent XML envelope strips
      to keep storage compact).

  Three display modes:
    Success: header (tool name + content_type + size) → title (if set) →
             [markdown / text / code / image] → caption (if set)
    Error:   red error block
    Live SSE: NOT rendered here. The transient banner is in
              <PreviewBanner>. The persistent row is only the
              `llm_history`-derived view (visible after reload or after
              the tool result row arrives).

  Style mirrors KanbanList/NalarBrowser: monospace, rounded-md, border
  + soft card bg, violet tool-name, ✓/✗ status, +/− toggle.
-->
<script setup lang="ts">
import { computed, ref } from 'vue'
import { marked } from 'marked'

const props = defineProps<{
  /** Inner <data> XML from the tool result envelope. */
  content: string
  /** Raw JSON arguments passed by the LLM. Used for title, language, caption. */
  parameters: string
  /** Whether the row is already expanded (from parent state). */
  expanded?: boolean
}>()

const isExpanded = ref(props.expanded ?? false)

// ── Inner-data XML parsing ──────────────────────────────────────────
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

const errorMessage = computed(() => findTag(props.content, 'error'))
const status = computed(() => findTag(props.content, 'status'))
const contentType = computed(() => findTag(props.content, 'content_type') ?? 'text')
const contentLengthStr = computed(() => findTag(props.content, 'content_length') ?? '0')
const isSuccess = computed(() => errorMessage.value === null && status.value === 'shown')

// ── Parameters parsing (JSON) ────────────────────────────────────────
interface ShowPreviewArgs {
  content_type?: 'markdown' | 'text' | 'code' | 'image'
  content?: string
  title?: string
  language?: string
  caption?: string
}

const args = computed<ShowPreviewArgs>(() => {
  try {
    const parsed = JSON.parse(props.parameters)
    if (parsed && typeof parsed === 'object') return parsed as ShowPreviewArgs
  } catch {
    /* fall through */
  }
  return {}
})

// ── Content rendering ────────────────────────────────────────────────
const renderedContent = computed<string>(() => {
  const ct = contentType.value
  const c = args.value.content ?? ''
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
      const lang = args.value.language ?? 'plaintext'
      return `<pre><code class="language-${escapeHtml(lang)}">${escapeHtml(c)}</code></pre>`
    }
    case 'image':
      // The <img> tag is set directly via v-html below for safety.
      return c
    default:
      return `<pre class="whitespace-pre-wrap break-all">${escapeHtml(c)}</pre>`
  }
})

const imageSrc = computed<string | null>(() => {
  if (contentType.value !== 'image') return null
  const c = args.value.content ?? ''
  // Accept either data URLs (data:image/png;base64,...) or http(s)://...
  if (c.startsWith('data:') || c.startsWith('http://') || c.startsWith('https://')) return c
  return null
})

// ── Header content ───────────────────────────────────────────────────
function escapeHtml(s: string): string {
  return s
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;')
}

const headerLabel = computed(() => {
  if (!isSuccess.value) return 'error'
  const ct = contentType.value
  const bytes = parseInt(contentLengthStr.value, 10) || 0
  const kb = bytes < 1024 ? `${bytes} B` : `${(bytes / 1024).toFixed(1)} KB`
  return `${ct} · ${kb}`
})

const statusIndicator = computed(() => (isSuccess.value ? '✓' : '✗'))

const title = computed(() => args.value.title ?? '')
const caption = computed(() => args.value.caption ?? '')
const language = computed(() => args.value.language ?? '')

const toggle = () => {
  isExpanded.value = !isExpanded.value
}
</script>

<template>
  <div
    class="font-mono text-xs rounded-md overflow-hidden border border-[var(--color-border)] bg-[var(--semantic-card-bg)]"
    :class="{ 'border-red-500/50 opacity-90': !isSuccess }"
  >
    <!-- Header -->
    <div
      class="group flex items-center gap-1 px-2 py-1 cursor-pointer select-none hover:bg-violet-500/5"
      @click="toggle"
      role="button"
      tabindex="0"
    >
      <span class="text-[var(--color-violet)] font-semibold text-xs">show_preview</span>
      <span class="flex-1 truncate text-left text-[var(--semantic-text-muted)] text-xs">
        {{ headerLabel }}
      </span>

      <!-- Status indicator -->
      <span class="text-xs font-semibold" :class="isSuccess ? 'text-green-500' : 'text-red-500'">
        {{ statusIndicator }}
      </span>

      <!-- Toggle -->
      <span class="w-4 text-center text-[var(--semantic-text-muted)] text-sm">
        {{ isExpanded ? '−' : '+' }}
      </span>
    </div>

    <!-- Expanded content -->
    <div v-if="isExpanded" class="border-t border-[var(--color-border)] bg-black/[0.02]">
      <!-- Error -->
      <div v-if="errorMessage" class="flex gap-2 px-2 py-1.5 text-red-500 text-xs">
        <span class="font-semibold shrink-0">Error:</span>
        <span class="whitespace-pre-wrap break-all">{{ errorMessage }}</span>
      </div>

      <!-- Success -->
      <template v-else>
        <!-- Title -->
        <div
          v-if="title"
          class="px-3 py-1 text-sm font-semibold text-[var(--semantic-text)] border-b border-dashed border-[var(--color-border)]"
        >
          {{ title }}
          <span v-if="language" class="ml-2 text-xs text-[var(--semantic-text-muted)] font-normal">[{{ language }}]</span>
        </div>

        <!-- Content (markdown/text/code) -->
        <div
          v-if="contentType !== 'image'"
          class="px-3 py-2 text-xs text-[var(--semantic-text)] markdown-content"
          v-html="renderedContent"
        />

        <!-- Content (image) -->
        <div v-else class="px-3 py-2 flex justify-center bg-black/[0.04]">
          <img
            v-if="imageSrc"
            :src="imageSrc"
            :alt="title || caption || 'Preview image'"
            class="max-w-full max-h-96 object-contain"
            @error="(e) => { (e.target as HTMLImageElement).style.display = 'none' }"
          />
          <div v-else class="text-xs text-red-500 italic">
            Image source invalid (expected data: URL or http(s):// URL)
          </div>
        </div>

        <!-- Caption -->
        <div
          v-if="caption"
          class="px-3 py-1 text-xs italic text-[var(--semantic-text-muted)] border-t border-dashed border-[var(--color-border)]"
        >
          {{ caption }}
        </div>
      </template>
    </div>
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
.markdown-content :deep(th), .markdown-content :deep(td) { border: 1px solid var(--color-border); padding: 0.25rem 0.5rem; }
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
git add src/apps/desktop/src/components/tool_outputs/ShowPreview.vue
git commit -m "feat(frontend): add ShowPreview component for persistent tool-result rows"
```

---

### Task 3.2: Wire `<ShowPreview>` into ChatView's tool-name switch

**Files:**
- Modify: `src/apps/desktop/src/components/ChatView.vue`

- [ ] **Step 1: Add the import**

Add to the ChatView.vue imports (near the other `tool_outputs/` imports around line 38-39):

```ts
import ShowPreview from './tool_outputs/ShowPreview.vue'
```

- [ ] **Step 2: Add the v-if branch**

In the `template` section, after the `<KanbanList>` block (around line 2299), add:

```vue
                          <ShowPreview
                            v-else-if="msg.tool_name === 'show_preview'"
                            :content="innerToolData(msg)"
                            :parameters="getParametersForMessage(msg)"
                            :expanded="expandedToolIds.has(`${groupIndex}-${idx}`)"
                          />
```

- [ ] **Step 3: Add `show_preview` to the inline tool header label**

In the `formatToolHeader` function (around line 174), add a branch:

```ts
if (tool_name === 'show_preview') {
  // The arguments JSON has the title/content_type/length we need for
  // the collapsed preview. Reuse the same parse + extract pattern as
  // nalar_browser.
  return `<span class="tool-inline">${tool_name} → ${escapeHtml(previewLabel)}</span>`
}
```

(Reference: search for `if (tool_name === 'nalar_browser')` to see the
neighboring pattern, then mirror it for `show_preview`.)

- [ ] **Step 4: Verify build**

```bash
cd src/apps/desktop
timeout 120 bun run build 2>&1 | tail -n 20
```
Expected: build succeeds.

- [ ] **Step 5: Commit**

```bash
git add src/apps/desktop/src/components/ChatView.vue
git commit -m "feat(frontend): wire ShowPreview into ChatView tool-name switch"
```

---

### Task 3.3: Add transient `<PreviewBanner>` component

**Files:**
- Create: `src/apps/desktop/src/components/PreviewBanner.vue`

- [ ] **Step 1: Implement the component**

```vue
<!--
  PreviewBanner — transient banner shown at the top of the chat when a
  show_preview SSE event arrives.

  Driven by `usePreviewStore` (Pinia). Auto-dismisses after 5 seconds
  (managed by the store). Click the X to dismiss manually.

  Visual: small pill with the preview's title (or content_type if no
  title), a "previewing" label, and a dismiss button. Animates in from
  the top with a fade.
-->
<script setup lang="ts">
import { storeToRefs } from 'pinia'
import { usePreviewStore } from '../stores/preview'

const previewStore = usePreviewStore()
const { current } = storeToRefs(previewStore)

const label = () => {
  if (!current.value) return ''
  const title = current.value.title
  if (title) return title
  // No title → show the content_type + a short content excerpt
  const c = current.value.content
  const excerpt = c.length > 60 ? `${c.slice(0, 60)}...` : c
  return `${current.value.content_type} · ${excerpt}`
}
</script>

<template>
  <Transition name="preview-banner">
    <div
      v-if="current"
      class="preview-banner flex items-center gap-2 px-3 py-2 mb-2 rounded-md border border-[var(--color-violet)] bg-violet-500/10 text-xs"
      role="status"
    >
      <span class="text-[var(--color-violet)] font-semibold">Previewing:</span>
      <span class="flex-1 truncate text-[var(--semantic-text)]">{{ label() }}</span>
      <button
        class="px-1 border-none bg-transparent cursor-pointer text-[var(--semantic-text-muted)] hover:text-[var(--semantic-text)]"
        @click="previewStore.dismissCurrent()"
        title="Dismiss preview"
      >
        ✕
      </button>
    </div>
  </Transition>
</template>

<style scoped>
.preview-banner-enter-active,
.preview-banner-leave-active {
  transition: opacity 0.2s ease, transform 0.2s ease;
}
.preview-banner-enter-from,
.preview-banner-leave-to {
  opacity: 0;
  transform: translateY(-8px);
}
</style>
```

- [ ] **Step 2: Mount the banner in ChatView**

In ChatView.vue, add to imports:
```ts
import PreviewBanner from './PreviewBanner.vue'
```

In the template, place the banner above the messages wrapper (search for
`messagesWrapperRef` — the banner goes immediately before it):

```vue
      <PreviewBanner />

      <div ref="messagesWrapperRef" class="messages-wrapper ...">
```

- [ ] **Step 3: Verify build**

```bash
cd src/apps/desktop
timeout 120 bun run build 2>&1 | tail -n 20
```
Expected: build succeeds.

- [ ] **Step 4: Commit**

```bash
git add src/apps/desktop/src/components/PreviewBanner.vue src/apps/desktop/src/components/ChatView.vue
git commit -m "feat(frontend): add PreviewBanner transient banner component"
```

---

## Chunk 4: End-to-End Verification + Documentation

### Task 4.1: Add frontend unit tests

**Files:**
- Create: `src/apps/desktop/src/__tests__/showPreview.spec.ts`

- [ ] **Step 1: Implement unit tests**

```ts
import { describe, it, expect, beforeEach } from 'vitest'
import { mount } from '@vue/test-utils'
import { setActivePinia, createPinia } from 'pinia'
import { nextTick } from 'vue'
import ShowPreview from '../components/tool_outputs/ShowPreview.vue'

const XML_SUCCESS = `<show_preview><status>shown</status><preview_id>pv_test</preview_id><content_type>markdown</content_type><content_length>14</content_length></show_preview>`
const XML_ERROR = `<show_preview><error>content_type invalid</error></show_preview>`
const PARAMS_MARKDOWN = JSON.stringify({ content_type: 'markdown', content: '# Hello', title: 'Test' })
const PARAMS_IMAGE = JSON.stringify({ content_type: 'image', content: 'data:image/png;base64,iVBOR...' })

describe('ShowPreview', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
  })

  it('renders success header with content_type + size', () => {
    const wrapper = mount(ShowPreview, {
      props: { content: XML_SUCCESS, parameters: PARAMS_MARKDOWN },
    })
    expect(wrapper.text()).toContain('show_preview')
    expect(wrapper.text()).toContain('markdown')
  })

  it('renders error state when XML contains <error>', () => {
    const wrapper = mount(ShowPreview, {
      props: { content: XML_ERROR, parameters: '{}' },
    })
    expect(wrapper.text()).toContain('content_type invalid')
  })

  it('expands to show markdown content when toggled', async () => {
    const wrapper = mount(ShowPreview, {
      props: { content: XML_SUCCESS, parameters: PARAMS_MARKDOWN },
    })
    // Click header to expand
    await wrapper.find('[role="button"]').trigger('click')
    await nextTick()
    // Title should now be visible
    expect(wrapper.text()).toContain('Test')
  })

  it('renders <img> for image content_type', async () => {
    const wrapper = mount(ShowPreview, {
      props: { content: XML_SUCCESS, parameters: PARAMS_IMAGE },
    })
    await wrapper.find('[role="button"]').trigger('click')
    await nextTick()
    const img = wrapper.find('img')
    expect(img.exists()).toBe(true)
    expect(img.attributes('src')).toContain('data:image/png;base64')
  })
})
```

- [ ] **Step 2: Run tests**

```bash
cd src/apps/desktop
timeout 120 bunx vitest run showPreview 2>&1 | tail -n 20
```
Expected: 4/4 tests pass.

- [ ] **Step 3: Commit**

```bash
git add src/apps/desktop/src/__tests__/showPreview.spec.ts
git commit -m "test(frontend): add ShowPreview component unit tests"
```

---

### Task 4.2: End-to-end manual smoke test

- [ ] **Step 1: Build the backend**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
timeout 180 zig build install:linux:system 2>&1 | tail -n 5
```
Expected: 4/6 steps succeed (cp step fails harmlessly).

- [ ] **Step 2: Build the frontend**

```bash
cd src/apps/desktop
timeout 120 bun run build 2>&1 | tail -n 10
```
Expected: build succeeds.

- [ ] **Step 3: Run the desktop app on port 8080**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
./zig-out/bin/nalar --port 8080 &
```

- [ ] **Step 4: Send a test prompt that triggers show_preview**

In the chat UI, type: "Use show_preview to show me a sample markdown summary of the project structure, then show_preview with a small image."

Expected:
- The transient "Previewing:" banner appears briefly.
- The persistent tool-result rows appear in the chat history (one for
  the markdown, one for the image).
- Both previews can be expanded/collapsed.
- On page reload, both previews reappear from the DB.

- [ ] **Step 5: Stop the dev process**

```bash
kill $(pgrep -f "nalar --port 8080")
```

---

### Task 4.3: Documentation

**Files:**
- Modify: `docs/sse-reconnect-plan.md` (or create `docs/show-preview-plan.md`)

- [ ] **Step 1: Document the new SSE event**

Add to the SSE event contract table in `docs/sse-reconnect-plan.md`:

```
| show_preview | show_preview | tool preview pushed by agent |
```

- [ ] **Step 2: Commit**

```bash
git add docs/sse-reconnect-plan.md
git commit -m "docs: document show_preview SSE event"
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
   - show_preview tool appears in the LLM's tool list.
   - Live SSE banner appears briefly during a turn.
   - Persistent tool-result row renders the preview correctly.
   - Markdown is rendered via `marked`.
   - Code blocks have language hints.
   - Images (data URL or http URL) render inline.
   - Multi-preview per turn: each call gets its own row.
   - Reload preserves all previews via the existing `llm_history` path.

## Pitfalls to watch for

- **UTF-8 sanitization**: pass `sanitized_content` to the SSE event, not the raw input. Otherwise invalid bytes in tool stdout corrupt the JSON wire format (see project memory `zig-0.16-std-json-fmt-emits-invalid-utf8-as-array`).
- **preview_id collision**: use `unix_ms + random suffix`. Don't reuse timestamps.
- **Content type validation**: enforce the enum. The LLM sometimes hallucinates `"md"` or `"text/plain"`. Return a clear error.
- **Size cap**: enforce strictly. A 5 MB markdown will hang the renderer.
- **SSE listener cleanup**: ChatView's `disconnectSse` must `bus.off('show_preview', ...)` to avoid leaks across chat switches (matches the existing llm/queue listener pattern).
- **Lazy analysis in `zig build test`**: the `execShowPreview` test in Task 1.4 may not be reached by the test runner's module graph. Always also run `zig build install:linux:system` to verify the full graph compiles.
- **Zig 0.16 T → T const constraint**: when refactoring `execShowPreview` to return `T → !T`, the `result.output` field is implicitly const. Use `var result_owned = result;` then free via the owned copy.