//! MCP Streamable HTTP transport for the agent AI (Zig client).
//!
//! This file contains everything HTTP-specific for the agent's MCP
//! client, mirroring the stdio transport's `mcp_stdio.zig`:
//!   1. **SSE event parser** (Section A) — `readSseEvent` walks a
//!      line-buffered stream and yields fully-parsed events. Used by
//!      `HttpClient.callTool` and `HttpClient.listTools` to consume
//!      `text/event-stream` responses per the Streamable HTTP spec.
//!   2. **MCP request-header builder** (Section B) — `buildMcpHeaders`
//!      emits the spec-mandated `MCP-Protocol-Version`, `Mcp-Method`,
//!      and `Mcp-Name` headers (per spec revision 2025-11-25), merged
//!      with the user-defined custom headers from
//!      `mcp_servers[name].headers`.
//!   3. **`HttpClient`** (Section C) — one POST, one response (JSON or
//!      SSE), returns the final JSON-RPC body.
//!   4. **`HttpRegistry`** (Section D) — process-global, one client
//!      per server name, lazy init, no respawn needed.
//!   5. **`ListTools` helper** (Section E) — sibling of `callTool` that
//!      does `tools/list` instead of `tools/call`.
//!
//! Tests are inline at the bottom (per the user's "no need split code
//! for zig, just one file with test" preference). Total expected size:
//! ~700-900 lines including the 18 inline tests (12 for the helpers,
//! 6 for HttpClient + HttpRegistry).
//!
//! Plan: docs/superpowers/plans/2026-08-28-mcp-streamable-http.md

const std = @import("std");
const builtin = @import("builtin");

// ============================================================================
// SECTION A — MCP spec constants (pub so the registry in Section D can read)
// ============================================================================

/// Current Streamable HTTP protocol revision we implement.
/// Bump when the spec at
///   https://modelcontextprotocol.io/specification/draft/basic/transports/streamable-http
/// revises again. Sent as the `MCP-Protocol-Version` header on every POST.
///
/// 2025-11-25 is the latest revision `@modelcontextprotocol/sdk` v1.30.0
/// (the canonical MCP TS SDK) actually implements. The spec page's
/// "current" 2026-07-28 revision is not yet implemented by any SDK or
/// client in the ecosystem; targeting it would mean our HTTP client
/// can't talk to ANY real server today.
pub const PROTOCOL_VERSION: []const u8 = "2025-11-25";

/// Spec-mandated Accept header value (comma-separated, no spaces).
/// Every request must include this so the server knows we handle BOTH
/// `application/json` and `text/event-stream` responses.
pub const ACCEPT_HEADER: []const u8 = "application/json, text/event-stream";

pub const HttpError = error{
    InvalidSseEvent,           // no `data:` field on an event we expected to carry a JSON-RPC message
    ServerHeaderMismatch,      // 400 with HeaderMismatch error
    UnsupportedProtocolVersion, // 400 with UnsupportedProtocolVersionError
    ServerMethodNotFound,      // 404 (distinct from a legacy 404)
    ServerReturnedError,       // other 4xx/5xx
    InvalidJson,               // response body wasn't valid JSON-RPC
};

// ============================================================================
// SECTION B — SSE event parser (private to this file)
// ============================================================================
//
// Wire format (per SSE spec https://html.spec.whatwg.org/multipage/server-sent-events.html):
//
//   event: <event-type>\n
//   data: <data-line-1>\n
//   data: <data-line-2>\n    <- multi-line data is concatenated with \n
//   id: <event-id>\n
//   retry: <milliseconds>\n
//   :<comment>\n            <- comment, ignored by clients
//   \n                      <- blank line: event boundary; dispatch the event
//
// Multi-`data:` lines per event are concatenated with `\n` (per the
// SSE spec: "the data field is then the concatenation of all the data
// values, each separated by a single U+000A LINE FEED character").
//
// Field names are CASE-INSENSITIVE per the SSE spec — we use
// `std.ascii.startsWithIgnoreCase` for the dispatch.

/// One parsed SSE event. All fields are freshly allocated slices
/// owned by the caller (free with `allocator.free`). `event` and `id`
/// default to `""` per the SSE spec (the event type "message" is
/// implicit when no `event:` field is present).
pub const SseEvent = struct {
    event: []const u8 = "",
    data: []const u8 = "",
    id: []const u8 = "",
    retry_ms: ?u64 = null,
};

/// Read one SSE event from a line-buffered reader. Returns null on
/// EOF (clean stream end). Skips comment lines (starting with `:`),
/// blank lines (event boundaries), and unknown field lines (per the
/// SSE spec, clients ignore unknown fields).
///
/// The reader is `anytype` so tests can pass an in-memory mock — the
/// only contract is a `next() !?[]const u8` method that returns the
/// next line (without the trailing `\n`) or null on EOF. This matches
/// `custom_http_client.stream.StreamScanner.next`'s shape.
fn readSseEvent(allocator: std.mem.Allocator, reader: anytype) !?SseEvent {
    // Per-event accumulators. Reset on every event boundary (blank
    // line). On EOF, if we have any partial event (a `data:` line in
    // flight), we flush it; otherwise we return null to signal clean
    // stream end.
    var event_buf = std.ArrayList(u8).empty;
    var id_buf = std.ArrayList(u8).empty;
    var data_buf = std.ArrayList(u8).empty;
    var retry_ms: ?u64 = null;
    var saw_data = false;
    var in_event = false;
    defer {
        event_buf.deinit(allocator);
        id_buf.deinit(allocator);
        data_buf.deinit(allocator);
    }

    while (true) {
        const line_opt = try reader.next();
        const line = line_opt orelse {
            // EOF: flush if we have a partial event, else return null.
            break;
        };

        if (line.len == 0) {
            // Blank line: event boundary. If we were in an event, dispatch.
            if (in_event) {
                if (saw_data) {
                    return SseEvent{
                        .event = try event_buf.toOwnedSlice(allocator),
                        .data = try data_buf.toOwnedSlice(allocator),
                        .id = try id_buf.toOwnedSlice(allocator),
                        .retry_ms = retry_ms,
                    };
                }
                // No data: this was a comment-only event. Per SSE spec,
                // clients should still process id/retry but we don't
                // have anything to return. Continue.
                event_buf.clearRetainingCapacity();
                id_buf.clearRetainingCapacity();
                data_buf.clearRetainingCapacity();
                retry_ms = null;
                in_event = false;
            }
            continue;
        }

        // Comment line (SSE spec: ":..." is a comment, ignore).
        if (line[0] == ':') continue;

        in_event = true;

        // Dispatch on the first colon. Field names are case-insensitive
        // per the SSE spec — use std.ascii.startsWithIgnoreCase.
        if (std.ascii.startsWithIgnoreCase(line, "data:")) {
            saw_data = true;
            // Per SSE spec, the value is everything after the first
            // colon minus a single leading space (if present).
            var value = line["data:".len..];
            if (value.len > 0 and value[0] == ' ') value = value[1..];
            if (data_buf.items.len > 0) try data_buf.append(allocator, '\n');
            try data_buf.appendSlice(allocator, value);
        } else if (std.ascii.startsWithIgnoreCase(line, "event:")) {
            var value = line["event:".len..];
            if (value.len > 0 and value[0] == ' ') value = value[1..];
            event_buf.clearRetainingCapacity();
            try event_buf.appendSlice(allocator, value);
        } else if (std.ascii.startsWithIgnoreCase(line, "id:")) {
            var value = line["id:".len..];
            if (value.len > 0 and value[0] == ' ') value = value[1..];
            id_buf.clearRetainingCapacity();
            try id_buf.appendSlice(allocator, value);
        } else if (std.ascii.startsWithIgnoreCase(line, "retry:")) {
            var value = line["retry:".len..];
            if (value.len > 0 and value[0] == ' ') value = value[1..];
            retry_ms = std.fmt.parseInt(u64, value, 10) catch null;
        }
        // Unknown field: ignore (per SSE spec).
    }

    // EOF reached. Flush any partial event.
    if (in_event and saw_data) {
        return SseEvent{
            .event = try event_buf.toOwnedSlice(allocator),
            .data = try data_buf.toOwnedSlice(allocator),
            .id = try id_buf.toOwnedSlice(allocator),
            .retry_ms = retry_ms,
        };
    }
    return null;
}

// ============================================================================
// SECTION C — MCP request-header builder (private to this file)
// ============================================================================
//
// Spec (revision 2025-11-25) requires these headers on EVERY POST:
//   - `MCP-Protocol-Version: 2025-11-25`
//   - `Accept: application/json, text/event-stream`
//   - `Content-Type: application/json`
//   - `Mcp-Method: <method>` (e.g. "tools/call")
//   - `Mcp-Name: <name>` (for tools/call, resources/read, prompts/get)
//
// We use `std.http.Header` here for the slice. The caller passes
// `custom_headers` (a `[]const std.http.Header` from the user's
// `mcp_servers[name].headers` config) which we MERGE with the spec
// headers. Spec headers go FIRST in the slice because libcurl's
// curl_slist uses the FIRST match for duplicate names, so the spec
// value (e.g. `MCP-Protocol-Version: 2025-11-25`) wins over a user's
// accidental custom value of the same name. The user CANNOT override
/// spec values, even on purpose.

/// Returns true iff every byte of `s` is in the ASCII range (0..127).
/// Used by `buildMcpHeaders` to decide whether to emit `Mcp-Name` —
/// non-ASCII tool names are dropped (the spec's Base64-sentinel
/// encoding for non-ASCII header values is a v2).
fn isAllAscii(s: []const u8) bool {
    for (s) |c| {
        if (c > 127) return false;
    }
    return true;
}

/// Build the request headers for an MCP Streamable HTTP POST.
///
/// `tool_name` is only used for `tools/call` — pass "" for methods
/// that don't take a name (initialize, ping, tools/list, etc.).
///
/// `custom_headers` is a `[]const std.http.Header` slice; we only
/// read `.name` and `.value` fields. Null = no custom headers.
///
/// Returns a freshly-allocated `[]std.http.Header` slice the caller
/// owns (frees with `allocator.free`).
fn buildMcpHeaders(
    allocator: std.mem.Allocator,
    method: []const u8,
    tool_name: []const u8,
    custom_headers: []const std.http.Header,
) ![]std.http.Header {
    // 4 spec headers always present. We MAY add a 5th (Mcp-Name) if
    // tool_name is non-empty AND ASCII. The slice order is critical:
    // spec headers FIRST so libcurl's first-match-wins uses the spec
    // value, not a user's accidental custom override of the same name.
    const include_name = tool_name.len > 0 and isAllAscii(tool_name);
    const spec_count: usize = if (include_name) 5 else 4;
    const total = spec_count + custom_headers.len;

    const out = try allocator.alloc(std.http.Header, total);
    errdefer allocator.free(out);

    // Spec headers (FIRST in the slice).
    out[0] = .{ .name = "Accept", .value = ACCEPT_HEADER };
    out[1] = .{ .name = "Content-Type", .value = "application/json" };
    out[2] = .{ .name = "MCP-Protocol-Version", .value = PROTOCOL_VERSION };
    out[3] = .{ .name = "Mcp-Method", .value = method };
    if (include_name) {
        out[4] = .{ .name = "Mcp-Name", .value = tool_name };
    }

    // User-supplied custom headers (LAST in the slice, after the spec
    // ones). Note we don't dedupe — libcurl's first-match-wins handles
    // duplicates. The spec headers above will always be the values the
    // server sees.
    for (custom_headers, 0..) |h, i| {
        out[spec_count + i] = h;
    }

    return out;
}

// ============================================================================
// SECTION D — HttpClient + HttpRegistry (arrives in Task 3)
// ============================================================================
//
// Stubbed here so the file compiles. Task 3 adds the real impls
// along with the 6 inline tests for these.

// ============================================================================
// SECTION E — ListTools helper (arrives in Task 3)
// ============================================================================

// ============================================================================
// SECTION F — Tests
// ============================================================================
//
// Tests live at the bottom of the impl file per the user's "no need
// split code for zig, just one file with test" preference.
//
// Test counts:
//   - 8 tests for `readSseEvent` (Section A)
//   - 4 tests for `buildMcpHeaders` (Section C)
//   - 6 tests for HttpClient + HttpRegistry (Section D, arrives in Task 3)

const testing = std.testing;

// ── Mock line reader for SSE parser tests ──────────────────────────────

/// In-memory line reader for `readSseEvent` tests. Holds a list of
/// lines (without trailing `\n`); `next()` returns them one at a time
/// then null. Mirrors the contract of `StreamScanner.next()` so the
/// SSE parser is duck-type compatible with the real streaming reader.
const MockLineReader = struct {
    lines: []const []const u8,
    index: usize = 0,

    fn next(self: *MockLineReader) !?[]const u8 {
        if (self.index >= self.lines.len) return null;
        const line = self.lines[self.index];
        self.index += 1;
        return line;
    }
};

// ── readSseEvent tests (8 tests) ───────────────────────────────────────

/// All readSseEvent tests must free ALL three freshly-allocated
/// fields of the returned event (event / data / id). Most fields are
/// empty for most tests but the parser allocates an empty slice for
/// each non-empty field, so we always free defensively.
const testing_allocator = testing.allocator;

test "readSseEvent: single data-only event" {
    var reader = MockLineReader{ .lines = &.{ "data: hello" } };
    const ev = (try readSseEvent(testing_allocator, &reader)) orelse unreachable;
    defer {
        testing_allocator.free(ev.event);
        testing_allocator.free(ev.data);
        testing_allocator.free(ev.id);
    }
    try testing.expectEqualStrings("hello", ev.data);
    try testing.expectEqualStrings("", ev.event);
    try testing.expectEqualStrings("", ev.id);
    try testing.expectEqual(@as(?u64, null), ev.retry_ms);
}

test "readSseEvent: event + data" {
    var reader = MockLineReader{ .lines = &.{
        "event: progress",
        "data: {\"p\":50}",
    } };
    const ev = (try readSseEvent(testing_allocator, &reader)) orelse unreachable;
    defer {
        testing_allocator.free(ev.event);
        testing_allocator.free(ev.data);
        testing_allocator.free(ev.id);
    }
    try testing.expectEqualStrings("progress", ev.event);
    try testing.expectEqualStrings("{\"p\":50}", ev.data);
}

test "readSseEvent: multi-data concatenation with \\n" {
    // Per SSE spec, multi-`data:` lines are concatenated with a single
    // \n character between them (NOT stripped, NOT removed).
    var reader = MockLineReader{ .lines = &.{
        "data: line1",
        "data: line2",
    } };
    const ev = (try readSseEvent(testing_allocator, &reader)) orelse unreachable;
    defer {
        testing_allocator.free(ev.event);
        testing_allocator.free(ev.data);
        testing_allocator.free(ev.id);
    }
    try testing.expectEqualStrings("line1\nline2", ev.data);
}

test "readSseEvent: comment line ignored" {
    // Per SSE spec, lines starting with `:` are comments and ignored.
    var reader = MockLineReader{ .lines = &.{
        ":heartbeat",
        "data: real",
    } };
    const ev = (try readSseEvent(testing_allocator, &reader)) orelse unreachable;
    defer {
        testing_allocator.free(ev.event);
        testing_allocator.free(ev.data);
        testing_allocator.free(ev.id);
    }
    try testing.expectEqualStrings("real", ev.data);
}

test "readSseEvent: retry parsed as integer" {
    var reader = MockLineReader{ .lines = &.{
        "retry: 3000",
        "data: ok",
    } };
    const ev = (try readSseEvent(testing_allocator, &reader)) orelse unreachable;
    defer {
        testing_allocator.free(ev.event);
        testing_allocator.free(ev.data);
        testing_allocator.free(ev.id);
    }
    try testing.expectEqual(@as(?u64, 3000), ev.retry_ms);
    try testing.expectEqualStrings("ok", ev.data);
}

test "readSseEvent: id field captured" {
    var reader = MockLineReader{ .lines = &.{
        "id: 42",
        "data: ok",
    } };
    const ev = (try readSseEvent(testing_allocator, &reader)) orelse unreachable;
    defer {
        testing_allocator.free(ev.event);
        testing_allocator.free(ev.data);
        testing_allocator.free(ev.id);
    }
    try testing.expectEqualStrings("42", ev.id);
    try testing.expectEqualStrings("ok", ev.data);
}

test "readSseEvent: blank line mid-stream resets to a new event" {
    // Two events in one stream: first carries "first", second carries
    // "second". A blank line (`""` in our mock = event boundary) resets
    // the per-event accumulators.
    var reader = MockLineReader{ .lines = &.{
        "data: first",
        "", // event boundary
        "data: second",
    } };
    const ev1 = (try readSseEvent(testing_allocator, &reader)) orelse unreachable;
    defer {
        testing_allocator.free(ev1.event);
        testing_allocator.free(ev1.data);
        testing_allocator.free(ev1.id);
    }
    try testing.expectEqualStrings("first", ev1.data);

    const ev2 = (try readSseEvent(testing_allocator, &reader)) orelse unreachable;
    defer {
        testing_allocator.free(ev2.event);
        testing_allocator.free(ev2.data);
        testing_allocator.free(ev2.id);
    }
    try testing.expectEqualStrings("second", ev2.data);
}

test "readSseEvent: case-insensitive field names" {
    // Per SSE spec, field names are case-insensitive. "DATA:" must be
    // treated the same as "data:".
    var reader = MockLineReader{ .lines = &.{ "DATA: upper" } };
    const ev = (try readSseEvent(testing_allocator, &reader)) orelse unreachable;
    defer {
        testing_allocator.free(ev.event);
        testing_allocator.free(ev.data);
        testing_allocator.free(ev.id);
    }
    try testing.expectEqualStrings("upper", ev.data);
}

// ── buildMcpHeaders tests (4 tests) ────────────────────────────────────

test "buildMcpHeaders: required headers always present for tools/call" {
    const hdrs = try buildMcpHeaders(
        testing.allocator,
        "tools/call",
        "say_hello",
        &[_]std.http.Header{},
    );
    defer testing.allocator.free(hdrs);
    // 4 spec headers (Accept, Content-Type, MCP-Protocol-Version,
    // Mcp-Method) + 1 per-method (Mcp-Name) = 5 total.
    try testing.expectEqual(@as(usize, 5), hdrs.len);
    // Spot-check the values. Order isn't asserted here (libcurl
    // uses first-match, not order).
    var found_accept = false;
    var found_content_type = false;
    var found_protocol = false;
    var found_method = false;
    var found_name = false;
    for (hdrs) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "Accept")) {
            try testing.expectEqualStrings("application/json, text/event-stream", h.value);
            found_accept = true;
        } else if (std.ascii.eqlIgnoreCase(h.name, "Content-Type")) {
            try testing.expectEqualStrings("application/json", h.value);
            found_content_type = true;
        } else if (std.ascii.eqlIgnoreCase(h.name, "MCP-Protocol-Version")) {
            try testing.expectEqualStrings("2025-11-25", h.value);
            found_protocol = true;
        } else if (std.ascii.eqlIgnoreCase(h.name, "Mcp-Method")) {
            try testing.expectEqualStrings("tools/call", h.value);
            found_method = true;
        } else if (std.ascii.eqlIgnoreCase(h.name, "Mcp-Name")) {
            try testing.expectEqualStrings("say_hello", h.value);
            found_name = true;
        }
    }
    try testing.expect(found_accept);
    try testing.expect(found_content_type);
    try testing.expect(found_protocol);
    try testing.expect(found_method);
    try testing.expect(found_name);
}

test "buildMcpHeaders: no Mcp-Name for initialize" {
    const hdrs = try buildMcpHeaders(
        testing.allocator,
        "initialize",
        "", // no tool name
        &[_]std.http.Header{},
    );
    defer testing.allocator.free(hdrs);
    // 4 spec headers only (no Mcp-Name when tool_name is empty).
    try testing.expectEqual(@as(usize, 4), hdrs.len);
    for (hdrs) |h| {
        try testing.expect(!std.ascii.eqlIgnoreCase(h.name, "Mcp-Name"));
    }
}

test "buildMcpHeaders: Mcp-Name omitted for non-ASCII tool names" {
    // Spec says Mcp-Name MUST be ASCII-safe (with a Base64-sentinel
    // fallback for non-ASCII values, which we don't implement in v1).
    // For v1 we just SKIP the header when the value isn't ASCII.
    const hdrs = try buildMcpHeaders(
        testing.allocator,
        "tools/call",
        "\xe5\x90\x8d\xe5\xad\x97", // "名字" in UTF-8 (non-ASCII)
        &[_]std.http.Header{},
    );
    defer testing.allocator.free(hdrs);
    try testing.expectEqual(@as(usize, 4), hdrs.len);
    for (hdrs) |h| {
        try testing.expect(!std.ascii.eqlIgnoreCase(h.name, "Mcp-Name"));
    }
}

test "buildMcpHeaders: custom headers merged; spec headers win on conflict" {
    // A custom `MCP-Protocol-Version: 1999-01-01` must NOT override the
    // spec value `2025-11-25`. We assert this by putting spec headers
    // FIRST in the slice (so libcurl's first-match-wins sees the spec
    // value) and the malicious custom header LAST.
    const custom = [_]std.http.Header{
        .{ .name = "X-Trace-Id", .value = "abc" },
        .{ .name = "MCP-Protocol-Version", .value = "1999-01-01" },
    };
    const hdrs = try buildMcpHeaders(
        testing.allocator,
        "tools/call",
        "say_hello",
        &custom,
    );
    defer testing.allocator.free(hdrs);
    // Total: 4 spec + 1 Mcp-Name + 2 custom = 7. (We don't dedupe
    // duplicate names here — the FIRST one wins in libcurl, but we
    // pass all of them through so the slice reflects the user's
    // explicit request. Tests below verify ordering.)
    try testing.expectEqual(@as(usize, 7), hdrs.len);
    // The FIRST MCP-Protocol-Version in the slice must be the spec
    // value (so libcurl uses it). The custom 1999-01-01 should appear
    // LATER in the slice.
    var first_protocol: ?[]const u8 = null;
    var found_1999 = false;
    var found_2025 = false;
    for (hdrs) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "MCP-Protocol-Version")) {
            if (first_protocol == null) first_protocol = h.value;
            if (std.mem.eql(u8, h.value, "1999-01-01")) found_1999 = true;
            if (std.mem.eql(u8, h.value, "2025-11-25")) found_2025 = true;
        }
    }
    try testing.expectEqualStrings("2025-11-25", first_protocol.?);
    try testing.expect(found_1999);
    try testing.expect(found_2025);
    // X-Trace-Id is present and equals the custom value.
    var found_trace = false;
    for (hdrs) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "X-Trace-Id")) {
            try testing.expectEqualStrings("abc", h.value);
            found_trace = true;
        }
    }
    try testing.expect(found_trace);
}
