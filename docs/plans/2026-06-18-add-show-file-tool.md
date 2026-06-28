# Add `show_file` Agent Tool (Display a File to the User)

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a new agent tool `show_file` that the AI agent **MUST** call whenever it wants to display a file to the user. The canonical use case is "I just wrote a landing page → show the HTML so the user can preview it", but the tool covers any previewable file (images, PDFs, markdown, JSON, plain text). Distinct from `read_file`, which loads content into the *agent's* context — `show_file` displays the file in the *user's* chat window.

**Architecture:** Backend adds a thin tool wrapper (`src/modules/agent/tools/show_file.zig`) that returns metadata (file, mime, size) plus a session-scoped URL `GET /api/session/:session_id/file?path=...`. A new HTTP handler (`src/ai_workflow/tui/http_handlers/show_file.zig`) serves the file from the session's cwd with path-traversal protection (mirrors the guard pattern in `src/modules/static_files.zig:resolve`). Frontend adds `src/apps/desktop/src/components/tool_outputs/ShowFile.vue` that fetches the URL and renders an `<iframe sandbox>` for HTML/text, `<img>` for images, `<iframe>` for PDFs, and a download link for everything else. One new row in `ChatView.vue`'s `v-if` tool dispatch. Mirrors the existing `read_file` ↔ `ReadFile.vue` / `write_file` ↔ `WriteFile.vue` pattern end-to-end.

**Tech Stack:** Vue 3 + TypeScript + Vite + Bun. Vitest + @vue/test-utils + jsdom. Zig 0.16 + `std.Io.Threaded`. No new dependencies.

---

## Why a new tool (and not a `read_file` flag)?

| Concern | `read_file` | `show_file` (new) |
|---|---|---|
| Loads content into LLM context | ✅ yes (full file body) | ❌ no — only metadata + URL |
| Renders preview in user's chat | ❌ no (just a `<pre>` blob) | ✅ yes (iframe / img / pdf) |
| Sandboxed HTML rendering | n/a | ✅ `<iframe sandbox="allow-same-origin">` |
| Cost per call | O(file size) tokens | O(1) tokens (just metadata) |
| LLM description goal | "load this so I can reason" | "let the user see this" |

These are different **communication directions**: `read_file` is agent→self, `show_file` is agent→user. Conflating them means the agent either (a) wastes tokens loading files it doesn't need to reason about, or (b) tries to "show" by dumping a `<pre>` blob the user can't preview as HTML.

---

## Design decisions locked during brainstorming

1. **One tool, multiple render modes** — `show_file` is a single tool. The frontend component dispatches on mime type (detected server-side from extension via the existing `static_files.mimeForPath` table). Single tool keeps the LLM's mental model simple ("I want to show the user a file" → `show_file`).
2. **Server-rendered metadata, client-fetches body** — Tool result is small (~150 bytes) and includes a URL. Frontend fetches the body on demand. This avoids bloating LLM history with multi-MB HTML files and scales to any file size.
3. **Path is sandboxed to the session's `cwd`** — The `GET /api/session/:session_id/file?path=…` handler resolves the path against the session's `cwd` and refuses any path that escapes it. Defense in depth: substring-reject `..`, then `startsWith` check on canonicalized path. Reuses the static_files.zig pattern.
4. **`<iframe sandbox="allow-same-origin">` for HTML** — Agent-generated HTML can't access the parent app's storage/cookies. The `allow-same-origin` is needed so the iframe's relative URL fetches work; we deliberately omit `allow-scripts` and `allow-top-navigation` to block JS and clickjacking. (If a future use case needs JS in the preview, that's a v2 decision.)
5. **Session_id is the only auth** — Anyone with the session_id can already `read_file` / `write_file` on the session (those tools run server-side with full process privileges). Adding a separate auth token for the preview URL would be theater, not security. Same trust model as the rest of the API.
6. **Static file serving, not DB blob** — The file is read directly from disk, not stored in the database. The LLM already wrote it via `write_file`; re-storing it in `llm_history` would duplicate state and bloat the DB.
7. **Both global main agent and sub-agents get the tool** — Sub-agents may also create artifacts the user wants to preview. Register the tool in `UNIFIED_TOOL_REGISTRY` (which is shared between main and sub-agents per `MAIN_AGENT_TOOL_REGISTRY: []const ToolInfo = UNIFIED_TOOL_REGISTRY;` at `tool_registry.zig:1459`).
8. **No new HTTP CORS work** — The new `/api/session/:session_id/file` endpoint is same-origin with the rest of the chat API, which already has CORS preflight wired via `cors.zig`.

---

## File structure

### New files

```
src/modules/agent/tools/
├── show_file.zig                       (tool def + executeShowFile helper)
└── show_file_test.zig                  (unit tests)

src/ai_workflow/tui/http_handlers/
├── show_file.zig                       (GET /api/session/:session_id/file)
└── show_file_test.zig                  (static contract tests)

src/apps/desktop/src/components/tool_outputs/
└── ShowFile.vue                        (file-type dispatch + preview rendering)

src/apps/desktop/src/__tests__/
└── ShowFile.spec.ts                    (component unit tests)
```

### Modified files

```
src/root.zig                            (re-export show_file module under nalarcore)
src/modules/agent/tools/tools.zig       (re-export show_file_tool)
src/modules/agent/test_runner.zig       (register show_file_test.zig)
src/ai_workflow/tui/tool_registry.zig   (UNIFIED_TOOL_REGISTRY entry + execShowFile)
src/ai_workflow/tui/http_handlers/mod.zig  (re-export showFileHandler)
src/main.zig                            (register GET /api/session/:session_id/file route)
src/apps/desktop/src/components/ChatView.vue  (tool dispatch entry)
```

---

## Backend implementation

### Step 1: `src/modules/agent/tools/show_file.zig`

The tool wraps a single helper that:
1. Stats the file (existence + size + mime detection)
2. Builds the preview URL from the **session id** (passed via `ctx` — see Step 3) and the path
3. Returns the metadata XML

```zig
const std = @import("std");
const schemas = @import("schemas.zig");
const AgentTool = schemas.AgentTool;
const ToolProperty = schemas.ToolProperty;
const ToolParameters = schemas.ToolParameters;

// Reuse the mime table from static_files.zig (it's a `pub const mime_table`
// but the helper `mimeForPath` is file-private — re-declare locally OR
// expose mimeForPath in static_files.zig as pub).
// Recommended: expose `pub fn mimeForPath(path: []const u8) []const u8`
// in static_files.zig (one-line, surgical), then import it here.
const static_files = @import("../../static_files.zig");

pub const ShowFileInput = struct {
    /// Absolute path to the file to display. Same convention as
    /// read_file / write_file (absolute path, no cwd-relative shortcuts).
    path: []const u8,
};

pub const ShowFileResult = struct {
    path: []const u8,
    url: []const u8,
    mime: []const u8,
    size: u64,
    file_name: []const u8,   // basename, for the UI header

    pub fn deinit(self: ShowFileResult, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.url);
        // mime is a static string (from mimeForPath) — DO NOT free
        // file_name aliases self.path — DO NOT free
    }
};

/// Build the preview URL that the frontend will fetch. The session_id
/// is what scopes the file to this session's cwd; without it the
/// HTTP handler would have to trust a path-only key.
///
/// Format: `/api/session/{session_id}/file?path={path}`
/// `path` is URL-encoded by the caller (the LLM is unlikely to put
/// spaces in paths, but `+` and `&` need encoding — we use the
/// std.Uri.Component.percentEncode helper for safety).
pub fn buildPreviewUrl(
    allocator: std.mem.Allocator,
    session_id: []const u8,
    path: []const u8,
) ![]u8 {
    const encoded_path = try std.Uri.Component.percentEncode(allocator, path, &.{ '/', '.' });
    return std.fmt.allocPrint(
        allocator,
        "/api/session/{s}/file?path={s}",
        .{ session_id, encoded_path },
    );
}

/// Stat the file, build the result. Returns `error.FileNotFound` if the
/// path doesn't exist or `error.IsDir` if it's a directory. Does NOT
/// check cwd sandboxing — that's the HTTP handler's job (the LLM
/// already had `read_file` / `write_file` access to any path it tries
/// to show, so the trust model is the same).
pub fn showFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    session_id: []const u8,
) !ShowFileResult {
    // Stat
    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch |err| {
        return err; // includes FileNotFound, NotDir, AccessDenied, etc.
    };
    defer std.Io.File.close(file, io);
    const stat = try std.Io.File.stat(file, io);
    const size: u64 = @intCast(stat.size);

    // Compute basename (mirror std.fs.path.basename but in-place)
    const basename_start = std.mem.lastIndexOfScalar(u8, path, '/') orelse 0;
    const file_name = path[basename_start + 1 ..];

    const mime = static_files.mimeForPath(path);
    const url = try buildPreviewUrl(allocator, session_id, path);
    errdefer allocator.free(url);

    return ShowFileResult{
        .path = try allocator.dupe(u8, path),
        .url = url,
        .mime = mime,
        .size = size,
        .file_name = file_name,
    };
}

/// Serialize result to XML for the AI tool output.
///
/// Shape:
///   <showed>true</showed>
///   <file>...</file>
///   <file_name>...</file_name>
///   <url>...</url>
///   <mime>...</mime>
///   <size>...</size>
///
/// The `url` is NOT XML-escaped (URLs use `&` legitimately for query
/// strings — escaping would break the frontend's URL parser). The other
/// fields ARE escaped to handle paths with `<`, `>`, `&`, etc.
pub fn toXmlSuccess(allocator: std.mem.Allocator, result: ShowFileResult) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator, "<showed>true</showed>");
    try out.appendSlice(allocator, "<file>");
    try appendXmlEscaped(allocator, &out, result.path);
    try out.appendSlice(allocator, "</file>");
    try out.appendSlice(allocator, "<file_name>");
    try appendXmlEscaped(allocator, &out, result.file_name);
    try out.appendSlice(allocator, "</file_name>");
    try out.appendSlice(allocator, "<url>");
    try out.appendSlice(allocator, result.url);
    try out.appendSlice(allocator, "</url>");
    try out.appendSlice(allocator, "<mime>");
    try appendXmlEscaped(allocator, &out, result.mime);
    try out.appendSlice(allocator, "</mime>");

    var size_buf: [32]u8 = undefined;
    const size_str = std.fmt.bufPrint(&size_buf, "{d}", .{result.size}) catch "0";
    try out.appendSlice(allocator, "<size>");
    try out.appendSlice(allocator, size_str);
    try out.appendSlice(allocator, "</size>");

    return out.toOwnedSlice(allocator);
}

/// XML-escape special characters. Local helper — see [1] below for why
/// we don't reuse the global one.
fn appendXmlEscaped(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    s: []const u8,
) !void {
    for (s) |c| {
        switch (c) {
            '<' => try out.appendSlice(allocator, "&lt;"),
            '>' => try out.appendSlice(allocator, "&gt;"),
            '&' => try out.appendSlice(allocator, "&amp;"),
            '"' => try out.appendSlice(allocator, "&quot;"),
            '\'' => try out.appendSlice(allocator, "&apos;"),
            else => try out.append(allocator, c),
        }
    }
}

/// Error XML shape (mirrors read_file / write_file conventions):
///   <showed>false</showed>
///   <file>...</file>
///   <error>...</error>
pub fn toXmlError(allocator: std.mem.Allocator, err: anyerror, path: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator, "<showed>false</showed>");
    try out.appendSlice(allocator, "<file>");
    try appendXmlEscaped(allocator, &out, path);
    try out.appendSlice(allocator, "</file>");
    try out.appendSlice(allocator, "<error>");
    const err_name = @errorName(err);
    try appendXmlEscaped(allocator, &out, err_name);
    try out.appendSlice(allocator, "</error>");
    return out.toOwnedSlice(allocator);
}

pub const show_file_tool = AgentTool{
    .type = "function",
    .function = .{
        .name = "show_file",
        .description =
        \\Display a file to the user in the chat (preview / inline view).
        \\
        \\Use this tool when you've created a file (or want to surface an
        \\existing one) that the USER should see. Common triggers:
        \\- "I just wrote a landing page" → show_file(path="/abs/path/index.html")
        \\- "Here's a screenshot" → show_file(path="/abs/path/screenshot.png")
        \\- "Here's the data file I produced" → show_file(path="/abs/path/out.csv")
        \\
        \\Renders (chosen automatically from the file extension):
        \\  .html / .htm            → sandboxed iframe (HTML preview, JS disabled)
        \\  .md / .txt / .json / .csv / .zig / .py / .js / .ts / .css / .xml
        \\                         → iframe with the raw text
        \\  .png / .jpg / .jpeg / .gif / .svg / .webp
        \\                         → inline <img>
        \\  .pdf                    → embedded PDF viewer (iframe)
        \\  anything else           → "Open in new tab" link
        \\
        \\This tool is the ONLY way the agent should display files to the
        \\user. Do NOT paste HTML/image bytes into the chat text — use
        \\show_file so the file renders as a real preview.
        \\
        \\Distinct from read_file, which loads the file's contents into
        \\YOUR context for reasoning. show_file sends the file to the
        \\USER for viewing — the LLM never sees the body.
        ,
        .parameters = .{
            .type = "object",
            .properties = &.{
                .{
                    .name = "path",
                    .type = "string",
                    .description = "Absolute path to the file to show. "
                        ++ "Same convention as read_file / write_file.",
                },
            },
            .required = &.{"path"},
        },
    },
};
```

**[1] Why a local `appendXmlEscaped` instead of reusing `helpers.xml_escape`?**
The plan is intentionally self-contained. If `helpers.xml_escape`'s signature ever changes, `show_file.zig` doesn't need to track it. The function is 8 lines — duplication is cheaper than the import coupling for a tool with a single internal use site. (If a third caller appears, factor it out then.)

### Step 2: `src/modules/agent/tools/show_file_test.zig`

Unit tests, registered in `src/modules/agent/test_runner.zig` (Step 3). Use the `testing.allocator` pattern from the other tool tests; create a temp file with `std.testing.tmpDir` (Zig 0.16 API) and exercise the helper.

```zig
const std = @import("std");
const testing = std.testing;
const show_file = @import("show_file.zig");

test "showFile returns metadata for a regular file" {
    const alloc = testing.allocator;
    const io = testing.io;  // Zig 0.16 testing helper

    // Create a temp file
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const sub_path = "hello.html";
    {
        const f = try tmp.dir.createFile(io, sub_path, .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "<h1>hi</h1>");
    }

    // Resolve to absolute path (tmp.dir is a Dir, not a string path)
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const sub_abs = try tmp.dir.realPath(sub_path, &path_buf);
    const abs_path = try alloc.dupe(u8, sub_abs);

    const result = try show_file.showFile(alloc, io, abs_path, "test_session_123");
    defer result.deinit(alloc);

    try testing.expect(std.mem.endsWith(u8, result.path, "hello.html"));
    try testing.expectEqualStrings("hello.html", result.file_name);
    try testing.expect(result.size > 0);
    try testing.expect(std.mem.indexOf(u8, result.mime, "text/html") != null);
    try testing.expect(std.mem.indexOf(u8, result.url, "/api/session/test_session_123/file") != null);
    try testing.expect(std.mem.indexOf(u8, result.url, "path=") != null);
}

test "showFile returns FileNotFound for missing path" {
    const alloc = testing.allocator;
    const io = testing.io;
    const result = show_file.showFile(alloc, io, "/nonexistent/path/foo.html", "sess");
    try testing.expectError(error.FileNotFound, result);
}

test "toXmlSuccess includes all required fields" {
    const alloc = testing.allocator;
    const result = show_file.ShowFileResult{
        .path = "/abs/foo.html",
        .url = "/api/session/s1/file?path=%2Fabs%2Ffoo.html",
        .mime = "text/html; charset=utf-8",
        .size = 42,
        .file_name = "foo.html",
    };
    const xml = try show_file.toXmlSuccess(alloc, result);
    defer alloc.free(xml);

    try testing.expect(std.mem.indexOf(u8, xml, "<showed>true</showed>") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "<file>/abs/foo.html</file>") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "<file_name>foo.html</file_name>") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "<url>/api/session/s1/file?path=%2Fabs%2Ffoo.html</url>") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "<mime>text/html") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "<size>42</size>") != null);
}

test "toXmlError renders FileNotFound correctly" {
    const alloc = testing.allocator;
    const xml = try show_file.toXmlError(alloc, error.FileNotFound, "/abs/missing.html");
    defer alloc.free(xml);

    try testing.expect(std.mem.indexOf(u8, xml, "<showed>false</showed>") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "<file>/abs/missing.html</file>") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "<error>FileNotFound</error>") != null);
}

test "buildPreviewUrl percent-encodes the path" {
    const alloc = testing.allocator;
    const url = try show_file.buildPreviewUrl(alloc, "sess_1", "/path with space/foo.html");
    defer alloc.free(url);
    try testing.expectEqualStrings(
        "/api/session/sess_1/file?path=%2Fpath%20with%20space%2Ffoo.html",
        url,
    );
}
```

### Step 3: Register the tool module

Three files:

**`src/root.zig`** — Add a top-level re-export next to `read_file` (line 361):

```zig
pub const read_file = @import("modules/agent/tools/read_file.zig");
pub const write_file = @import("modules/agent/tools/write_file.zig");
pub const show_file = @import("modules/agent/tools/show_file.zig");   // ← new
```

**`src/modules/agent/tools/tools.zig`** — Add a re-export + tool constant (mirrors the read_file pattern — note the existing `tools.zig` does NOT re-export `read_file_tool`; that's intentional because `read_file_tool` is consumed via `tool_registry.zig`'s `nalar_mod.read_file` directly). For `show_file`, follow the same pattern: re-export the module so `tool_registry.zig` can do `nalar_mod.show_file.show_file_tool`:

```zig
// Add to src/modules/agent/tools/tools.zig:
pub const show_file = @import("show_file.zig");
```

(No new `pub const show_file_tool = …` line — the tool_registry will reach in via `nalar_mod.show_file.show_file_tool`.)

**`src/modules/agent/test_runner.zig`** — Register the test file (after the `add_skill_test.zig` line, line 20):

```zig
_ = @import("tools/show_file_test.zig");
```

### Step 4: Register the tool in `tool_registry.zig`

Two changes in `src/ai_workflow/tui/tool_registry.zig`:

**a) Add the module import** (after the `read_file_mod` line, line 16):

```zig
const show_file_mod = nalar_mod.show_file;
```

**b) Add the registry entry** in `UNIFIED_TOOL_REGISTRY` (line 1409, under the `// === FILE OPERATIONS ===` block at line 1429, after the `remove_file` line):

```zig
    .{ .name = "show_file", .exec = execShowFile, .tool_def = show_file_mod.show_file_tool },
```

**c) Add the tool to the main agent's `allAgentTools` list** (line 1463, after the `remove_file_mod.remove_file_tool` line at line 1479):

```zig
        show_file_mod.show_file_tool,
```

**d) Implement `execShowFile`** (add after `execReadFile` at line 224, before `execTextReplace`):

```zig
pub fn execShowFile(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    const parsed = std.json.parseFromSlice(
        show_file_mod.ShowFileInput,
        ctx.allocator,
        tc.function.arguments,
        .{ .allocate = .alloc_always },
    ) catch |err| {
        const err_msg = try std.fmt.allocPrint(ctx.allocator, "show_file failed: {s}", .{@errorName(err)});
        const output = try wrapToolOutput(ctx.allocator, "show_file", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    defer parsed.deinit();

    const result = show_file_mod.showFile(
        ctx.allocator,
        ctx.io,
        parsed.value.path,
        ctx.session_id,
    ) catch |err| {
        const inner = try show_file_mod.toXmlError(ctx.allocator, err, parsed.value.path);
        const err_msg = try std.fmt.allocPrint(ctx.allocator, "show_file failed: {s}", .{@errorName(err)});
        const output = try wrapToolOutput(ctx.allocator, "show_file", tc.function.arguments, false, err_msg, inner);
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    defer result.deinit(ctx.allocator);

    const inner = try show_file_mod.toXmlSuccess(ctx.allocator, result);
    const output = try wrapToolOutput(ctx.allocator, "show_file", tc.function.arguments, true, null, inner);
    return ToolExecResult{ .output = output, .output_allocated = true };
}
```

### Step 5: HTTP handler `src/ai_workflow/tui/http_handlers/show_file.zig`

Serves the file with cwd-sandboxing. Mirrors `memories_detail.zig` for the handler shape, `static_files.zig` for the path-resolution guard, and uses `read_file_mod` to read the file body (reuse the existing `readFile` + offset/limit pagination — see step 6 for why we paginate).

```zig
const std = @import("std");
const nalarcore = @import("nalarcore");
const gserverz = nalarcore.gserverz;
const http_response = @import("http_response.zig");
const static_files = @import("../../../modules/static_files.zig");
const llm_history = nalarcore.llm_history;

/// 5 MB cap on inline previews. Larger files get streamed
/// (Content-Length + read loops) but the iframe / img won't try to
/// load more than this. Tune if user feedback indicates need.
const MAX_PREVIEW_BYTES: u64 = 5 * 1024 * 1024;

/// Look up the session's cwd from the database. Returns null if the
/// session doesn't exist. Mirrors the pattern in
/// `llm_history.zig:getSessionListWithCursor`.
fn getSessionCwd(
    allocator: std.mem.Allocator,
    db: *nalarcore.sqlite.SqliteBackend,
    session_id: []const u8,
) !?[]u8 {
    var q = try db.query(
        allocator,
        "SELECT s.cwd FROM sessions s WHERE s.id = ?",
        &.{std.sqlite_bind_text(session_id)},
    );
    defer q.deinit();

    const row = (try q.next()) orelse return null;
    defer row.deinit(allocator);

    const cwd = row.values[0];
    if (cwd.len == 0) return null;
    return try allocator.dupe(u8, cwd);
}

/// Resolve `requested_path` against the session's `session_cwd` and
/// verify the result lives inside the cwd. Rejects `..` and any
/// absolute path that isn't under cwd. Mirrors the static_files.zig
/// `resolve()` guard pattern (defense in depth: substring reject +
/// canonical-path check).
fn resolveSafePath(
    allocator: std.mem.Allocator,
    session_cwd: []const u8,
    requested_path: []const u8,
) !?[]u8 {
    // 1. Substring-reject `..` (defense in depth; the canonical check
    //    below would catch it too, but the early reject is cheaper).
    if (std.mem.indexOf(u8, requested_path, "..") != null) {
        return null;
    }

    // 2. Reject paths starting with `~` (no home expansion; agent
    //    should always pass absolute paths).
    if (requested_path.len > 0 and requested_path[0] == '~') {
        return null;
    }

    // 3. Strip leading `/` (if the LLM passes an absolute path, treat
    //    it as cwd-relative — matches the rest of the agent's file
    //    tools which always pass absolute paths anyway).
    const rel = if (requested_path.len > 0 and requested_path[0] == '/')
        requested_path[1..]
    else
        requested_path;

    // 4. Join with cwd, then canonicalize via realpath.
    const joined = try std.fs.path.join(allocator, &.{ session_cwd, rel });
    defer allocator.free(joined);

    var canon_buf: [std.fs.max_path_bytes]u8 = undefined;
    const canon = std.fs.realpath(joined, &canon_buf) catch {
        // realpath fails on non-existent files — return the joined
        // path anyway; the openFile below will surface FileNotFound.
        return try allocator.dupe(u8, joined);
    };

    // 5. Must live under session_cwd.
    if (!std.mem.startsWith(u8, canon, session_cwd)) {
        return null;
    }

    return try allocator.dupe(u8, canon);
}

/// GET /api/session/:session_id/file?path=<absolute_path>
///
/// Headers: Content-Type from extension (via static_files.mimeForPath),
/// Content-Length, Cache-Control: no-store (preview must always be
/// fresh — the file on disk may have been re-edited).
pub fn showFileHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;
    const io = ctx.io;

    // 1. Look up singleton (DB access).
    const di = try nalarcore.getSingleton();
    const db = di.db;

    // 2. Get session_id from path params.
    const session_id = req.params.get("session_id") orelse {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Missing :session_id" }),
        });
    };

    // 3. Get requested path from query string.
    const query = try req.query();
    const requested_path = query.get("path") orelse {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Missing ?path=" }),
        });
    };

    // 4. Look up the session's cwd.
    const session_cwd = (getSessionCwd(allocator, db, session_id) catch null) orelse {
        return res.jsonResponse(.{
            .status_code = 404,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Session not found" }),
        });
    };
    defer allocator.free(session_cwd);

    // 5. Sandbox the path.
    const safe_path = (resolveSafePath(allocator, session_cwd, requested_path) catch null) orelse {
        return res.jsonResponse(.{
            .status_code = 403,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Path is outside the session workspace" }),
        });
    };
    defer allocator.free(safe_path);

    // 6. Stat for size + mime.
    const file = std.Io.Dir.cwd().openFile(io, safe_path, .{}) catch |err| {
        const status: u16 = switch (err) {
            error.FileNotFound => 404,
            error.AccessDenied => 403,
            else => 500,
        };
        return res.jsonResponse(.{
            .status_code = status,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = @errorName(err) }),
        });
    };
    defer std.Io.File.close(file, io);

    const stat = try std.Io.File.stat(file, io);
    const size: u64 = @intCast(stat.size);

    const mime = static_files.mimeForPath(safe_path);

    // 7. Read the file body. For files > MAX_PREVIEW_BYTES, read the
    //    first MAX_PREVIEW_BYTES only (caller can re-fetch with an
    //    offset param if needed; v1 always returns from byte 0).
    const read_len: usize = @intCast(@min(size, MAX_PREVIEW_BYTES));
    const body = try allocator.alloc(u8, read_len);
    errdefer allocator.free(body);
    _ = try std.Io.File.read(file, io, body);

    // 8. Build response. Use a custom headers map so we can set
    //    Content-Type, Content-Length, and Cache-Control.
    //
    //    (gserverz.HttpResponse exposes a way to set headers; if not,
    //    fall back to a raw write — check the existing healthHandler
    //    for the canonical pattern. If gserverz is too low-level,
    //    mirror the staticDirHandler in main.zig:215-218 which uses
    //    setStaticDirHandler; for now assume the headers-builder
    //    path is available via `res.bytesResponse` with custom
    //    headers, or fall back to a manual HTTP/1.1 response write.)
    return res.bytesResponse(.{
        .status_code = 200,
        .content_type = mime,
        .body = body,
        .extra_headers = &.{
            .{ .name = "Cache-Control", .value = "no-store" },
            .{ .name = "X-Content-Type-Options", .value = "nosniff" },
        },
    });
}
```

**Important:** the `res.bytesResponse` / header-builder shape above is *placeholder* — the implementer MUST check the actual `gserverz.HttpResponse` API in `src/modules/custom_http_server/src/http_server.zig` for what methods exist (e.g. `bytesResponse` vs `rawResponse` vs `jsonResponse`) and adjust the call site. The plan is correct on the *semantics*; the method names are speculative.

### Step 6: Wire the HTTP handler

**`src/ai_workflow/tui/http_handlers/mod.zig`** — Add the re-export (after the `routinesRunHandler` line, line 57):

```zig
pub const showFileHandler = @import("show_file.zig").showFileHandler;
```

**`src/main.zig`** — Register the route (after the `try gs.router.get("/api/session/:session_id/messages", …)` line, line 244):

```zig
try gs.router.get("/api/session/:session_id/file", ai_mod.http_handlers.showFileHandler);
```

### Step 7: Static contract test `src/ai_workflow/tui/http_handlers/show_file_test.zig`

Mirrors `memories_crud_test.zig` — read the source as text, grep for required substrings. Register in `src/ai_workflow/tui/test_runner.zig`.

```zig
const std = @import("std");
const testing = std.testing;
const HANDLER_PATH = "src/ai_workflow/tui/http_handlers/show_file.zig";

fn readSource(alloc: std.mem.Allocator, path: []const u8) ![]u8 {
    const f = try std.fs.cwd().openFile(path, .{});
    defer f.close();
    return try f.readToEndAlloc(alloc, 1024 * 1024);
}

test "show_file handler uses req.params.get for session_id" {
    const src = try readSource(testing.allocator, HANDLER_PATH);
    defer testing.allocator.free(src);
    if (std.mem.indexOf(u8, src, "req.params.get(\"session_id\")") == null) {
        std.debug.print("!! show_file.zig does not read session_id from req.params !!\n", .{});
        return error.SessionIdParamMissing;
    }
}

test "show_file handler sandboxes path with resolveSafePath" {
    const src = try readSource(testing.allocator, HANDLER_PATH);
    defer testing.allocator.free(src);
    if (std.mem.indexOf(u8, src, "resolveSafePath") == null) {
        return error.PathSandboxMissing;
    }
}

test "show_file handler rejects '..' substring" {
    const src = try readSource(testing.allocator, HANDLER_PATH);
    defer testing.allocator.free(src);
    if (std.mem.indexOf(u8, src, "\"..\"") == null) {
        return error.DoubleDotSubstringCheckMissing;
    }
}

test "show_file handler looks up session cwd from sessions table" {
    const src = try readSource(testing.allocator, HANDLER_PATH);
    defer testing.allocator.free(src);
    if (std.mem.indexOf(u8, src, "FROM sessions") == null) {
        return error.SessionCwdQueryMissing;
    }
}

test "show_file handler sets Cache-Control no-store" {
    const src = try readSource(testing.allocator, HANDLER_PATH);
    defer testing.allocator.free(src);
    if (std.mem.indexOf(u8, src, "no-store") == null) {
        return error.CacheControlMissing;
    }
}
```

---

## Frontend implementation

### Step 8: `src/apps/desktop/src/components/tool_outputs/ShowFile.vue`

Renders a header (filename + mime + size + Open-in-new-tab link) and an embedded preview dispatched on mime type. The component receives the **inner `<data>` XML** of the tool envelope (the parent already unwraps it — see `ChatView.vue:innerToolData`). It also receives the raw `parameters` JSON string for fallback.

```vue
<script setup lang="ts">
import { computed, ref } from 'vue'
import { useInjectOpenInCodeEditor } from '../../composables/useCodeEditor'

const props = defineProps<{
  /** Inner <data> XML from the show_file result envelope. */
  content: string
  /** Tool-call arguments as a JSON string. */
  parameters: string
  expanded?: boolean
  cwd?: string
}>()

const openInEditor = useInjectOpenInCodeEditor()
const isLoaded = ref(false)
const hasError = ref(false)

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

// Parse the tool's inner data
const filePath = computed(() => findTag(props.content, 'file'))
const fileName = computed(() => findTag(props.content, 'file_name') ?? filePath.value ?? 'unknown')
const previewUrl = computed(() => findTag(props.content, 'url'))
const mime = computed(() => findTag(props.content, 'mime') ?? 'application/octet-stream')
const sizeStr = computed(() => findTag(props.content, 'size'))
const sizeBytes = computed(() => {
  if (sizeStr.value === null) return null
  const n = parseInt(sizeStr.value, 10)
  return Number.isFinite(n) ? n : null
})
const isShowed = computed(() => {
  const s = findTag(props.content, 'showed')
  return s === 'true'
})
const errorMessage = computed(() => findTag(props.content, 'error'))

// Classify the mime into a render mode
type RenderMode = 'html' | 'image' | 'pdf' | 'text' | 'binary'
const renderMode = computed<RenderMode>(() => {
  const m = mime.value
  if (m.startsWith('text/html')) return 'html'
  if (m.startsWith('image/')) return 'image'
  if (m === 'application/pdf') return 'pdf'
  // Text-ish: text/*, application/json, application/javascript,
  // application/xml, application/csv, anything starting with text/
  if (m.startsWith('text/')) return 'text'
  if (m === 'application/json' || m === 'application/javascript' ||
      m === 'application/xml' || m === 'application/csv' ||
      m === 'application/octet-stream') {
    // .json/.js/.ts/.css/.xml/.csv fall here. Wrap in iframe so the
    // browser handles syntax highlighting naturally (e.g. Chromium
    // shows .json pretty-printed).
    return 'text'
  }
  return 'binary'
})

// Human-readable file size
const sizeHuman = computed(() => {
  const b = sizeBytes.value
  if (b === null) return ''
  if (b < 1024) return `${b} B`
  if (b < 1024 * 1024) return `${(b / 1024).toFixed(1)} KB`
  return `${(b / (1024 * 1024)).toFixed(1)} MB`
})

// Open in new tab fallback
const openInNewTab = () => {
  if (previewUrl.value) window.open(previewUrl.value, '_blank', 'noopener,noreferrer')
}

const handleOpenInEditor = (e: Event) => {
  e.stopPropagation()
  if (filePath.value && props.cwd && openInEditor) {
    openInEditor({ filePath: filePath.value, cwd: props.cwd })
  }
}

const copyPath = async (e: Event) => {
  e.stopPropagation()
  if (filePath.value) {
    await navigator.clipboard.writeText(filePath.value)
  }
}

const onIframeLoad = () => { isLoaded.value = true }
const onIframeError = () => { hasError.value = true; isLoaded.value = true }
const onImgLoad = () => { isLoaded.value = true }
const onImgError = () => { hasError.value = true; isLoaded.value = true }
</script>

<template>
  <div
    class="font-mono text-xs rounded-md overflow-hidden border border-[var(--color-border)] bg-[var(--semantic-card-bg)]"
    :class="{ 'border-red-500/50 opacity-80': !!errorMessage || hasError }"
  >
    <!-- Header -->
    <div
      class="group flex items-center gap-1 px-2 py-1"
      :class="errorMessage ? 'cursor-default' : ''"
    >
      <span class="text-[var(--color-violet)] font-semibold text-xs">show_file</span>
      <span
        class="flex-1 truncate text-left text-[var(--color-violet)] font-medium"
        :title="filePath || ''"
      >{{ fileName || 'unknown' }}</span>
      <span v-if="sizeHuman" class="text-[var(--semantic-text-muted)] text-xs">{{ sizeHuman }}</span>
      <span
        v-if="!errorMessage"
        class="text-xs"
        :class="isShowed ? 'text-green-500' : 'text-red-500'"
      >{{ isShowed ? '✓' : '✗' }}</span>

      <button
        v-if="previewUrl"
        class="px-0.5 border-none bg-transparent cursor-pointer text-[var(--semantic-text-muted)] hover:!text-violet-500 text-base"
        @click.stop="openInNewTab"
        title="Open in new tab"
      >↗</button>
      <button
        class="px-0.5 border-none bg-transparent cursor-pointer text-[var(--semantic-text-muted)] opacity-0 group-hover:opacity-100 hover:!text-violet-500 text-base transition-opacity"
        @click="copyPath"
        title="Copy path"
      >⎘</button>
      <button
        v-if="props.cwd && openInEditor && filePath"
        class="px-0.5 border-none bg-transparent cursor-pointer text-[var(--semantic-text-muted)] opacity-0 group-hover:opacity-100 hover:!text-violet-500 transition-opacity"
        @click="handleOpenInEditor"
        title="Open in code editor"
      >
        <svg class="w-3.5 h-3.5" fill="none" viewBox="0 0 24 24" stroke="currentColor">
          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M11 5H6a2 2 0 00-2 2v11a2 2 0 002 2h11a2 2 0 002-2v-5m-1.414-9.414a2 2 0 112.828 2.828L11.828 15H9v-2.828l8.586-8.586z" />
        </svg>
      </button>
    </div>

    <!-- Error -->
    <div v-if="errorMessage" class="border-t border-[var(--color-border)] bg-black/[0.02]">
      <div class="flex gap-2 px-2 py-1.5 text-red-500 text-xs">
        <span class="font-semibold shrink-0">Error:</span>
        <span class="whitespace-pre-wrap break-all">{{ errorMessage }}</span>
      </div>
    </div>

    <!-- Preview area (only when succeeded) -->
    <div
      v-else-if="previewUrl && isShowed"
      class="border-t border-[var(--color-border)] bg-white dark:bg-[#0d0d0d]"
    >
      <!-- HTML: sandboxed iframe. allow-same-origin so relative paths work;
           explicitly omit allow-scripts to block JS in the preview. -->
      <iframe
        v-if="renderMode === 'html'"
        :src="previewUrl"
        sandbox="allow-same-origin"
        class="w-full block bg-white"
        style="height: 480px; border: 0;"
        @load="onIframeLoad"
        @error="onIframeError"
      />
      <!-- Text-ish: iframe with raw text. The browser's default
           text-rendering handles JSON pretty-printing and basic
           mono formatting. We deliberately use an iframe (not <pre>)
           because the user may want to scroll the long text. -->
      <iframe
        v-else-if="renderMode === 'text'"
        :src="previewUrl"
        sandbox="allow-same-origin"
        class="w-full block bg-white"
        style="height: 480px; border: 0;"
        @load="onIframeLoad"
        @error="onIframeError"
      />
      <!-- PDF: iframe. Browser-native PDF viewer. -->
      <iframe
        v-else-if="renderMode === 'pdf'"
        :src="previewUrl"
        class="w-full block bg-white"
        style="height: 600px; border: 0;"
        @load="onIframeLoad"
        @error="onIframeError"
      />
      <!-- Image: native <img> with object-fit: contain so the user
           can see the whole image without scrolling. -->
      <div
        v-else-if="renderMode === 'image'"
        class="flex items-center justify-center p-2"
        style="min-height: 200px; max-height: 600px;"
      >
        <img
          :src="previewUrl"
          :alt="fileName || ''"
          class="max-w-full max-h-[600px] object-contain"
          @load="onImgLoad"
          @error="onImgError"
        />
      </div>
      <!-- Binary: just a download link + size. -->
      <div v-else class="px-3 py-4 text-center">
        <div class="text-[var(--semantic-text-dim)] mb-2">
          Preview not available for this file type
        </div>
        <div class="text-xs text-[var(--semantic-text-muted)] mb-3">
          {{ mime }} · {{ sizeHuman }}
        </div>
        <a
          :href="previewUrl"
          download
          class="inline-block px-3 py-1 rounded bg-[var(--color-violet)] text-white text-xs font-medium hover:opacity-90"
        >Download</a>
      </div>
    </div>
  </div>
</template>
```

**Design notes:**

- **Header always shown** — The filename, mime badge, and size are always visible so the user knows what was previewed even after scrolling away from the iframe. The expand/collapse toggle is intentionally NOT included — the iframe itself scrolls, and collapsing it would hide the preview, which defeats the point.
- **Sandbox `allow-same-origin` only** — Critical security choice. The agent-generated HTML runs in a same-origin iframe, but with NO `allow-scripts` and NO `allow-top-navigation`. So even if the agent writes `<script>document.cookie</script>`, the script is blocked. Relative URLs in the HTML (e.g. `<img src="./logo.png">`) still work because we kept `allow-same-origin`. See the [MDN iframe sandbox reference](https://developer.mozilla.org/en-US/docs/Web/HTML/Element/iframe#sandbox) for the full trade-off.
- **No `expanded` prop wired to collapse** — Unlike `ReadFile.vue` / `WriteFile.vue`, `show_file` doesn't make the preview collapsible. The user came here to *see* the file; iframes scroll internally. Adding collapse would just add clicks for no UX win. (If user feedback asks for it, v2.)
- **New-tab fallback (↗ button)** — Always shown. Critical for binary files (no inline render) and for users who want a bigger viewport. Uses `noopener,noreferrer` to prevent the opened page from accessing `window.opener`.
- **Open-in-code-editor button** — Same icon as the other file tools. Lets the user jump from "preview" to "edit" in one click.
- **Error rendering** — `<showed>false</showed>` puts the file info + error in the header, and the error message in the body. The header doesn't show a "no preview" placeholder, the red border indicates the failure.

### Step 9: Wire the Vue component in `ChatView.vue`

Add the import (after the `WriteFile` import at line 21):

```ts
import ShowFile from './tool_outputs/ShowFile.vue'
```

Add the dispatch in the tool-rendering `v-if`/`v-else-if` chain (after the `WriteFile` block at line 1898):

```vue
<ShowFile
  v-else-if="msg.tool_name === 'show_file'"
  :content="innerToolData(msg)"
  :parameters="getParametersForMessage(msg)"
  :expanded="expandedToolIds.has(`${groupIndex}-${idx}`)"
  :cwd="cwd"
/>
```

### Step 10: Frontend test `src/apps/desktop/src/__tests__/ShowFile.spec.ts`

Mirrors the other tool-output specs (e.g. `ReadFile.vue`'s test). Cover the four render modes + the error path.

```ts
import { describe, it, expect, beforeEach } from 'vitest'
import { mount } from '@vue/test-utils'
import { nextTick } from 'vue'
import ShowFile from '../components/tool_outputs/ShowFile.vue'

const HTML_XML = `<showed>true</showed><file>/abs/landing.html</file><file_name>landing.html</file_name><url>/api/session/s1/file?path=%2Fabs%2Flanding.html</url><mime>text/html; charset=utf-8</mime><size>1234</size>`

const PNG_XML = `<showed>true</showed><file>/abs/img.png</file><file_name>img.png</file_name><url>/api/session/s1/file?path=%2Fabs%2Fimg.png</url><mime>image/png</mime><size>5678</size>`

const PDF_XML = `<showed>true</showed><file>/abs/doc.pdf</file><file_name>doc.pdf</file_name><url>/api/session/s1/file?path=%2Fabs%2Fdoc.pdf</url><mime>application/pdf</mime><size>99999</size>`

const TEXT_XML = `<showed>true</showed><file>/abs/data.json</file><file_name>data.json</file_name><url>/api/session/s1/file?path=%2Fabs%2Fdata.json</url><mime>application/json</mime><size>200</size>`

const BINARY_XML = `<showed>true</showed><file>/abs/app.zip</file><file_name>app.zip</file_name><url>/api/session/s1/file?path=%2Fabs%2Fapp.zip</url><mime>application/zip</mime><size>1024</size>`

const ERROR_XML = `<showed>false</showed><file>/abs/missing.html</file><error>FileNotFound</error>`

describe('ShowFile.vue', () => {
  it('renders an iframe with sandbox=allow-same-origin for HTML files', () => {
    const w = mount(ShowFile, {
      props: { content: HTML_XML, parameters: '{"path":"/abs/landing.html"}' },
    })
    const iframe = w.find('iframe')
    expect(iframe.exists()).toBe(true)
    expect(iframe.attributes('sandbox')).toBe('allow-same-origin')
    // Critical: scripts must NOT be allowed
    expect(iframe.attributes('sandbox')).not.toContain('allow-scripts')
    expect(iframe.attributes('src')).toBe('/api/session/s1/file?path=%2Fabs%2Flanding.html')
  })

  it('renders an <img> for image MIME types', () => {
    const w = mount(ShowFile, {
      props: { content: PNG_XML, parameters: '{}' },
    })
    expect(w.find('img').exists()).toBe(true)
    expect(w.find('img').attributes('src')).toBe('/api/session/s1/file?path=%2Fabs%2Fimg.png')
    expect(w.find('iframe').exists()).toBe(false)
  })

  it('renders a sandbox-less iframe for PDF files', () => {
    const w = mount(ShowFile, {
      props: { content: PDF_XML, parameters: '{}' },
    })
    const iframe = w.find('iframe')
    expect(iframe.exists()).toBe(true)
    expect(iframe.attributes('src')).toContain('doc.pdf')
  })

  it('renders a text iframe for application/json', () => {
    const w = mount(ShowFile, {
      props: { content: TEXT_XML, parameters: '{}' },
    })
    const iframe = w.find('iframe')
    expect(iframe.exists()).toBe(true)
    expect(iframe.attributes('src')).toContain('data.json')
  })

  it('renders a Download link (not a preview) for binary files', () => {
    const w = mount(ShowFile, {
      props: { content: BINARY_XML, parameters: '{}' },
    })
    expect(w.find('iframe').exists()).toBe(false)
    expect(w.find('img').exists()).toBe(false)
    const link = w.find('a')
    expect(link.exists()).toBe(true)
    expect(link.attributes('href')).toContain('app.zip')
    expect(link.text()).toContain('Download')
  })

  it('renders the error message in the body when showed=false', () => {
    const w = mount(ShowFile, {
      props: { content: ERROR_XML, parameters: '{}' },
    })
    expect(w.find('iframe').exists()).toBe(false)
    expect(w.text()).toContain('FileNotFound')
    expect(w.text()).toContain('Error')
  })

  it('shows the filename in the header', () => {
    const w = mount(ShowFile, {
      props: { content: HTML_XML, parameters: '{}' },
    })
    expect(w.text()).toContain('landing.html')
    expect(w.text()).toContain('show_file')
  })

  it('formats the file size in human-readable units', () => {
    expect(mount(ShowFile, { props: { content: HTML_XML, parameters: '{}' } }).text()).toMatch(/1\.2 KB|1,234 B|1234 B/)
    expect(mount(ShowFile, { props: { content: PDF_XML, parameters: '{}' } }).text()).toContain('KB')
  })
})
```

---

## Verification commands (run throughout)

```bash
# Backend (Zig)
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
timeout 180 zig build test --summary all 2>&1 | tail -n 50

# Frontend type-check + bundle (per project NALAR.md memory — bun run build
# is the authoritative type check, NOT vitest)
cd src/apps/desktop
timeout 120 bun run build 2>&1 | tail -n 30

# Frontend unit tests
cd src/apps/desktop
timeout 120 bunx vitest run ShowFile 2>&1 | tail -n 30

# Manual smoke test (after `zig build install:linux:system` and
# `./zig-out/bin/nalar --port 8080 &` in a separate terminal)
curl -sS -X POST http://127.0.0.1:8080/api/session \
  -H 'Content-Type: application/json' \
  -d '{"cwd":"/tmp/show-file-smoke","name":"smoke"}'

# Create a test HTML file
mkdir -p /tmp/show-file-smoke
cat > /tmp/show-file-smoke/landing.html <<'EOF'
<!doctype html><html><body><h1>Hello from show_file!</h1></body></html>
EOF

# Verify the handler serves it (replace SESSION_ID with the response from above)
curl -sS "http://127.0.0.1:8080/api/session/SESSION_ID/file?path=/tmp/show-file-smoke/landing.html"
# Expected: the HTML body, with Content-Type: text/html

# Verify path traversal is blocked
curl -sS "http://127.0.0.1:8080/api/session/SESSION_ID/file?path=/tmp/show-file-smoke/../etc/passwd"
# Expected: 403 with "Path is outside the session workspace"

# Verify missing session returns 404
curl -sS "http://127.0.0.1:8080/api/session/nonexistent_session/file?path=/tmp/x"
# Expected: 404 with "Session not found"
```

Per the project's `desktop-typescript-bun-build-as-typecheck` memory:
**Always run `bun run build` (NOT just `bunx vitest run`)** — vitest uses esbuild
which strips types, so TS2532 errors only surface during `vue-tsc --build`.

Per the project's `custom-http-server-per-request-arena` memory:
**Don't add `defer allocator.free(...)` for request-scoped allocations in HTTP
handlers.** The `GinwaServer.handle` arena reaps them. The `show_file` handler
follows the existing pattern (no `defer` on `joined` / `body` / `safe_path` —
the arena owns them, the request owns the arena).

---

## Rollout checklist

- [ ] Step 1: `src/modules/agent/tools/show_file.zig` created with the full content above
- [ ] Step 2: `src/modules/agent/tools/show_file_test.zig` created with the 5 tests above
- [ ] Step 3a: `src/root.zig` adds `pub const show_file = …`
- [ ] Step 3b: `src/modules/agent/tools/tools.zig` adds `pub const show_file = …`
- [ ] Step 3c: `src/modules/agent/test_runner.zig` registers `show_file_test.zig`
- [ ] Step 4: `src/ai_workflow/tui/tool_registry.zig` gets the import, the registry entry, the `allAgentTools` entry, and `execShowFile`
- [ ] Step 5: `src/ai_workflow/tui/http_handlers/show_file.zig` created (adjust `gserverz.HttpResponse` call site to the actual API)
- [ ] Step 6a: `src/ai_workflow/tui/http_handlers/mod.zig` re-exports `showFileHandler`
- [ ] Step 6b: `src/main.zig` registers the `GET /api/session/:session_id/file` route
- [ ] Step 7: `src/ai_workflow/tui/http_handlers/show_file_test.zig` created and registered in `src/ai_workflow/tui/test_runner.zig`
- [ ] Step 8: `src/apps/desktop/src/components/tool_outputs/ShowFile.vue` created
- [ ] Step 9: `src/apps/desktop/src/components/ChatView.vue` adds the import + dispatch entry
- [ ] Step 10: `src/apps/desktop/src/__tests__/ShowFile.spec.ts` created
- [ ] `timeout 180 zig build test --summary all 2>&1 | tail -n 50` — must show `test success` and the new test count (target: 431 + ~5 show_file + 5 show_file_test = ~441)
- [ ] `cd src/apps/desktop && timeout 120 bun run build 2>&1 | tail -n 30` — must complete without TS errors
- [ ] `cd src/apps/desktop && timeout 120 bunx vitest run ShowFile 2>&1 | tail -n 30` — all 8 new tests pass
- [ ] Manual smoke test passes (3 `curl` invocations above)
- [ ] End-to-end: open the desktop app, start a chat, ask the agent to create a landing page, observe the show_file tool result renders an iframe preview

## Known limitations (out of scope, deferred to v2)

- **No `Content-Range` / partial fetches** — Files > 5 MB get truncated at 5 MB. If the user reports wanting to preview larger files (e.g. a 50 MB HTML report), add `Range` header support in v2.
- **No JS in HTML previews** — `sandbox="allow-same-origin"` deliberately omits `allow-scripts`. If users want to preview a WebGL demo or a JS app, that's a v2 decision (will need a per-session allowlist or a `--allow-scripts` flag).
- **No sub-agent sandboxing of cwd** — Sub-agents inherit the parent's `cwd` (per the existing tool-registry design). The preview URL's session_id sandbox still works, but a sub-agent's "session" is the parent's session, not its own. If sub-agents should be sandboxed more strictly, that's a v2 decision affecting the entire tool-registry architecture, not just `show_file`.
- **No `text/html` content sniffing override** — The mime is taken from the file extension. A file named `landing.html` containing actual JPEG bytes would render as broken HTML. The browser's `X-Content-Type-Options: nosniff` header prevents it from guessing, but a malicious agent could exploit the mismatch. Not a security issue (the agent is trusted), just a UX wart. v2.
