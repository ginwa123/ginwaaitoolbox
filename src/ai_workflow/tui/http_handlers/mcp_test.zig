//! `POST /api/mcp/test` — try a candidate MCP server config WITHOUT saving.
//!
//! Purpose: let the user click "Test" inside the Add/Edit MCP server modal
//! and verify their command + args + env + cwd (or URL + headers for the
//! HTTP transport) actually work BEFORE they click Save. The existing
//! flow only validates the config on disk at agent-loop time, which means
//! a typo'd command or wrong path would only surface mid-workflow.
//!
//! This endpoint is INERT in the sense that it does NOT touch
//! `config.json` or the DB — it just spawns the candidate child / fires
//! the candidate HTTP request once and reports the result. Successful
//! calls also leave the spawned child in the `StdioRegistry` cache
//! keyed by a per-call preview name (so a subsequent Save with the same
//! `server_name` reuses it, which is fine and matches the existing
//! registry semantics).
//!
//! **Timeout model**: HTTP probes use `custom_http_client`'s
//! `timeout_ms` (libcurl handles cancellation at the OS level).
//! stdio probes have a 10s deadline (see `TEST_STDIO_TIMEOUT_MS`),
//! implemented via the deadline plumbing in `mcp_stdio.StdioClient`
//! (plan 2026-08-28-fix-mcp-stdio-blocking). On deadline, the recv
//! returns `StdioError.RecvTimeout` and the preview entry is marked
//! stale so the next /api/mcp/test doesn't reuse the hung child.
//! `2026-08-28-fix-mcp-stdio-blocking` plan.
//!
//! Wire (request):
//! ```json
//! {
//!   "transport": "stdio",
//!   "command": "mcp-hello-world",
//!   "args": ["--name", "alpha"],
//!   "env": ["NODE_ENV=production"],
//!   "cwd": "/abs/path"
//! }
//! ```
//! OR
//! ```json
//! {
//!   "transport": "http",
//!   "url": "https://mcp.contextcontext.com://mcp",
//!   "headers": {"X-Token": "secret"}
//! }
//! ```
//!
//! Wire (response): `{"ok": true, "transport": "...", "tools": [{"name", "description"}]}`
//! on success; `{"ok": false, "error": "...", "details": "..."}` on failure.
//! Both paths return HTTP 200 (matches `notify_test.zig`'s pattern — the
//! endpoint is a probe, not a state mutation, and the user's UI wants
//! to render the error message inline, not as a 500).

const std = @import("std");
const mod = @import("mod.zig");
const nalarcore = mod.nalarcore;
const gserverz = nalarcore.gserverz;
const http_response = nalarcore.http_response;
const logger_mod = nalarcore.loggermod;
const mcp_stdio = nalarcore.mcp_stdio;
const tool_models = nalarcore.tool_models;
// `custom_http_client` is a separate top-level package imported
// directly via `@import("custom_http_client")` (see root.zig:509),
// not a member of `nalarcore`.
const custom_http_client = @import("custom_http_client");

/// Per-call deadline for HTTP probes (libcurl has OS-level timeout
/// support). See the "Timeout model" comment at the top.
const TEST_HTTP_TIMEOUT_MS: u32 = 10_000;

/// Per-call deadline for stdio probes (mcp_stdio.zig polls this
/// between bytes read). Tight enough to fail fast for the user
/// without burning a long test budget; long enough to absorb
/// slow process spawn + IPC roundtrip on a busy host.
const TEST_STDIO_TIMEOUT_MS: u64 = 10_000;

/// Tagged request body. Mirrors the frontend's `McpServerModalValue`
/// shape minus the `name` field (we don't persist anything here).
const TestRequest = struct {
    transport: []const u8 = "",
    /// stdio-only fields
    command: []const u8 = "",
    args: ?[]const []const u8 = null,
    env: ?[]const []const u8 = null,
    cwd: []const u8 = "",
    /// http-only fields
    url: []const u8 = "",
    headers: ?std.json.Value = null,
};

// ─── Error mapping ──────────────────────────────────────────────────────────

const TestError = error{
    MissingTransport,
    UnsupportedTransport,
    MissingCommand,
    MissingUrl,
    SpawnFailed,
    SendFailed,
    RecvFailed,
    Timeout,
    JsonParseFailed,
    InvalidResponse,
    OutOfMemory,
};

// ─── Use case ──────────────────────────────────────────────────────────────

const ToolPreview = struct {
    name: []const u8,
    description: []const u8,
};

const TestOutcome = struct {
    transport: []const u8,
    tools: []const ToolPreview,
};

/// Try a single MCP server candidate. Returns either the parsed
/// tools (on success) or a `TestError`. On error, `out_err_detail`
/// (if non-null) is set to a heap-allocated slice with the concrete
/// underlying error name (e.g. "UnexpectedEof") — useful for
/// surfacing in the response body without making the user dig
/// through server logs. Pure function — does NOT write to disk/DB.
fn useCase(
    allocator: std.mem.Allocator,
    io: std.Io,
    logger: *logger_mod.Logger,
    req: TestRequest,
    out_err_detail: *?[]const u8,
) TestError!TestOutcome {
    // Transport dispatch.
    if (std.mem.eql(u8, req.transport, "stdio")) {
        return testStdio(allocator, io, logger, req, out_err_detail);
    } else if (std.mem.eql(u8, req.transport, "http")) {
        return testHttp(allocator, io, logger, req);
    } else if (req.transport.len == 0) {
        return TestError.MissingTransport;
    } else {
        return TestError.UnsupportedTransport;
    }
}

// ─── stdio ────────────────────────────────────────────────────────────────

/// Try a stdio candidate: spawn the child, send `tools/list` as
/// raw NDJSON, parse the response.
///
/// **Deadline**: 10s via `TEST_STDIO_TIMEOUT_MS`, plumbed into
/// `client.recv(deadline_ns, null)`. A hung child returns
/// `StdioError.RecvTimeout` instead of blocking the handler; the
/// preview entry is marked stale so the next test doesn't reuse
/// the dead client. See plan 2026-08-28-fix-mcp-stdio-blocking.
fn testStdio(
    allocator: std.mem.Allocator,
    io: std.Io,
    logger: *logger_mod.Logger,
    req: TestRequest,
    out_err_detail: *?[]const u8,
) TestError!TestOutcome {
    if (req.command.len == 0) return TestError.MissingCommand;

    // Build argv from request fields.
    var argv_list: std.ArrayList([]const u8) = .empty;
    defer argv_list.deinit(allocator);
    try argv_list.append(allocator, try allocator.dupe(u8, req.command));
    if (req.args) |a| {
        for (a) |arg| {
            try argv_list.append(allocator, try allocator.dupe(u8, arg));
        }
    }
    const argv = try argv_list.toOwnedSlice(allocator);
    defer {
        for (argv) |a| allocator.free(a);
        allocator.free(argv);
    }

    // Per-call preview name. Keeps the spawned child distinct from
    // the user's eventual Save'd name (so two consecutive Tests
    // don't share cached children). Marked stale on failure so
    // the next test doesn't reuse a half-dead client.
    const preview_name = std.fmt.allocPrint(
        allocator,
        "__mcp_test_preview_{d}",
        .{std.Io.Timestamp.now(io, .real).nanoseconds},
    ) catch return TestError.OutOfMemory;
    defer allocator.free(preview_name);

    const reg = mcp_stdio.StdioRegistry.global(allocator);
    const client = reg.getOrSpawn(preview_name, argv) catch |err| {
        logger.warnFmt("[mcp_test] stdio spawn failed for command '{s}': {s}", .{ req.command, @errorName(err) });
        return TestError.SpawnFailed;
    };

    // Send `tools/list` as raw NDJSON (not Content-Length framed).
    // The @modelcontextprotocol/sdk reads stdin via a line-based
    // stream reader and parses each line as JSON; a Content-Length
    // header before the JSON makes the first "line" un-parseable
    // and the SDK silently drops the request. This is a v1.x SDK
    // quirk — the spec allows both formats.
    const body = std.fmt.allocPrint(
        allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":\"1\",\"method\":\"tools/list\",\"params\":{{}}}}\n",
        .{},
    ) catch return TestError.OutOfMemory;
    defer allocator.free(body);

    // Direct write to stdin — bypass the Content-Length framing in
    // `client.send` (per the SDK quirk comment above).
    const stdin_file = client.stdin orelse return TestError.SendFailed;
    std.Io.File.writeStreamingAll(stdin_file, io, body) catch |err| {
        logger.warnFmt("[mcp_test] stdio send failed: {s}", .{@errorName(err)});
        return TestError.SendFailed;
    };

    // 10s deadline per the /api/mcp/test probe's contract (we want
    // fast failure for the user, not a 30s default). The cancel
    // callback is null — the HTTP request can be cancelled by the
    // client closing the connection (handled by the http server's
    // own teardown). On RecvTimeout we mark the preview stale so
    // a second /api/mcp/test with a responsive server doesn't reuse
    // the hung child. See mcp_stdio.zig's markStale for the
    // self-healing contract.
    const deadline_ns: u64 = TEST_STDIO_TIMEOUT_MS * std.time.ns_per_ms;
    const resp = client.recv(deadline_ns, null) catch |err| {
        // Mark the preview entry stale so the next test doesn't
        // reuse the (now-dead) cached client. Surface the concrete
        // StdioError in the response.
        reg.markStale(preview_name);
        out_err_detail.* = allocator.dupe(u8, @errorName(err)) catch null;
        return TestError.RecvFailed;
    };
    defer allocator.free(resp);

    // Parse result.tools[] into a lean preview.
    const tools = parseToolsList(allocator, resp) catch |err| {
        logger.warnFmt("[mcp_test] stdio response parse failed: {s}", .{@errorName(err)});
        return TestError.JsonParseFailed;
    };

    return .{ .transport = "stdio", .tools = tools };
}

/// Try an HTTP candidate: POST `tools/list` to the URL with the
/// headers, parse `result.tools[]`. Uses libcurl's built-in 10s
/// timeout via `timeout_ms`.
fn testHttp(
    allocator: std.mem.Allocator,
    io: std.Io,
    logger: *logger_mod.Logger,
    req: TestRequest,
) TestError!TestOutcome {
    _ = io;
    if (req.url.len == 0) return TestError.MissingUrl;

    var client = custom_http_client.Client.init(allocator);
    defer client.deinit();

    const body = allocator.dupe(u8,
        \\{"jsonrpc":"2.0","id":"1","method":"tools/list","params":{}}
    ) catch return TestError.OutOfMemory;
    defer allocator.free(body);

    var header_buf: [16]custom_http_client.Header = undefined;
    var header_count: usize = 0;
    header_buf[header_count] = .{ .name = "Accept", .value = "application/json, text/event-stream" };
    header_count += 1;
    header_buf[header_count] = .{ .name = "Content-Type", .value = "application/json" };
    header_count += 1;

    if (req.headers) |hdrs_value| {
        const hdrs_obj = switch (hdrs_value) {
            .object => |obj| obj,
            else => return TestError.JsonParseFailed,
        };
        var it = hdrs_obj.iterator();
        while (it.next()) |entry| {
            if (header_count >= header_buf.len) break;
            const v_str = switch (entry.value_ptr.*) {
                .string => |s| s,
                else => continue,
            };
            header_buf[header_count] = .{ .name = entry.key_ptr.*, .value = v_str };
            header_count += 1;
        }
    }
    const header_slice = header_buf[0..header_count];

    const result = custom_http_client.post(
        &client,
        req.url,
        body,
        header_slice,
        .{ .timeout_ms = TEST_HTTP_TIMEOUT_MS },
    ) catch |err| {
        logger.warnFmt("[mcp_test] http POST failed for '{s}': {s}", .{ req.url, @errorName(err) });
        if (err == error.Timeout) return TestError.Timeout;
        return TestError.SendFailed;
    };
    defer result.deinit(allocator);

    if (result.status_code != 200) {
        logger.warnFmt("[mcp_test] http server returned status {d}", .{result.status_code});
        return TestError.InvalidResponse;
    }

    const tools = parseToolsList(allocator, result.body) catch |err| {
        logger.warnFmt("[mcp_test] http response parse failed: {s}", .{@errorName(err)});
        return TestError.JsonParseFailed;
    };

    return .{ .transport = "http", .tools = tools };
}

/// Parse an MCP `tools/list` response into a preview list.
fn parseToolsList(allocator: std.mem.Allocator, body: []const u8) TestError![]const ToolPreview {
    const trimmed = std.mem.trim(u8, body, " \t\r\n");
    const json_start: []const u8 = if (std.mem.startsWith(u8, trimmed, "data:"))
        std.mem.trim(u8, trimmed["data:".len..], " \t")
    else
        body;

    var parse_arena = std.heap.ArenaAllocator.init(allocator);
    defer parse_arena.deinit();
    const parsed = std.json.parseFromSlice(
        std.json.Value,
        parse_arena.allocator(),
        json_start,
        .{ .ignore_unknown_fields = true },
    ) catch return TestError.JsonParseFailed;

    const root = switch (parsed.value) {
        .object => |obj| obj,
        else => return TestError.InvalidResponse,
    };
    const result_value = root.get("result") orelse return TestError.InvalidResponse;
    const result_obj = switch (result_value) {
        .object => |obj| obj,
        else => return TestError.InvalidResponse,
    };
    const tools_value = result_obj.get("tools") orelse return TestError.InvalidResponse;
    const tools_array = switch (tools_value) {
        .array => |a| a,
        else => return TestError.InvalidResponse,
    };

    var out: std.ArrayList(ToolPreview) = .empty;
    errdefer out.deinit(allocator);
    for (tools_array.items) |tool_value| {
        const tool_obj = switch (tool_value) {
            .object => |obj| obj,
            else => continue,
        };
        const name_v = tool_obj.get("name") orelse continue;
        const name = switch (name_v) {
            .string => |s| s,
            else => continue,
        };
        const desc_v = tool_obj.get("description") orelse continue;
        const description = switch (desc_v) {
            .string => |s| s,
            else => continue,
        };
        out.append(allocator, .{
            .name = try allocator.dupe(u8, name),
            .description = try allocator.dupe(u8, description),
        }) catch return TestError.OutOfMemory;
    }
    return out.toOwnedSlice(allocator) catch return TestError.OutOfMemory;
}

// ─── Handler ───────────────────────────────────────────────────────────────

pub fn mcpTestHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;
    const io = ctx.io;
    const di = nalarcore.getSingleton() catch {
        return res.jsonResponse(.{
            .status_code = 500,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Server not initialized" }),
        });
    };
    const logger = di.logger;

    const parsed = std.json.parseFromSliceLeaky(TestRequest, allocator, req.body, .{
        .ignore_unknown_fields = true,
    }) catch {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try std.fmt.allocPrint(allocator, "{{\"error\":\"invalid JSON body\"}}", .{}),
        });
    };

    var err_detail: ?[]const u8 = null;
    defer if (err_detail) |d| allocator.free(d);
    const outcome = useCase(allocator, io, logger, parsed, &err_detail) catch |err| {
        const message: []const u8 = switch (err) {
            error.MissingTransport => "transport is required (stdio or http)",
            error.UnsupportedTransport => "transport must be 'stdio' or 'http'",
            error.MissingCommand => "command is required for stdio transport",
            error.MissingUrl => "url is required for http transport",
            error.SpawnFailed => "failed to spawn child process (check the command exists and is executable)",
            error.SendFailed => "failed to send request to MCP server",
            error.RecvFailed => "failed to receive response from MCP server",
            error.Timeout => "MCP server did not respond within 10 seconds",
            error.JsonParseFailed => "failed to parse MCP server response as JSON",
            error.InvalidResponse => "MCP server response did not contain a valid tools list",
            error.OutOfMemory => "out of memory",
        };
        const details: []const u8 = err_detail orelse @errorName(err);
        std.log.warn("[mcp_test] error: {s} ({s})", .{ message, details });
        const data = std.fmt.allocPrint(
            allocator,
            "{{\"ok\":false,\"error\":\"{s}\",\"details\":\"{s}\"}}",
            .{ message, details },
        ) catch {
            return res.jsonResponse(.{
                .status_code = 500,
                .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Out of memory" }),
            });
        };
        return res.jsonResponse(.{ .status_code = 200, .data = data });
    };

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    try buf.print(allocator, "{{\"ok\":true,\"transport\":\"{s}\",\"tools\":[", .{outcome.transport});
    for (outcome.tools, 0..) |tool, i| {
        if (i > 0) try buf.appendSlice(allocator, ",");
        try buf.print(allocator, "{{\"name\":{f},\"description\":{f}}}",
            .{ std.json.fmt(tool.name, .{}), std.json.fmt(tool.description, .{}) });
    }
    try buf.appendSlice(allocator, "]}");
    const data = try buf.toOwnedSlice(allocator);

    return res.jsonResponse(.{ .status_code = 200, .data = data });
}

// ─── Inline tests ──────────────────────────────────────────────────────────

const testing = std.testing;

fn sourceContains(allocator: std.mem.Allocator, path: []const u8, needle: []const u8) !bool {
    const raw = try std.Io.Dir.cwd().readFileAlloc(testing.io, path, allocator, .limited(1024 * 1024));
    defer allocator.free(raw);
    return std.mem.indexOf(u8, raw, needle) != null;
}

test "mcpTestHandler: registers the POST route with /api/mcp/test" {
    const found = try sourceContains(testing.allocator, "../../../../../main.zig", "/api/mcp/test");
    try testing.expect(found);
}

test "mcpTestHandler: returns ok:true with tools on stdio success" {
    const raw = try std.Io.Dir.cwd().readFileAlloc(
        testing.io,
        "src/ai_workflow/tui/http_handlers/mcp_test.zig",
        testing.allocator,
        .limited(1024 * 1024),
    );
    defer testing.allocator.free(raw);

    try testing.expect(std.mem.indexOf(u8, raw, "\"ok\":true") != null);
    try testing.expect(std.mem.indexOf(u8, raw, "\"transport\":") != null);
    try testing.expect(std.mem.indexOf(u8, raw, "\"tools\":[") != null);
}

test "mcpTestHandler: maps TestError variants to readable error messages" {
    const raw = try std.Io.Dir.cwd().readFileAlloc(
        testing.io,
        "src/ai_workflow/tui/http_handlers/mcp_test.zig",
        testing.allocator,
        .limited(1024 * 1024),
    );
    defer testing.allocator.free(raw);

    const catch_start = std.mem.indexOf(u8, raw, "const outcome = useCase") orelse
        return error.CatchBlockMissing;
    const switch_start = std.mem.indexOfPos(u8, raw, catch_start, "switch (err) {") orelse
        return error.SwitchMissing;
    const switch_end = std.mem.indexOfPos(u8, raw, switch_start, "};\n        }\n;") orelse
        return error.SwitchEndMissing;
    const switch_body = raw[switch_start..switch_end];

    for ([_][]const u8{
        "error.MissingTransport",
        "error.UnsupportedTransport",
        "error.MissingCommand",
        "error.MissingUrl",
        "error.SpawnFailed",
        "error.SendFailed",
        "error.RecvFailed",
        "error.Timeout",
        "error.JsonParseFailed",
        "error.InvalidResponse",
        "error.OutOfMemory",
    }) |variant| {
        if (std.mem.indexOf(u8, switch_body, variant) == null) {
            std.debug.print("\n!! mcp_test.zig error mapping missing variant {s} !!\n", .{variant});
            return error.VariantMissing;
        }
    }
}

test "mcp_test.zig http timeout is 10_000 ms" {
    const raw = try std.Io.Dir.cwd().readFileAlloc(
        testing.io,
        "src/ai_workflow/tui/http_handlers/mcp_test.zig",
        testing.allocator,
        .limited(1024 * 1024),
    );
    defer testing.allocator.free(raw);
    try testing.expect(std.mem.indexOf(u8, raw, "TEST_HTTP_TIMEOUT_MS: u32 = 10_000") != null);
}