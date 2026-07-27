const std = @import("std");
const linux = std.posix.system;
const gserverz = @import("http_server.zig");

// implementation http server custom
pub fn main(init: std.process.Init) void {
    run(init) catch |err| {
        std.debug.print("Server error: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
}

// ============================================================================
// Static HTML example — a self-contained landing page served at GET /.
//
// This is the canonical "static HTML in custom_http_server" pattern:
//
//   1. The HTML lives as a comptime string constant (LANDING_PAGE_HTML below).
//      Compiling it in keeps the binary self-contained — no on-disk file to
//      ship alongside the executable, no 404 risk.
//   2. The handler duplicates the constant into the per-request arena
//      (so it lives for the lifetime of the request and is reaped when
//      `GinwaServer.handle` calls `arena.deinit()` on the response).
//   3. We set `Content-Type: text/html; charset=utf-8` so browsers render
//      it as HTML (vs. withBody() which would default the Content-Type to
//      whatever the parser already has — i.e. nothing, making browsers
//      guess and usually render as plain text).
//   4. `withBody` automatically sets `Content-Length`, so the response
//      is one allocator-friendly call: get arena-owned slice, set body,
//      set content-type header, return response.
//
// Why a static HTML page (vs. e.g. compiling the Vue webapp into the
// binary): this server is the DEMO of itself — the page documents the
// server's own endpoints. It is not a generic static-file server.
// ============================================================================

/// A self-contained HTML landing page served at `GET /`. Inline CSS, inline
/// JavaScript, no external assets — works the same on every platform
/// (Linux/macOS/Windows) since HTML/CSS/JS are cross-platform by definition.
///
/// Sections:
///   * Hero: server identity + a one-line "what it is" pitch
///   * Endpoints table: every demo route with method, path, and curl example
///   * SSE live demo: a JavaScript EventSource subscribing to `/stream` and
///     rendering the last 5 events received
///
/// The page intentionally avoids hand-rolled HTML escaping inside the
/// JavaScript section (single-quoted strings only, no `</script>` inside
/// string literals) so the bytes are safe to embed verbatim.
const LANDING_PAGE_HTML =
    \\<!doctype html>
    \\<html lang="en">
    \\<head>
    \\  <meta charset="utf-8" />
    \\  <meta name="viewport" content="width=device-width, initial-scale=1" />
    \\  <title>GinwaServer — Static HTML Demo</title>
    \\  <style>
    \\    :root {
    \\      --bg: #0f172a;
    \\      --panel: #1e293b;
    \\      --panel-2: #334155;
    \\      --text: #e2e8f0;
    \\      --muted: #94a3b8;
    \\      --accent: #22d3ee;
    \\      --accent-2: #a78bfa;
    \\      --ok: #22c55e;
    \\      --warn: #f59e0b;
    \\    }
    \\    * { box-sizing: border-box; }
    \\    html, body { margin: 0; padding: 0; }
    \\    body {
    \\      font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', system-ui, sans-serif;
    \\      background: linear-gradient(135deg, #0f172a 0%, #1e1b4b 100%);
    \\      color: var(--text);
    \\      min-height: 100vh;
    \\      line-height: 1.5;
    \\    }
    \\    .container { max-width: 960px; margin: 0 auto; padding: 32px 24px; }
    \\    header.hero { padding: 32px 0 16px; }
    \\    h1 {
    \\      margin: 0 0 8px;
    \\      font-size: 36px;
    \\      letter-spacing: -0.02em;
    \\      background: linear-gradient(90deg, var(--accent), var(--accent-2));
    \\      -webkit-background-clip: text;
    \\      background-clip: text;
    \\      color: transparent;
    \\    }
    \\    .subtitle { color: var(--muted); font-size: 16px; margin: 0 0 8px; }
    \\    .badge-row { display: flex; flex-wrap: wrap; gap: 8px; margin-top: 16px; }
    \\    .badge {
    \\      display: inline-flex; align-items: center; gap: 6px;
    \\      padding: 4px 10px; border-radius: 999px;
    \\      font-size: 12px; font-weight: 500;
    \\      background: var(--panel-2); color: var(--muted);
    \\      border: 1px solid rgba(255,255,255,0.06);
    \\    }
    \\    .badge.ok { color: var(--ok); }
    \\    .badge.warn { color: var(--warn); }
    \\    section { margin-top: 32px; }
    \\    h2 {
    \\      font-size: 20px; margin: 0 0 12px;
    \\      border-bottom: 1px solid rgba(255,255,255,0.08);
    \\      padding-bottom: 8px;
    \\    }
    \\    .endpoint {
    \\      background: var(--panel);
    \\      border: 1px solid rgba(255,255,255,0.06);
    \\      border-radius: 8px;
    \\      padding: 14px 16px;
    \\      margin: 8px 0;
    \\    }
    \\    .endpoint-head {
    \\      display: flex; align-items: center; gap: 12px; flex-wrap: wrap;
    \\    }
    \\    .method {
    \\      font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
    \\      font-size: 12px; font-weight: 700;
    \\      padding: 3px 8px; border-radius: 4px;
    \\      background: var(--accent); color: #0c1320;
    \\      letter-spacing: 0.04em;
    \\    }
    \\    .method.post { background: var(--warn); }
    \\    .method.sse { background: var(--accent-2); }
    \\    code, pre {
    \\      font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
    \\      background: #0b1220; color: #cbd5e1;
    \\      padding: 2px 6px; border-radius: 4px; font-size: 13px;
    \\    }
    \\    pre { padding: 12px 14px; overflow-x: auto; margin: 8px 0 0; }
    \\    pre code { background: transparent; padding: 0; }
    \\    .path { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; color: var(--text); }
    \\    .desc { color: var(--muted); font-size: 14px; margin: 4px 0 0; }
    \\    #sse-log {
    \\      background: #0b1220;
    \\      border: 1px solid rgba(255,255,255,0.06);
    \\      border-radius: 8px;
    \\      padding: 12px; min-height: 96px;
    \\      font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
    \\      font-size: 13px;
    \\      max-height: 220px;
    \\      overflow-y: auto;
    \\    }
    \\    #sse-log .event { padding: 4px 0; border-bottom: 1px solid rgba(255,255,255,0.04); }
    \\    #sse-log .event:last-child { border-bottom: 0; }
    \\    #sse-status { font-size: 13px; color: var(--muted); margin-bottom: 8px; }
    \\    #sse-status.connected { color: var(--ok); }
    \\    #sse-status.error { color: var(--warn); }
    \\    footer {
    \\      margin-top: 48px; padding-top: 24px;
    \\      border-top: 1px solid rgba(255,255,255,0.08);
    \\      color: var(--muted); font-size: 13px; text-align: center;
    \\    }
    \\    @media (max-width: 600px) {
    \\      .container { padding: 20px 16px; }
    \\      h1 { font-size: 28px; }
    \\    }
    \\  </style>
    \\</head>
    \\<body>
    \\  <div class="container">
    \\    <header class="hero">
    \\      <h1>GinwaServer</h1>
    \\      <p class="subtitle">A static HTML page served by the custom HTTP server &mdash; this file lives as a comptime string in <code>src/main.zig</code>.</p>
    \\      <div class="badge-row">
    \\        <span class="badge ok">● Zig 0.16</span>
    \\        <span class="badge ok">● Linux / macOS / Windows</span>
    \\        <span class="badge">HTTP/1.1</span>
    \\        <span class="badge">SSE</span>
    \\        <span class="badge">JSON</span>
    \\      </div>
    \\    </header>
    \\
    \\    <section>
    \\      <h2>Endpoints</h2>
    \\
    \\      <div class="endpoint">
    \\        <div class="endpoint-head">
    \\          <span class="method">GET</span>
    \\          <span class="path">/</span>
    \\        </div>
    \\        <p class="desc">This page &mdash; a static HTML response compiled into the binary.</p>
    \\        <pre><code>curl http://127.0.0.1:29590/</code></pre>
    \\      </div>
    \\
    \\      <div class="endpoint">
    \\        <div class="endpoint-head">
    \\          <span class="method">GET</span>
    \\          <span class="path">/health</span>
    \\        </div>
    \\        <p class="desc">Plain-text health check. Suitable for load balancers and process supervisors.</p>
    \\        <pre><code>curl http://127.0.0.1:29590/health
\\# -&gt; OK</code></pre>
    \\      </div>
    \\
    \\      <div class="endpoint">
    \\        <div class="endpoint-head">
    \\          <span class="method">GET</span>
    \\          <span class="path">/hello</span>
    \\        </div>
    \\        <p class="desc">Greets with optional <code>name</code>, <code>greeting</code>, and <code>mood</code> query parameters.</p>
    \\        <pre><code>curl "http://127.0.0.1:29590/hello?name=World&amp;greeting=Hi&amp;mood=happy"
\\# -&gt; Hi, World! (greeting: Hi, mood: happy)</code></pre>
    \\      </div>
    \\
    \\      <div class="endpoint">
    \\        <div class="endpoint-head">
    \\          <span class="method">GET</span>
    \\          <span class="path">/hello/:name</span>
    \\        </div>
    \\        <p class="desc">Path-parameter variant &mdash; :name is extracted by the router.</p>
    \\        <pre><code>curl http://127.0.0.1:29590/hello/Alice
\\# -&gt; hello, Alice! (greeting: hello, mood: neutral)</code></pre>
    \\      </div>
    \\
    \\      <div class="endpoint">
    \\        <div class="endpoint-head">
    \\          <span class="method post">POST</span>
    \\          <span class="path">/users</span>
    \\        </div>
    \\        <p class="desc">Creates a user from a JSON body. Returns 201 Created with the echoed payload.</p>
    \\        <pre><code>curl -X POST http://127.0.0.1:29590/users \
    \\  -H "Content-Type: application/json" \
    \\  -d '{"username":"alice","email":"alice@example.com"}'
\\# -&gt; {"username":"alice","email":"alice@example.com"}</code></pre>
    \\      </div>
    \\
    \\      <div class="endpoint">
    \\        <div class="endpoint-head">
    \\          <span class="method sse">SSE</span>
    \\          <span class="path">/stream</span>
    \\        </div>
    \\        <p class="desc">Server-Sent Events. Open the connection and receive named events and heartbeats until you close it.</p>
    \\        <pre><code>curl -N http://127.0.0.1:29590/stream
\\# stream of "data: ..." events ending in periodic heartbeats</code></pre>
    \\      </div>
    \\    </section>
    \\
    \\    <section>
    \\      <h2>Live SSE demo</h2>
    \\      <p class="desc">Open this page in a browser, then look below &mdash; this block subscribes to <code>/stream</code> via the EventSource API and renders the last events it receives.</p>
    \\      <div id="sse-status">Connecting&hellip;</div>
    \\      <div id="sse-log"></div>
    \\      <script>
    \\        (function () {
    \\          var status = document.getElementById('sse-status');
    \\          var log = document.getElementById('sse-log');
    \\          var MAX_EVENTS = 5;
    \\
    \\          function appendLine(text) {
    \\            var line = document.createElement('div');
    \\            line.className = 'event';
    \\            var ts = new Date().toISOString().substr(11, 12);
    \\            line.textContent = '[' + ts + '] ' + text;
    \\            log.appendChild(line);
    \\            while (log.childNodes.length > MAX_EVENTS) {
    \\              log.removeChild(log.firstChild);
    \\            }
    \\            log.scrollTop = log.scrollHeight;
    \\          }
    \\
    \\          if (typeof EventSource === 'undefined') {
    \\            status.textContent = 'EventSource not supported in this browser';
    \\            status.className = 'error';
    \\            return;
    \\          }
    \\
    \\          var source = new EventSource('/stream');
    \\          source.addEventListener('connected', function (e) {
    \\            status.textContent = '● Connected to /stream';
    \\            status.className = 'connected';
    \\            appendLine('connected: ' + (e.data || ''));
    \\          });
    \\          source.addEventListener('message', function (e) {
    \\            appendLine('message: ' + (e.data || ''));
    \\          });
    \\          source.onerror = function () {
    \\            status.textContent = '● Connection error (server offline?)';
    \\            status.className = 'error';
    \\          };
    \\        })();
    \\      </script>
    \\    </section>
    \\
    \\    <footer>
    \\      Source: <code>src/modules/custom_http_server/src/main.zig</code> &middot; see <code>LANDING_PAGE_HTML</code>.
    \\    </footer>
    \\  </div>
    \\</body>
    \\</html>
;

/// Serves the static landing page at `GET /`. Allocates a per-request copy of
/// the HTML body, sets `Content-Type: text/html; charset=utf-8`, and lets
/// `withBody` add the matching `Content-Length` automatically. No defer
/// needed — the per-request arena allocator reaps the dup'd buffer when
/// `GinwaServer.handle` returns.
fn landingPageHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    _ = req;

    // Duplicate into the per-request arena so the response is request-scoped
    // (reaped by GinwaServer.handle via arena.deinit()). LANDING_PAGE_HTML
    // itself lives in the binary's rodata; the arena copy is what the wire
    // receives. For a 4 KB page the dup is ~4 KB of arena — negligible.
    const body = ctx.allocator.dupe(u8, LANDING_PAGE_HTML) catch {
        return gserverz.response.internalError("Failed to allocate HTML body", ctx.allocator);
    };

    var out = res.withBody(body);

    // withBody already sets Content-Length. We explicitly add the HTML
    // content-type so browsers render the response as HTML (without this,
    // some browsers sniff and fall back to plain text rendering).
    out.headers.put("Content-Type", "text/html; charset=utf-8") catch {
        return gserverz.response.internalError("Failed to set Content-Type header", ctx.allocator);
    };

    return out;
}

// Handlers - (ctx, req, res) -> !HttpResponse
fn healthHandler(_: gserverz.HttpContext, req: gserverz.HttpRequest, res: gserverz.HttpResponse) !gserverz.HttpResponse {
    _ = req;
    return res.withBody("OK");
}

fn helloHandler(ctx: gserverz.HttpContext, req: gserverz.HttpRequest, res: gserverz.HttpResponse) !gserverz.HttpResponse {
    const name = req.query.get("name") orelse "HTTP";
    const greeting = req.query.get("greeting") orelse "hello";
    const mood = req.query.get("mood") orelse "neutral";

    const text = std.fmt.allocPrint(ctx.allocator, "Hello, {s}! (greeting: {s}, mood: {s})", .{ name, greeting, mood }) catch {
        return gserverz.response.internalError("Failed to format", ctx.allocator);
    };
    return res.withBody(text);
}

fn helloNameHandler(ctx: gserverz.HttpContext, req: gserverz.HttpRequest, res: gserverz.HttpResponse) !gserverz.HttpResponse {
    const name = req.query.get("name") orelse req.params.get("name") orelse "unknown";
    const greeting = req.query.get("greeting") orelse "hello";
    const mood = req.query.get("mood") orelse "neutral";


    const text = std.fmt.allocPrint(ctx.allocator, "Hello, {s}! (greeting: {s}, mood: {s})", .{ name, greeting, mood }) catch {
        return gserverz.response.internalError("Failed to format", ctx.allocator);
    };
    return res.withBody(text);
}

const User = struct {
    username: []const u8 = "",
    email: []const u8 = "",
};

fn createUserHandler(ctx: gserverz.HttpContext, req: gserverz.HttpRequest, res: gserverz.HttpResponse) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    std.debug.print("HANDLER: req.body.len={}\n", .{req.body.len});

    const user = std.json.parseFromSliceLeaky(User, allocator, req.body, .{}) catch |err| {
        std.debug.print("HANDLER JSON error: {s}\n", .{@errorName(err)});
        if (req.body.len > 0) {
            std.debug.print("HANDLER body[0..50]={s}\n", .{req.body[0..@min(50, req.body.len)]});
        }
        return gserverz.response.badRequest("Invalid user JSON", allocator);
    };

    const json_text = std.fmt.allocPrint(allocator, "{{\"username\":\"{s}\",\"email\":\"{s}\"}}", .{ user.username, user.email }) catch {
        return gserverz.response.internalError("Failed to format", allocator);
    };
    return res.jsonResponse(.{ .status_code = 201, .data = json_text });
}

/// SSE streaming handler - registers client with SSE manager
/// Actual streaming handled by SseManager.runEventLoop()
fn sseStreamHandler(ctx: gserverz.HttpContext, req: gserverz.HttpRequest, res: gserverz.HttpResponse) !gserverz.HttpResponse {
    _ = ctx;
    _ = req;
    _ = res;
    // Client is registered in http_server.zig before this is called
    // The SSE manager event loop handles ongoing messaging and heartbeat
    return error.WouldBlock; // Handler should not complete - connection stays open
}

pub fn run(init: std.process.Init) !void {
    // const arena_allocator = init.arena;
    // defer arena_allocator.deinit();
    // const allocator = arena_allocator.allocator();
    //
    const allocator = init.gpa;
    const io = init.io;

    // Test allocator with a large allocation first
    std.debug.print("DEBUG: Testing allocator with 1MB allocation...\n", .{});
    const test_alloc = allocator.alloc(u8, 1024 * 1024) catch |err| {
        std.debug.print("DEBUG: 1MB alloc failed: {s}\n", .{@errorName(err)});
        return err;
    };
    allocator.free(test_alloc);
    std.debug.print("DEBUG: 1MB alloc succeeded\n", .{});

    const address = try gserverz.Address.init(29590);
    const gs = try gserverz.GinwaServer.init(allocator, io, address);
    defer gs.deinit();

    // Start SSE event loop in a separate thread (non-blocking)
    const sse_thread = try std.Thread.spawn(.{}, struct {
        fn run(sm: *gserverz.SseManager, secs: u32) void {
            sm.startEventLoop(secs) catch |err| {
                std.debug.print("SSE event loop error: {s}\n", .{@errorName(err)});
            };
        }
    }.run, .{ &gs.sse_manager, @as(u32, 15) });
    defer {
        gs.sse_manager.stop();
        sse_thread.join();
    }

    std.debug.print("HTTP Server listening on 127.0.0.1:29590...\n", .{});
    std.debug.print("SSE Event loop running with 15s heartbeat...\n", .{});
    std.debug.print("Open  http://127.0.0.1:29590/  in a browser for the static HTML demo.\n", .{});
    std.debug.print("Or:   curl http://127.0.0.1:29590/health\n", .{});
    std.debug.print("Press Ctrl+C to stop\n\n", .{});

    try gs.router.get("/hello", helloHandler);
    try gs.router.get("/health", healthHandler);
    try gs.router.get("/hello/:name", helloNameHandler);
    try gs.router.post("/users", createUserHandler);
    // Static HTML page — served by landingPageHandler. See LANDING_PAGE_HTML above.
    try gs.router.get("/", landingPageHandler);
    try gs.router.sse("/stream", sseStreamHandler);

    try gs.listen();
}

// curl http://127.0.0.1:29590/       # → HTML landing page
// curl http://127.0.0.1:29590/health # → "OK"
// curl http://127.0.0.1:29590/hello   # → "Hello, HTTP!"
