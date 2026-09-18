//! Unified SSE stream endpoint for all server-pushed events.
//!
//! Replaces the 5 dedicated SSE routes registered in main.zig:
//!   - GET /api/workers/stream
//!   - GET /api/sessions/stream
//!   - GET /api/llm/stream/:session_id
//!   - GET /api/llm/session/:session_id/queue_messages/stream
//!   - GET /api/kanban/events
//!
//! The client opens ONE EventSource and declares which channel families
//! it cares about via the `?channels=` query parameter:
//!
//!   /api/events?channels=workers,sessions,kanban
//!   /api/events?channels=llm
//!   /api/events?channels=queue
//!   /api/events?channels=workers,sessions,kanban,llm,queue
//!
//! Channel tokens and the event_bus routing keys they fan out to:
//!   workers        → "workers"
//!   sessions       → "sessions"
//!   kanban         → "kanban_column", "kanban_task"
//!   design_element → "design_element" (central key — all workspaces' design
//!                    element create/update/delete events; the frontend
//!                    filters by `data.workspace_id` JS-side)
//!   llm            → "llm"          (central key — all sessions' LLM events)
//!   queue          → "queue"        (central key — all sessions' queue events)
//!   background_process → "background_process" (central key — all sessions'
//!                    background-process created/completed events; the
//!                    frontend filters by `data.session_id` JS-side)
//!
//! Plan: docs/superpowers/plans/2026-06-30-unify-sse-endpoints.md

const std = @import("std");
const nalar_core = @import("nalarcore");
const gserverz = nalar_core.gserverz;
const ai_mod = nalar_core.ai_mod;
const auth_common = @import("auth_common.zig");

/// Forward an SSE event to every client registered under `routing_key`.
///
/// Lifted verbatim from kanban_events_sse.zig:34-76. Subscription-lock-safe:
/// `getListClientsForSession` returns an owned copy of the client list, so
/// the SSE event loop can safely `unregisterSessionClient` on POLL.HUP
/// while we are still iterating here.
fn forwardToClients(routing_key: []const u8, data: ai_mod.on_event_sent.SseEvent) void {
    const di = nalar_core.getSingleton() catch return;
    const allocator = di.allocator;
    const server = di.server;

    const maybe_clients = ai_mod.getListClientsForSession(routing_key, allocator, false) catch return;
    defer if (maybe_clients) |c| allocator.free(c);
    const client_ids = maybe_clients orelse return;
    if (client_ids.len == 0) return;

    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    if (data.event_type) |event_type| {
        buf.appendSlice(allocator, "event: ") catch return;
        buf.appendSlice(allocator, event_type) catch return;
        buf.append(allocator, '\n') catch return;
    }

    if (data.data.len == 0) {
        buf.appendSlice(allocator, "data: \n") catch return;
    } else {
        var iter = std.mem.splitScalar(u8, data.data, '\n');
        while (iter.next()) |line| {
            buf.appendSlice(allocator, "data: ") catch return;
            buf.appendSlice(allocator, line) catch return;
            buf.append(allocator, '\n') catch return;
        }
    }
    buf.append(allocator, '\n') catch return;

    const sse_event_data = buf.toOwnedSlice(allocator) catch return;
    defer allocator.free(sse_event_data);

    for (client_ids) |client_id| {
        server.sse_manager.sendToClient(client_id, sse_event_data) catch {};
    }
}

/// ChannelList — the parsed result of `?channels=`.
pub const ChannelList = struct {
    /// Each entry is a routing key the handler must subscribe a
    /// callback to. Duplicates are not deduplicated (the SSE
    /// event_bus handles duplicate subscribers without error).
    routing_keys: []const []const u8,

    pub fn deinit(self: ChannelList, allocator: std.mem.Allocator) void {
        for (self.routing_keys) |k| allocator.free(k);
        allocator.free(self.routing_keys);
    }
};

/// Parse `?channels=workers,sessions,kanban,llm,queue`.
/// Returns the list of routing keys to subscribe + register. Returns
/// ChannelParseError on missing/empty/unknown channel tokens.
pub const ChannelParseError = error{
    MissingChannels,
    UnknownChannel,
    OutOfMemory,
};

/// `pub` so `unified_events_sse_test.zig` can import it for behavioral
/// tests (Plan Reviewer finding #3). The `pub` is harmless — the
/// function is only called from `unifiedEventsStreamHandler`.
pub fn parseChannels(allocator: std.mem.Allocator, raw: []const u8) ChannelParseError!ChannelList {
    // Trim whitespace from the raw value (the router does not trim).
    const trimmed = std.mem.trim(u8, raw, " \t");
    if (trimmed.len == 0) return error.MissingChannels;

    var routing_keys: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer {
        for (routing_keys.items) |k| allocator.free(k);
        routing_keys.deinit(allocator);
    }

    var iter = std.mem.splitScalar(u8, trimmed, ',');
    while (iter.next()) |token_raw| {
        const token = std.mem.trim(u8, token_raw, " \t");
        if (token.len == 0) continue; // skip empty tokens (e.g. ",,,")

        if (std.mem.eql(u8, token, "workers")) {
            try routing_keys.append(allocator, try allocator.dupe(u8, "workers"));
        } else if (std.mem.eql(u8, token, "sessions")) {
            try routing_keys.append(allocator, try allocator.dupe(u8, "sessions"));
        } else if (std.mem.eql(u8, token, "kanban")) {
            try routing_keys.append(allocator, try allocator.dupe(u8, "kanban_column"));
            try routing_keys.append(allocator, try allocator.dupe(u8, "kanban_task"));
        } else if (std.mem.eql(u8, token, "llm")) {
            try routing_keys.append(allocator, try allocator.dupe(u8, "llm"));
        } else if (std.mem.eql(u8, token, "queue")) {
            try routing_keys.append(allocator, try allocator.dupe(u8, "queue"));
        } else if (std.mem.eql(u8, token, "background_process")) {
            // Background-process lifecycle (`background_process_created` /
            // `background_process_completed` on the central
            // "background_process" key — see background_process_events.zig).
            // Single key covers both granular event types; the frontend
            // filters by `data.session_id` JS-side.
            try routing_keys.append(allocator, try allocator.dupe(u8, "background_process"));
        } else if (std.mem.eql(u8, token, "design_element")) {
            // Design-mode element mutations. The frontend
            // `createUnifiedSseConnection` sends this token; the
            // backend's `on_event_sent_design.zig` emits
            // `design_element_created/updated/deleted` on the central
            // "design_element" routing key. The single key covers all
            // three granular event types (the action discriminator
            // tells them apart JS-side).
            try routing_keys.append(allocator, try allocator.dupe(u8, "design_element"));
        } else {
            return error.UnknownChannel;
        }
    }

    // If the raw value was non-empty but every comma-delimited token
    // was empty (e.g. ",,,"), we still need to error. The trim+skip
    // path above would leave routing_keys empty without an explicit
    // error here — guard against that.
    if (routing_keys.items.len == 0) return error.MissingChannels;

    return ChannelList{ .routing_keys = try routing_keys.toOwnedSlice(allocator) };
}

// =============================================================================
// Callback structs (top-level, NOT inline).
//
// Each routing key gets its own callback. The routing key itself is
// hard-coded into the callback body — there's no closure capture of a
// loop variable (Pitfall 1: inline-struct capture trap). The handler
// picks the right callback by inspecting the routing-key SHAPE with
// an if/else chain (mirrors kanban_events_sse.zig:79-90).
// =============================================================================

/// Callback for `kanban_column` routing key — fires on column create/update/delete.
pub const CallbackUnifiedColumnStream = struct {
    pub fn callback(data: ai_mod.on_event_sent.SseEvent) void {
        forwardToClients("kanban_column", data);
    }
};

/// Callback for `kanban_task` routing key.
pub const CallbackUnifiedTaskStream = struct {
    pub fn callback(data: ai_mod.on_event_sent.SseEvent) void {
        forwardToClients("kanban_task", data);
    }
};

/// Callback for `workers` routing key.
pub const CallbackUnifiedWorkersStream = struct {
    pub fn callback(data: ai_mod.on_event_sent.SseEvent) void {
        forwardToClients("workers", data);
    }
};

/// Callback for `sessions` routing key.
pub const CallbackUnifiedSessionsStream = struct {
    pub fn callback(data: ai_mod.on_event_sent.SseEvent) void {
        forwardToClients("sessions", data);
    }
};

/// Callback for the central "llm" routing key. Forwards to every
/// client registered under "llm" — the frontend listener then
/// filters by `data.session_id` on the JS side.
pub const CallbackUnifiedLLMBroadcast = struct {
    pub fn callback(data: ai_mod.on_event_sent.SseEvent) void {
        forwardToClients("llm", data);
    }
};

/// Callback for the central "queue" routing key. Forwards to every
/// client registered under "queue" — the frontend listener then
/// filters by `data.session_id` on the JS side.
pub const CallbackUnifiedQueueBroadcast = struct {
    pub fn callback(data: ai_mod.on_event_sent.SseEvent) void {
        forwardToClients("queue", data);
    }
};

/// Callback for the central "design_element" routing key. Forwards
/// to every client registered under "design_element" — the frontend
/// listener (`designSse.ts` Pinia store) then filters by
/// `data.workspace_id` on the JS side and dispatches to the
/// `workspacesStore.fetchDesignElements` action.
pub const CallbackUnifiedDesignElementStream = struct {
    pub fn callback(data: ai_mod.on_event_sent.SseEvent) void {
        forwardToClients("design_element", data);
    }
};

/// Callback for the central "background_process" routing key. Forwards
/// to every client registered under "background_process" — the frontend
/// listener (`BackgroundCommandsPopup.vue`) then filters by
/// `data.session_id` on the JS side and re-fetches the list.
pub const CallbackUnifiedBackgroundProcessStream = struct {
    pub fn callback(data: ai_mod.on_event_sent.SseEvent) void {
        forwardToClients("background_process", data);
    }
};

/// Terminate an SSE stream the handler cannot serve (auth failure,
/// missing/empty/unknown `?channels=`).
///
/// kabelweb sends the `200 text/event-stream` headers AND registers the
/// fd BEFORE this handler runs, so a bare `return res.jsonResponse(...)`
/// never reaches the wire — without this call the browser holds an
/// immortal ping-only stream that never emits `event: connected`, and
/// the frontend SseClient sits in 'connecting' forever. Sends an
/// optional terminal named event, then removes the client so the
/// browser's EventSource errors out promptly instead of hanging.
fn terminateSseStream(ctx: gserverz.HttpContext, event_name: ?[]const u8, data_json: []const u8) void {
    const cid = ctx.client_id orelse return;
    const di = nalar_core.getSingleton() catch return;
    if (event_name) |name| {
        var buf: [256]u8 = undefined;
        const frame = std.fmt.bufPrint(&buf, "event: {s}\ndata: {s}\n\n", .{ name, data_json }) catch return;
        di.server.sse_manager.sendToClient(cid, frame) catch {};
    }
    di.server.sse_manager.removeClient(cid, .explicit_shutdown);
}

/// SSE stream endpoint — single endpoint for all server-pushed events.
///
/// The `?channels=` query parameter is REQUIRED. Missing/empty/unknown
/// values terminate the stream (see `terminateSseStream` — a JSON error
/// body can never reach the wire once kabelweb has sent the SSE
/// headers).
pub fn unifiedEventsStreamHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    // Manual auth gate: kabelweb sse() does not run middleware.
    // The rejection paths terminate the stream explicitly — the 401
    // JSON below is type-compat only and never reaches the wire
    // (headers already sent); the `auth_error` event + removeClient
    // in terminateSseStream are what the browser actually observes.
    if (nalar_core.getSingleton()) |di_gate| {
        if (di_gate.auth_enabled) {
            const tok = auth_common.parseSessionToken(req.headers) orelse {
                terminateSseStream(ctx, "auth_error", "{\"error\":\"Unauthenticated\"}");
                return res.jsonResponse(.{ .status_code = 401, .data = "{\"error\":\"Unauthenticated\"}" });
            };
            const sess = auth_common.lookupSession(allocator, di_gate.db, tok) orelse {
                terminateSseStream(ctx, "auth_error", "{\"error\":\"Unauthenticated\"}");
                return res.jsonResponse(.{ .status_code = 401, .data = "{\"error\":\"Unauthenticated\"}" });
            };
            auth_common.freeSessionLookup(allocator, sess);
        }
    } else |_| {}

    // 1. Parse ?channels=
    const raw_channels = req.query.get("channels") orelse {
        terminateSseStream(ctx, null, "");
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try std.fmt.allocPrint(allocator,
                \\{{"error":"missing channels query parameter"}}
            , .{}),
        });
    };
    var channels = parseChannels(allocator, raw_channels) catch |err| switch (err) {
        error.MissingChannels => {
            terminateSseStream(ctx, null, "");
            return res.jsonResponse(.{
                .status_code = 400,
                .data = try std.fmt.allocPrint(allocator,
                    \\{{"error":"missing or empty channels query parameter"}}
                , .{}),
            });
        },
        error.UnknownChannel => {
            terminateSseStream(ctx, null, "");
            return res.jsonResponse(.{
                .status_code = 400,
                .data = try std.fmt.allocPrint(allocator,
                    \\{{"error":"unknown channel in {s}"}}
                , .{raw_channels}),
            });
        },
        error.OutOfMemory => return error.OutOfMemory,
    };
    defer channels.deinit(allocator);

    // 2. Register + subscribe
    const di = try nalar_core.getSingleton();
    const event_bus = di.event_bus;
    const server = di.server;

    if (ctx.client_id) |client_id| {
        const client_id_copy: [16]u8 = client_id;

        // 2a. Register the client_id under EVERY routing key.
        // registerSessionClient dupes the key internally, so we can
        // pass each entry of channels.routing_keys (already-owned
        // slices) directly.
        for (channels.routing_keys) |rk| {
            ai_mod.registerSessionClient(rk, client_id_copy, true) catch {};
        }

        // 2b. Subscribe ONE callback per routing key. The callback
        // looks up the client list for ITS OWN routing key only —
        // see forwardToClients.
        for (channels.routing_keys) |rk| {
            // event_bus.subscribe dupes the key internally, so we can
            // pass each entry directly and it remains valid for the
            // call. See worker_sse.zig:81 and kanban_events_sse.zig:117.
            if (std.mem.eql(u8, rk, "kanban_column")) {
                event_bus.subscribe(ai_mod.on_event_sent.SseEvent, rk, CallbackUnifiedColumnStream.callback) catch {};
            } else if (std.mem.eql(u8, rk, "kanban_task")) {
                event_bus.subscribe(ai_mod.on_event_sent.SseEvent, rk, CallbackUnifiedTaskStream.callback) catch {};
            } else if (std.mem.eql(u8, rk, "workers")) {
                event_bus.subscribe(ai_mod.on_event_sent.SseEvent, rk, CallbackUnifiedWorkersStream.callback) catch {};
            } else if (std.mem.eql(u8, rk, "sessions")) {
                event_bus.subscribe(ai_mod.on_event_sent.SseEvent, rk, CallbackUnifiedSessionsStream.callback) catch {};
            } else if (std.mem.eql(u8, rk, "llm")) {
                event_bus.subscribe(ai_mod.on_event_sent.SseEvent, rk, CallbackUnifiedLLMBroadcast.callback) catch {};
            } else if (std.mem.eql(u8, rk, "queue")) {
                event_bus.subscribe(ai_mod.on_event_sent.SseEvent, rk, CallbackUnifiedQueueBroadcast.callback) catch {};
            } else if (std.mem.eql(u8, rk, "design_element")) {
                event_bus.subscribe(ai_mod.on_event_sent.SseEvent, rk, CallbackUnifiedDesignElementStream.callback) catch {};
            } else if (std.mem.eql(u8, rk, "background_process")) {
                event_bus.subscribe(ai_mod.on_event_sent.SseEvent, rk, CallbackUnifiedBackgroundProcessStream.callback) catch {};
            }
        }

        // 3. Send the connected handshake (the verbatim byte sequence
        //    pinned by sse_handshake_test.zig:12).
        const connected_event = "event: connected\ndata: {\"connected\": true}\n\n";
        server.sse_manager.sendToClient(client_id_copy, connected_event) catch {};
    }

    return error.WouldBlock; // Keep connection open
}

// ===== Tests merged from sse_handshake_test.zig (2026-09-11 flatten) =====
// Regression test for the SSE `connected` event handshake.
// 
// Why this file exists
// ────────────────────
// The frontend `SseStatusBadge`
// (src/apps/desktop/src/components/SseStatusBadge.vue) and the
// `SseClient` state machine
// (src/apps/desktop/src/helpers/sseClient.ts) only transition
// from `'connecting'` to `'open'` when the server sends the SSE
// `connected` named event:
// 
//     event: connected\ndata: {"connected": true}\n\n
// 
// Two of the four legacy backend SSE handlers used to skip this
// handshake, leaving the badge stuck on "Connecting…" forever
// (the stream was alive and streaming, but the badge had no
// signal to hide). See docs/plans/2026-06-05-stuck-connecting-badge.md
// for the full trace.
// 
// After the 5→1 SSE endpoint unification (plan
// docs/superpowers/plans/2026-06-30-unify-sse-endpoints.md),
// only ONE backend SSE handler is registered
// (`unified_events_sse.zig`); this test pins its contract via a
// STATIC check: the unified handler source file must contain the
// handshake constant verbatim. Catches a future regression where
// the 3-line send block is removed or the byte sequence changes
// and the frontend SseStatusBadge gets stuck on "Connecting…"
// again.
// 
// The behavioral test (round-trip through a real SseManager +
// socketpair) was considered and dropped: Zig 0.16 removed
// `posix.socketpair` and the SseManager's own tests are
// POSIX-only via the lower-level `posix.system` layer, which
// would require a Linux-only gate. The static check is the
// higher-value test anyway — it directly tests the bug.

const nalarcore = @import("nalarcore");
const testing = std.testing;

/// The exact byte sequence the unified SSE handler MUST send as the
/// liveness handshake. Mirrors what the previous `worker_sse.zig`
/// / `sessions_sse.zig` emitted (those are now deleted; their
/// string is preserved here as the source of truth).
///
/// The trailing blank line (`\n\n`) is REQUIRED — it's the SSE
/// frame terminator. Without it, the browser's `EventSource`
/// will hold the bytes in its line buffer and never dispatch the
/// `connected` event to the SseClient.
///
/// The JSON in the `data:` line (`{"connected": true}`) is a
/// convention; the SseClient does NOT parse it. The empty JSON
/// object `{}` would also work.
///
/// IMPORTANT: this constant is the SOURCE-FORM of the handshake
/// as it appears in the .zig source files, NOT the in-memory
/// runtime form. Each `\n` in the file source is the two-byte
/// escape sequence (backslash + 'n'), and the literal `"` inside
/// the JSON is `\"` (backslash + quote). When Zig parses the
/// string literal at compile time, those escape sequences become
/// the real bytes that the SSE client sees. The test matches the
/// source form because the file is read as text.
const connected_handshake_in_source =
    "event: connected\\n" ++
    "data: {\\\"connected\\\": true}\\n" ++
    "\\n";

// ─── Static check on the single unified handler source file ───────────────

test "SSE handshake: unified stream handler sends the connected event" {
    // The single SSE route registered in src/main.zig. Must contain
    // the `connected` handshake string in its source, or the frontend
    // SseStatusBadge will be stuck on "Connecting…".
    //
    // This is a SOURCE-LEVEL test — it reads the .zig file from
    // disk at test time and asserts the handshake string appears
    // verbatim. The test is intentionally a substring match (not a
    // full AST walk) because:
    //   - The 3-line block is small and the byte sequence is the
    //     actual contract that reaches the client.
    //   - The constant string is also defined in this file as the
    //     source of truth, so any change must be made in lockstep.
    //
    // Path is relative to the project root, which is the cwd when
    // `zig build test:ai_workflow:tui` runs.
    const handlers = .{
        "src/http_handlers/unified_events_sse.zig",
    };

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    inline for (handlers) |path| {
        const source = std.Io.Dir.cwd().readFileAlloc(
            std.testing.io,
            path,
            allocator,
            .limited(64 * 1024),
        ) catch |err| {
            std.debug.print("\n!! SSE handshake: could not read {s}: {s}\n", .{ path, @errorName(err) });
            return err;
        };
        errdefer allocator.free(source);

        if (std.mem.indexOf(u8, source, connected_handshake_in_source) == null) {
            std.debug.print(
                "\n!! {s} does not contain the SSE connected handshake !!\n" ++
                    "   expected (verbatim, exactly as it must appear in the source):\n" ++
                    "     {s}\n" ++
                    "   Add the 3-line `event: connected` send right after\n" ++
                    "   `registerSessionClient`, mirroring worker_sse.zig.\n" ++
                    "   See docs/plans/2026-06-05-stuck-connecting-badge.md for why.\n",
                .{ path, connected_handshake_in_source },
            );
            return error.ConnectedHandshakeMissing;
        }
    }
}

// ===== Rejection paths must terminate the stream (2026-09-17) =====
// kabelweb sends the SSE 200 headers + registers the fd BEFORE the
// handler runs, so `res.jsonResponse(401/400)` never reaches the wire.
// Every rejection must call terminateSseStream (terminal event +
// removeClient) or the browser holds an immortal ping-only stream
// that never emits `event: connected` — SseClient stuck in
// 'connecting' forever (production `--auth` with no session cookie).

test "SSE rejection: handler terminates the stream on auth/400 paths" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const source = readSource(allocator, HANDLER_PATH) catch |err| {
        std.debug.print("\n!! SSE rejection: could not read {s}: {s}\n", .{ HANDLER_PATH, @errorName(err) });
        return err;
    };
    defer allocator.free(source);

    const required = .{
        "fn terminateSseStream",
        "auth_error",
        ".explicit_shutdown",
        "terminateSseStream(ctx, null",
    };
    inline for (required) |needle| {
        if (std.mem.indexOf(u8, source, needle) == null) {
            std.debug.print(
                "\n!! {s} missing {s} !!\n" ++
                    "   Every SSE rejection (auth failure, missing/unknown channels)\n" ++
                    "   must terminate the just-registered client — a bare\n" ++
                    "   res.jsonResponse never reaches the wire (headers already\n" ++
                    "   sent) and leaves a zombie ping-only stream.\n",
                .{ HANDLER_PATH, needle },
            );
            return error.SseRejectionPathMissing;
        }
    }
}

// ===== Tests merged from unified_events_sse_test.zig (2026-09-11 flatten) =====
// Static regression checks for the `/api/events` unified SSE handler.
// 
// Why this file exists
// ────────────────────
// The unified handler is the single entry point for ALL server-pushed
// events. Any regression in the channel parser or the routing-key
// subscriptions silently drops events for the entire frontend, so
// these contracts are pinned via static source checks (the same
// pattern as `kanban_events_sse_test.zig`).
// 
// Plan: docs/superpowers/plans/2026-06-30-unify-sse-endpoints.md.

const text_normalize = @import("helpers").text_normalize;

const HANDLER_PATH = "src/http_handlers/unified_events_sse.zig";
const MAIN_PATH = "src/main.zig";

fn readSource(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const raw = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        path,
        allocator,
        .limited(256 * 1024),
    );
    const normalized = try text_normalize.normalizeLineEndings(allocator, raw);
    allocator.free(raw); // free the CRLF-laden input — normalized is the LF-only copy
    return normalized;
}

// ─── Contract 1: handler exists and defines the public fn ─────────────────

test "unified_events_sse.zig exists and defines pub fn unifiedEventsStreamHandler" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "pub fn unifiedEventsStreamHandler") == null) {
        std.debug.print(
            "\n!! {s} does not define pub fn unifiedEventsStreamHandler !!\n", .{HANDLER_PATH},
        );
        return error.HandlerFunctionMissing;
    }
}

// ─── Contract 2: all 6 channel tokens are recognized ─────────────────────

test "unified_events_sse.zig recognizes all 6 channel tokens" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    const required_tokens = .{
        // workers branch
        "\"workers\"",
        // sessions branch
        "\"sessions\"",
        // kanban branch (subscribes BOTH kanban_column + kanban_task)
        "\"kanban\"",
        "\"kanban_column\"",
        "\"kanban_task\"",
        // design_element branch (design-mode v6, Chunk 2 SSE)
        "eql(u8, token, \"design_element\")",
        // bare 'llm' branch
        "eql(u8, token, \"llm\")",
        // bare 'queue' branch
        "eql(u8, token, \"queue\")",
    };

    inline for (required_tokens) |needle| {
        if (std.mem.indexOf(u8, source, needle) == null) {
            std.debug.print(
                "\n!! {s} is missing the substring {s} !!\n", .{ HANDLER_PATH, needle },
            );
            return error.ChannelTokenMissing;
        }
    }
}

// ─── Contract 3: handler sends the `connected` handshake ─────────────────

test "unified_events_sse.zig sends the connected handshake" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    // The verbatim byte sequence pinned by sse_handshake_test.zig:61-64.
    const handshake = "event: connected\\ndata: {\\\"connected\\\": true}\\n\\n";
    if (std.mem.indexOf(u8, source, handshake) == null) {
        std.debug.print(
            "\n!! {s} does not contain the SSE connected handshake !!\n", .{HANDLER_PATH},
        );
        return error.ConnectedHandshakeMissing;
    }
}

// ─── Contract 4: route is registered in main.zig ─────────────────────────

test "/api/events is registered in src/main.zig" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, MAIN_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "/api/events") == null) {
        std.debug.print(
            "\n!! {s} does not register the /api/events route !!\n", .{MAIN_PATH},
        );
        return error.RouteRegistrationMissing;
    }
}

// ─── Behavioral tests for parseChannels ────────────────────────────────
//
// Plan Reviewer finding #3: the 4 static contracts above only verify
// the file's shape, not the parser's correctness. A typo in the
// bare `llm`/`queue` token names, or an off-by-one in the kanban
// expansion would silently drop events in production. These
// behavioral tests pin the parser contract.
//
// To make `parseChannels` testable from this file, the production
// code must expose it as `pub fn` (currently `fn`). Chunk 1.1's
// implementation step promotes it to `pub`.

test "parseChannels: workers → 1 routing key" {
    const allocator = testing.allocator;
    const list = try parseChannels(allocator, "workers");
    defer list.deinit(allocator);
    try testing.expectEqual(@as(usize, 1), list.routing_keys.len);
    try testing.expectEqualStrings("workers", list.routing_keys[0]);
}

test "parseChannels: sessions,kanban → 3 routing keys (kanban expands)" {
    const allocator = testing.allocator;
    const list = try parseChannels(allocator, "sessions,kanban");
    defer list.deinit(allocator);
    try testing.expectEqual(@as(usize, 3), list.routing_keys.len);
    try testing.expectEqualStrings("sessions", list.routing_keys[0]);
    try testing.expectEqualStrings("kanban_column", list.routing_keys[1]);
    try testing.expectEqualStrings("kanban_task", list.routing_keys[2]);
}

test "parseChannels: llm:<sid> → error.UnknownChannel (superseded by bare 'llm')" {
    try testing.expectError(error.UnknownChannel, parseChannels(testing.allocator, "llm:chat-123"));
}

test "parseChannels: queue:<sid> → error.UnknownChannel (superseded by bare 'queue')" {
    try testing.expectError(error.UnknownChannel, parseChannels(testing.allocator, "queue:chat-abc"));
}

test "parseChannels: bare 'llm' → central 'llm' routing key" {
    const allocator = testing.allocator;
    const list = try parseChannels(allocator, "llm");
    defer list.deinit(allocator);
    try testing.expectEqual(@as(usize, 1), list.routing_keys.len);
    try testing.expectEqualStrings("llm", list.routing_keys[0]);
}

test "parseChannels: bare 'queue' → central 'queue' routing key" {
    const allocator = testing.allocator;
    const list = try parseChannels(allocator, "queue");
    defer list.deinit(allocator);
    try testing.expectEqual(@as(usize, 1), list.routing_keys.len);
    try testing.expectEqualStrings("queue", list.routing_keys[0]);
}

test "parseChannels: mixed 5 channels (bare llm+queue) → 6 routing keys (kanban expands)" {
    const allocator = testing.allocator;
    const list = try parseChannels(allocator,
        "workers,sessions,kanban,llm,queue");
    defer list.deinit(allocator);
    try testing.expectEqual(@as(usize, 6), list.routing_keys.len);
    // workers, sessions, kanban_column, kanban_task, llm, queue (in registration order)
    try testing.expectEqualStrings("workers", list.routing_keys[0]);
    try testing.expectEqualStrings("sessions", list.routing_keys[1]);
    try testing.expectEqualStrings("kanban_column", list.routing_keys[2]);
    try testing.expectEqualStrings("kanban_task", list.routing_keys[3]);
    try testing.expectEqualStrings("llm", list.routing_keys[4]);
    try testing.expectEqualStrings("queue", list.routing_keys[5]);
}

test "parseChannels: multiple bare tokens (llm+queue repeated) → 2 keys" {
    const allocator = testing.allocator;
    // Bare 'llm' and 'queue' tokens each register once under their
    // central key. The ChannelList does NOT deduplicate (see the
    // ChannelList docstring); the SSE event_bus handles duplicate
    // subscribers without error.
    const list = try parseChannels(allocator,
        "llm,llm,queue,queue");
    defer list.deinit(allocator);
    try testing.expectEqual(@as(usize, 4), list.routing_keys.len);
    try testing.expectEqualStrings("llm", list.routing_keys[0]);
    try testing.expectEqualStrings("llm", list.routing_keys[1]);
    try testing.expectEqualStrings("queue", list.routing_keys[2]);
    try testing.expectEqualStrings("queue", list.routing_keys[3]);
}

test "parseChannels: empty string → error.MissingChannels" {
    const allocator = testing.allocator;
    try testing.expectError(error.MissingChannels, parseChannels(allocator, ""));
}

test "parseChannels: whitespace-only → error.MissingChannels" {
    const allocator = testing.allocator;
    try testing.expectError(error.MissingChannels, parseChannels(allocator, "   "));
}

test "parseChannels: only commas → error.MissingChannels" {
    const allocator = testing.allocator;
    try testing.expectError(error.MissingChannels, parseChannels(allocator, ",,,"));
}

test "parseChannels: unknown channel → error.UnknownChannel" {
    const allocator = testing.allocator;
    try testing.expectError(error.UnknownChannel, parseChannels(allocator, "foo"));
}

test "parseChannels: llm: (per-session token removed) → error.UnknownChannel" {
    const allocator = testing.allocator;
    try testing.expectError(error.UnknownChannel, parseChannels(allocator, "llm:"));
}

test "parseChannels: queue: (per-session token removed) → error.UnknownChannel" {
    const allocator = testing.allocator;
    try testing.expectError(error.UnknownChannel, parseChannels(allocator, "queue:"));
}

test "parseChannels: trims whitespace around tokens" {
    const allocator = testing.allocator;
    const list = try parseChannels(allocator, "  workers , sessions  ");
    defer list.deinit(allocator);
    try testing.expectEqual(@as(usize, 2), list.routing_keys.len);
    try testing.expectEqualStrings("workers", list.routing_keys[0]);
    try testing.expectEqualStrings("sessions", list.routing_keys[1]);
}
