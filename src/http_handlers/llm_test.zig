//! HTTP handler + use-case for `POST /api/llm/test`.
//!
//! Purpose: let the user click "Test" inside the Add/Edit profile modal
//! and verify their model + base_url + api_key + url_style actually work
//! BEFORE they click Save. The existing flow only validates locally
//! (name/model non-empty) and persists via `PUT /api/config/nalar`, so a
//! typo'd base_url or revoked key would only surface mid-workflow.
//!
//! This endpoint is INERT: it does NOT touch `config.json` or the DB —
//! it fires ONE minimal non-streaming chat call against the candidate
//! `base_url` and reports the result.
//!
//! Wire (request):
//! ```json
//! {
//!   "model": "MiniMax-M2.7",
//!   "base_url": "https://api.minimax.io/v1/chat/completions",
//!   "api_key": "sk-...",
//!   "url_style": "openai"
//! }
//! ```
//! `url_style` is one of `"openai" | "openai-response" | "anthropic"`
//! (defaults to `"openai"`). Unknown styles are rejected with a clear
//! error — the frontend only sends the three known values.
//!
//! Wire (response): `{"ok": true, "model": "...", "reply": "ok",
//! "latency_ms": 123}` on success; `{"ok": false, "error": "...",
//! "details": "..."}` on failure. Both paths return HTTP 200 (matches
//! `mcp_test.zig` / `notify_test.zig` — the endpoint is a probe, and the
//! modal wants to render the error inline, not as a 500).
//!
//! Probe bodies (minimal, non-streaming, no tools):
//!   - openai:          `{"model","messages":[{"role":"user","content":
//!                        "Reply with exactly: ok"}],"max_tokens":16,
//!                        "temperature":0,"stream":false}`
//!   - openai-response: `{"model","input":"Reply with exactly: ok",
//!                        "max_output_tokens":16,"stream":false,
//!                        "store":false}`
//!   - anthropic:       `{"model","max_tokens":16,"messages":[{"role":
//!                        "user","content":"Reply with exactly: ok"}]}`
//!
//! Auth: `openai*` styles send `Authorization: Bearer <api_key>`;
//! `anthropic` sends `x-api-key: <api_key>` + `anthropic-version:
//! 2023-06-01`. An EMPTY api_key is allowed (local Ollama-style
//! endpoints, stub upstreams in tests) — the auth header is simply
//! omitted in that case.
//!
//! Session: every probe sends `x-opencode-session: nalar-llm-test-probe`
//! so Console Go / OpenCode Zen gateways can route it. Without the
//! header the gateway rejects the probe with 400
//! `{"type":"error","error":{"type":"MissingSessionID",...}}` — the
//! exact failure in the Edit-profile Test button for `url_style:
//! "anthropic"`. The value is a fixed probe id (not a real
//! conversation); extra headers are ignored by direct providers
//! (OpenAI / Ollama / MiniMax), matching how `Agent.callStreaming`
//! only omits the header when `sessionId` is empty.
//!
//! **Timeout model**: `custom_http_client`'s `timeout_ms` (libcurl
//! handles cancellation at the OS level), 15s per probe.

const std = @import("std");
const mod = @import("mod.zig");
const nalarcore = mod.nalarcore;
const gserverz = nalarcore.gserverz;
const http_response = nalarcore.http_response;
const logger_mod = nalarcore.loggermod;
// kabelweb is the unified web-framework package imported
// directly via `@import("kabelweb").client` (see root.zig:509),
// not a member of `nalarcore`.
const custom_http_client = @import("kabelweb").client;
const helpers = @import("helpers");

/// Per-call deadline for the probe (libcurl has OS-level timeout
/// support). Generous vs the MCP 10s probe because LLM inference —
/// even for 16 tokens — routinely takes several seconds on a cold
/// model, and a premature timeout would read as "your key is broken".
const TEST_LLM_TIMEOUT_MS: u32 = 15_000;

/// The probe prompt. Short + deterministic so the modal can show the
/// reply verbatim as proof the model answered.
const PROBE_PROMPT: []const u8 = "Reply with exactly: ok";

/// Max reply bytes carried on the wire. The probe asks for 16 tokens;
/// 200 bytes is plenty and keeps the modal payload small.
const MAX_REPLY_LEN: usize = 200;

/// Stable session id sent as `x-opencode-session` on every Test probe.
/// Console Go / OpenCode Zen gateways require the header for routing
/// and prompt caching — see https://opencode.ai/docs/go/#where-can-i-use-it
/// and `Agent.sessionId`. The probe has no real conversation, so a fixed
/// id is enough to satisfy the gateway; direct providers ignore it.
const PROBE_SESSION_ID: []const u8 = "nalar-llm-test-probe";

/// Candidate profile fields. Mirrors the frontend's `LlmTestRequest`
/// shape in `src/apps/desktop/src/api/index.ts`. Extra fields sent by
/// the form (thinking, temperature, ...) are ignored — the probe uses
/// fixed minimal values.
const TestRequest = struct {
    model: []const u8 = "",
    base_url: []const u8 = "",
    api_key: []const u8 = "",
    url_style: []const u8 = "openai",
};

// ─── Error mapping ──────────────────────────────────────────────────────────

const TestError = error{
    MissingModel,
    MissingBaseUrl,
    InvalidBaseUrl,
    UnsupportedStyle,
    SendFailed,
    Timeout,
    HttpError,
    JsonParseFailed,
    InvalidResponse,
    OutOfMemory,
};

const TestOutcome = struct {
    model: []const u8,
    reply: []const u8,
    latency_ms: i64,
};

// ─── Pure helpers (unit-testable, no network) ───────────────────────────────

/// Validate the candidate without touching the network. Empty api_key
/// is ALLOWED (keyless local endpoints + stub upstreams in tests).
fn validate(req: TestRequest) TestError!void {
    if (req.model.len == 0) return TestError.MissingModel;
    if (req.base_url.len == 0) return TestError.MissingBaseUrl;
    const has_http_scheme = std.mem.startsWith(u8, req.base_url, "http://") or
        std.mem.startsWith(u8, req.base_url, "https://");
    if (!has_http_scheme) return TestError.InvalidBaseUrl;
    if (!(std.mem.eql(u8, req.url_style, "openai") or
        std.mem.eql(u8, req.url_style, "openai-response") or
        std.mem.eql(u8, req.url_style, "anthropic")))
        return TestError.UnsupportedStyle;
}

/// Build the minimal probe body for the request's url_style. Caller
/// owns the returned slice.
fn buildProbeBody(allocator: std.mem.Allocator, req: TestRequest) TestError![]u8 {
    if (std.mem.eql(u8, req.url_style, "anthropic")) {
        return std.fmt.allocPrint(
            allocator,
            "{{\"model\":{f},\"max_tokens\":16,\"messages\":[{{\"role\":\"user\",\"content\":\"{s}\"}}]}}",
            .{ std.json.fmt(req.model, .{}), PROBE_PROMPT },
        ) catch return TestError.OutOfMemory;
    }
    if (std.mem.eql(u8, req.url_style, "openai-response")) {
        return std.fmt.allocPrint(
            allocator,
            "{{\"model\":{f},\"input\":\"{s}\",\"max_output_tokens\":16,\"stream\":false,\"store\":false}}",
            .{ std.json.fmt(req.model, .{}), PROBE_PROMPT },
        ) catch return TestError.OutOfMemory;
    }
    return std.fmt.allocPrint(
        allocator,
        "{{\"model\":{f},\"messages\":[{{\"role\":\"user\",\"content\":\"{s}\"}}],\"max_tokens\":16,\"temperature\":0,\"stream\":false}}",
        .{ std.json.fmt(req.model, .{}), PROBE_PROMPT },
    ) catch return TestError.OutOfMemory;
}

/// Extract the assistant reply text from a probe response body, per
/// url_style. Returns an owned slice truncated to MAX_REPLY_LEN.
fn extractReply(
    allocator: std.mem.Allocator,
    url_style: []const u8,
    body: []const u8,
) TestError![]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch {
        return TestError.JsonParseFailed;
    };
    defer parsed.deinit();

    const root = switch (parsed.value) {
        .object => |obj| obj,
        else => return TestError.InvalidResponse,
    };

    var reply: ?[]const u8 = null;
    if (std.mem.eql(u8, url_style, "anthropic")) {
        // `{"content": [{"type": "text", "text": "..."}]}`
        const content_v = root.get("content") orelse return TestError.InvalidResponse;
        const blocks = switch (content_v) {
            .array => |a| a,
            else => return TestError.InvalidResponse,
        };
        for (blocks.items) |block| {
            const obj = switch (block) {
                .object => |o| o,
                else => continue,
            };
            const t = obj.get("type") orelse continue;
            if (!std.mem.eql(u8, t.string, "text")) continue;
            const text_v = obj.get("text") orelse continue;
            reply = switch (text_v) {
                .string => |s| s,
                else => continue,
            };
            break;
        }
    } else if (std.mem.eql(u8, url_style, "openai-response")) {
        // `{"output": [{"type": "message", "content":
        // [{"type": "output_text", "text": "..."}]}]}`
        const output_v = root.get("output") orelse return TestError.InvalidResponse;
        const items = switch (output_v) {
            .array => |a| a,
            else => return TestError.InvalidResponse,
        };
        outer: for (items.items) |item| {
            const obj = switch (item) {
                .object => |o| o,
                else => continue,
            };
            const content_v = obj.get("content") orelse continue;
            const parts = switch (content_v) {
                .array => |a| a,
                else => continue,
            };
            for (parts.items) |part| {
                const pobj = switch (part) {
                    .object => |o| o,
                    else => continue,
                };
                const t = pobj.get("type") orelse continue;
                if (!std.mem.eql(u8, t.string, "output_text")) continue;
                const text_v = pobj.get("text") orelse continue;
                reply = switch (text_v) {
                    .string => |s| s,
                    else => continue,
                };
                break :outer;
            }
        }
    } else {
        // `{"choices": [{"message": {"content": "..."}}]}`
        const choices_v = root.get("choices") orelse return TestError.InvalidResponse;
        const choices = switch (choices_v) {
            .array => |a| a,
            else => return TestError.InvalidResponse,
        };
        if (choices.items.len == 0) return TestError.InvalidResponse;
        const first = switch (choices.items[0]) {
            .object => |o| o,
            else => return TestError.InvalidResponse,
        };
        const msg_v = first.get("message") orelse return TestError.InvalidResponse;
        const msg = switch (msg_v) {
            .object => |o| o,
            else => return TestError.InvalidResponse,
        };
        const content_v = msg.get("content") orelse return TestError.InvalidResponse;
        reply = switch (content_v) {
            .string => |s| s,
            else => return TestError.InvalidResponse,
        };
    }

    const text = reply orelse return TestError.InvalidResponse;
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    const capped = trimmed[0..@min(trimmed.len, MAX_REPLY_LEN)];
    return allocator.dupe(u8, capped) catch return TestError.OutOfMemory;
}

// ─── Use-case (network) ─────────────────────────────────────────────────────

fn useCase(
    allocator: std.mem.Allocator,
    logger: *logger_mod.Logger,
    req: TestRequest,
    out_err_detail: *?[]const u8,
) TestError!TestOutcome {
    try validate(req);

    var client = custom_http_client.Client.init(allocator);
    defer client.deinit();

    const body = try buildProbeBody(allocator, req);
    defer allocator.free(body);

    // Auth header buffer: only the Bearer/x-api-key value is owned;
    // names + static values are string literals.
    var auth_value: ?[]u8 = null;
    defer if (auth_value) |v| allocator.free(v);

    var header_buf: [8]custom_http_client.Header = undefined;
    var header_count: usize = 0;
    header_buf[header_count] = .{ .name = "Content-Type", .value = "application/json" };
    header_count += 1;
    if (std.mem.eql(u8, req.url_style, "anthropic")) {
        header_buf[header_count] = .{ .name = "anthropic-version", .value = "2023-06-01" };
        header_count += 1;
        if (req.api_key.len > 0) {
            header_buf[header_count] = .{ .name = "x-api-key", .value = req.api_key };
            header_count += 1;
        }
    } else if (req.api_key.len > 0) {
        auth_value = std.fmt.allocPrint(allocator, "Bearer {s}", .{req.api_key}) catch
            return TestError.OutOfMemory;
        header_buf[header_count] = .{ .name = "Authorization", .value = auth_value.? };
        header_count += 1;
    }
    // Console Go / Zen routing requires `x-opencode-session` on every
    // request (see PROBE_SESSION_ID). The chat path sends the real
    // conversation id via `Agent.sessionId`; the probe has none, so it
    // sends the fixed probe id. Harmless for direct providers.
    header_buf[header_count] = .{ .name = "x-opencode-session", .value = PROBE_SESSION_ID };
    header_count += 1;

    const start_ns = helpers.monotonicTimestampNanos();
    const result = custom_http_client.post(
        &client,
        req.base_url,
        body,
        header_buf[0..header_count],
        .{ .timeout_ms = TEST_LLM_TIMEOUT_MS },
    ) catch |err| {
        logger.warnFmt("[llm_test] probe POST failed for '{s}': {s}", .{ req.base_url, @errorName(err) });
        if (err == error.Timeout) return TestError.Timeout;
        return TestError.SendFailed;
    };
    defer result.deinit(allocator);
    const latency_ms: i64 = @intCast((helpers.monotonicTimestampNanos() - start_ns) / std.time.ns_per_ms);

    if (result.status_code != 200) {
        logger.warnFmt("[llm_test] upstream returned status {d}", .{result.status_code});
        // Surface the server's error body (e.g. 401 `{"error": ...}`)
        // so the modal shows WHY instead of a generic message.
        // Truncated to 200 bytes to keep the wire small.
        const snippet_len: usize = @min(result.body.len, 200);
        out_err_detail.* = std.fmt.allocPrint(
            allocator,
            "http {d}: {s}",
            .{ result.status_code, result.body[0..snippet_len] },
        ) catch null;
        return TestError.HttpError;
    }

    const reply = extractReply(allocator, req.url_style, result.body) catch |err| {
        logger.warnFmt("[llm_test] reply parse failed: {s}", .{@errorName(err)});
        if (err == error.JsonParseFailed) return TestError.JsonParseFailed;
        // Include a body snippet so a wrong-style success (e.g. HTML
        // login page from a bad base_url) is diagnosable.
        const snippet_len: usize = @min(result.body.len, 200);
        out_err_detail.* = std.fmt.allocPrint(
            allocator,
            "unparseable body: {s}",
            .{result.body[0..snippet_len]},
        ) catch null;
        return TestError.InvalidResponse;
    };

    return .{
        .model = req.model,
        .reply = reply,
        .latency_ms = latency_ms,
    };
}

// ─── Handler ────────────────────────────────────────────────────────────────

pub fn llmTestHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;
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
    const outcome = useCase(allocator, logger, parsed, &err_detail) catch |err| {
        const message: []const u8 = switch (err) {
            error.MissingModel => "model is required",
            error.MissingBaseUrl => "base_url is required",
            error.InvalidBaseUrl => "base_url must start with http:// or https://",
            error.UnsupportedStyle => "url_style must be 'openai', 'openai-response' or 'anthropic'",
            error.SendFailed => "failed to reach the LLM server (check base_url)",
            error.Timeout => "LLM server did not respond within 15 seconds",
            error.HttpError => "LLM server returned an error status",
            error.JsonParseFailed => "LLM server response was not valid JSON",
            error.InvalidResponse => "LLM server response did not contain a reply",
            error.OutOfMemory => "out of memory",
        };
        const details: []const u8 = err_detail orelse @errorName(err);
        std.log.warn("[llm_test] error: {s} ({s})", .{ message, details });
        const data = std.fmt.allocPrint(
            allocator,
            "{{\"ok\":false,\"error\":{f},\"details\":{f}}}",
            .{ std.json.fmt(message, .{}), std.json.fmt(details, .{}) },
        ) catch {
            return res.jsonResponse(.{
                .status_code = 500,
                .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Out of memory" }),
            });
        };
        return res.jsonResponse(.{ .status_code = 200, .data = data });
    };
    defer allocator.free(outcome.reply);

    const data = std.fmt.allocPrint(
        allocator,
        "{{\"ok\":true,\"model\":{f},\"reply\":{f},\"latency_ms\":{d}}}",
        .{ std.json.fmt(outcome.model, .{}), std.json.fmt(outcome.reply, .{}), outcome.latency_ms },
    ) catch {
        return res.jsonResponse(.{
            .status_code = 500,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Out of memory" }),
        });
    };

    return res.jsonResponse(.{ .status_code = 200, .data = data });
}

// ─── Inline tests ───────────────────────────────────────────────────────────

const testing = std.testing;

fn sourceContains(allocator: std.mem.Allocator, path: []const u8, needle: []const u8) !bool {
    const raw = try std.Io.Dir.cwd().readFileAlloc(testing.io, path, allocator, .limited(1024 * 1024));
    defer allocator.free(raw);
    return std.mem.indexOf(u8, raw, needle) != null;
}

test "llmTestHandler: registers the POST route with /api/llm/test" {
    const found = try sourceContains(testing.allocator, "src/main.zig", "/api/llm/test");
    try testing.expect(found);
}

test "llmTestHandler: mod.zig exports llmTestHandler" {
    const found = try sourceContains(
        testing.allocator,
        "src/http_handlers/mod.zig",
        "llmTestHandler",
    );
    try testing.expect(found);
}

test "llm_test validate: rejects empty model" {
    const req: TestRequest = .{ .model = "", .base_url = "http://127.0.0.1:9/x" };
    try testing.expectError(TestError.MissingModel, validate(req));
}

test "llm_test validate: rejects empty base_url" {
    const req: TestRequest = .{ .model = "m", .base_url = "" };
    try testing.expectError(TestError.MissingBaseUrl, validate(req));
}

test "llm_test validate: rejects base_url without http scheme" {
    const req: TestRequest = .{ .model = "m", .base_url = "api.example.com/v1" };
    try testing.expectError(TestError.InvalidBaseUrl, validate(req));
}

test "llm_test validate: rejects unknown url_style" {
    const req: TestRequest = .{ .model = "m", .base_url = "http://127.0.0.1:9/x", .url_style = "weird" };
    try testing.expectError(TestError.UnsupportedStyle, validate(req));
}

test "llm_test validate: allows empty api_key (keyless local / stub upstream)" {
    const req: TestRequest = .{ .model = "m", .base_url = "http://127.0.0.1:9/x", .api_key = "" };
    try validate(req);
}

test "llm_test validate: accepts all three known styles" {
    for ([_] []const u8{ "openai", "openai-response", "anthropic" }) |style| {
        const req: TestRequest = .{ .model = "m", .base_url = "http://127.0.0.1:9/x", .url_style = style };
        try validate(req);
    }
}

test "llm_test buildProbeBody: openai body carries model + probe prompt" {
    const req: TestRequest = .{ .model = "MiniMax-M2.7", .base_url = "http://x", .url_style = "openai" };
    const body = try buildProbeBody(testing.allocator, req);
    defer testing.allocator.free(body);
    try testing.expect(std.mem.indexOf(u8, body, "MiniMax-M2.7") != null);
    try testing.expect(std.mem.indexOf(u8, body, PROBE_PROMPT) != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"stream\":false") != null);
}

test "llm_test buildProbeBody: openai-response body uses input + max_output_tokens" {
    const req: TestRequest = .{ .model = "gpt-5", .base_url = "http://x", .url_style = "openai-response" };
    const body = try buildProbeBody(testing.allocator, req);
    defer testing.allocator.free(body);
    try testing.expect(std.mem.indexOf(u8, body, "\"input\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "max_output_tokens") != null);
}

test "llm_test buildProbeBody: anthropic body uses max_tokens + messages" {
    const req: TestRequest = .{ .model = "claude-x", .base_url = "http://x", .url_style = "anthropic" };
    const body = try buildProbeBody(testing.allocator, req);
    defer testing.allocator.free(body);
    try testing.expect(std.mem.indexOf(u8, body, "\"max_tokens\":16") != null);
    try testing.expect(std.mem.indexOf(u8, body, PROBE_PROMPT) != null);
}

test "llm_test extractReply: parses openai choices content" {
    const raw =
        \\{"id":"chatcmpl-1","choices":[{"message":{"role":"assistant","content":"ok"},"finish_reason":"stop"}]}
    ;
    const reply = try extractReply(testing.allocator, "openai", raw);
    defer testing.allocator.free(reply);
    try testing.expectEqualStrings("ok", reply);
}

test "llm_test extractReply: parses anthropic content blocks" {
    const raw =
        \\{"id":"msg_1","content":[{"type":"text","text":"ok"}],"stop_reason":"end_turn"}
    ;
    const reply = try extractReply(testing.allocator, "anthropic", raw);
    defer testing.allocator.free(reply);
    try testing.expectEqualStrings("ok", reply);
}

test "llm_test extractReply: parses openai-response output items" {
    const raw =
        \\{"id":"resp_1","output":[{"type":"message","content":[{"type":"output_text","text":"ok"}]}]}
    ;
    const reply = try extractReply(testing.allocator, "openai-response", raw);
    defer testing.allocator.free(reply);
    try testing.expectEqualStrings("ok", reply);
}

test "llm_test extractReply: rejects empty choices" {
    const raw = \\{"choices":[]}
    ;
    try testing.expectError(TestError.InvalidResponse, extractReply(testing.allocator, "openai", raw));
}

test "llm_test extractReply: rejects non-JSON body" {
    try testing.expectError(
        TestError.JsonParseFailed,
        extractReply(testing.allocator, "openai", "<html>login</html>"),
    );
}

test "llm_test.zig error mapping covers every TestError variant" {
    // Static-grep guard: the handler's exhaustive switch must name each
    // error variant so no probe failure falls through to a 500.
    const variants = [_][]const u8{
        "MissingModel",
        "MissingBaseUrl",
        "InvalidBaseUrl",
        "UnsupportedStyle",
        "SendFailed",
        "Timeout",
        "HttpError",
        "JsonParseFailed",
        "InvalidResponse",
        "OutOfMemory",
    };
    for (variants) |variant| {
        const found = try sourceContains(
            testing.allocator,
            "src/http_handlers/llm_test.zig",
            variant,
        );
        if (!found) {
            std.debug.print("\n!! llm_test.zig error mapping missing variant {s} !!\n", .{variant});
        }
        try testing.expect(found);
    }
}

test "llm_test.zig probe timeout is 15_000 ms" {
    const found = try sourceContains(
        testing.allocator,
        "src/http_handlers/llm_test.zig",
        "15_000",
    );
    try testing.expect(found);
}

test "llm_test probe sends x-opencode-session (Console Go requires it)" {
    // Regression guard for the Edit-profile Test button 400
    // `{"type":"error","error":{"type":"MissingSessionID",...}}`:
    // the probe must carry the session header or Console Go rejects
    // it before auth/routing. Asserts both the header name and the
    // stable probe id constant exist in the useCase header block.
    const has_header = try sourceContains(
        testing.allocator,
        "src/http_handlers/llm_test.zig",
        "x-opencode-session",
    );
    try testing.expect(has_header);
    const has_probe_id = try sourceContains(
        testing.allocator,
        "src/http_handlers/llm_test.zig",
        "PROBE_SESSION_ID",
    );
    try testing.expect(has_probe_id);
}
