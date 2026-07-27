# Custom HTTP Server

A lightweight, pure Zig HTTP server implementation with routing, SSE support, and JSON handling.

## Features

- **HTTP Server**: Pure Zig implementation using low-level POSIX sockets
- **Routing**: RESTful routing with path parameters (e.g., `/hello/:name`)
- **SSE (Server-Sent Events)**: Built-in SSE manager with heartbeat and broadcasting
- **JSON Handling**: JSON request/response parsing and generation
- **Concurrent**: Per-connection request handling with arena allocators
- **Cross-Platform**: Linux, macOS, BSD, and Windows support

## Quick Start

### Build and Run

```bash
zig build run
```

### Test Endpoints

```bash
# Static HTML landing page (open in a browser for the demo)
curl -i http://127.0.0.1:29590/
# → Returns: HTTP/1.1 200 OK
#            Content-Type: text/html; charset=utf-8
#            <html lang="en"><head>... (a styled, self-contained page
#            documenting every other endpoint below)

# Health check (plain text — suitable for load balancers)
curl http://127.0.0.1:29590/health
# → Returns: OK

# Query parameters
curl "http://127.0.0.1:29590/hello?name=World&greeting=Hello&mood=happy"
# → Returns: Hello, World! (greeting: Hello, mood: happy)

# Path parameters
curl http://127.0.0.1:29590/hello/Alice
# → Returns: Hello, Alice! (greeting: hello, mood: neutral)

# Create user (POST JSON)
curl -X POST http://127.0.0.1:29590/users \
  -H "Content-Type: application/json" \
  -d '{"username":"alice","email":"alice@example.com"}'
# → Returns: {"username":"alice","email":"alice@example.com"}

# SSE streaming
curl http://127.0.0.1:29590/stream
# → Receives server-sent events with heartbeat pings
```

### Static HTML in `main.zig`

`GET /` serves a real HTML page (`text/html; charset=utf-8`) compiled
into the binary as a comptime string constant (`LANDING_PAGE_HTML`).
The page is self-contained — inline CSS, inline JavaScript, no external
assets — and demonstrates every server feature:

* A styled "Endpoints" table with curl examples for each route.
* A live SSE demo using the browser's `EventSource` API to subscribe
  to `/stream` and render the last 5 events received.

To add the same pattern to your own server, copy the
`landingPageHandler` function from `src/main.zig`. It:

1. Calls `ctx.allocator.dupe(u8, LANDING_PAGE_HTML)` to copy the
   comptime constant into the per-request arena.
2. Calls `res.withBody(body)` to set the body and `Content-Length`.
3. Sets `Content-Type: text/html; charset=utf-8` explicitly so
   browsers render it as HTML (without this header some browsers
   sniff and fall back to plain text).

Static-contract regression tests in
`src/main_static_html_test.zig` assert the constant, function, route
registration, doctype, charset, endpoint table, and EventSource demo
all stay present across edits — see "Running Tests" below.

## Architecture

```
src/
├── main.zig                  # Server entry point, route setup, and static HTML page (LANDING_PAGE_HTML)
├── http_server.zig           # Core server: Address, GinwaServer, RequestBuffer
├── http_parser.zig           # HTTP request/response parsing
├── router.zig                # Route matching with parameter extraction
├── sse_manager.zig           # SSE client management and event loop
├── main_static_html_test.zig # Static-contract tests for LANDING_PAGE_HTML
└── build.zig                 # Build configuration
```

### Core Components

**http_server.zig**
- `Address`: Socket binding and port configuration
- `GinwaServer`: Main server struct handling connections
- `RequestBuffer`: Auto-growing buffer for reading HTTP requests

**router.zig**
- `Router`: Route registry supporting GET, POST, PUT, DELETE, PATCH
- `Route`: Individual route definition with handler
- Path parameter extraction via `:param` syntax

**sse_manager.zig**
- `SseManager`: Manages SSE connections and broadcasting
- `SseClient`: Individual SSE client state
- Heartbeat mechanism with configurable interval
- Thread-safe client management with lock

**http_parser.zig**
- `HttpRequest`: Parsed request with method, path, headers, body
- `HttpResponse`: Response builder with body and JSON support

## API Reference

### Router

```zig
try gs.router.get("/path", handler);
try gs.router.post("/path", handler);
try gs.router.put("/path", handler);
try gs.router.delete("/path", handler);
try gs.router.patch("/path", handler);
try gs.router.sse("/stream", sseHandler);
```

### Handler Signature

```zig
fn handler(ctx: HttpContext, req: HttpRequest, res: HttpResponse) !HttpResponse {
    // Access query params: req.query.get("name")
    // Access path params: req.params.get("name")
    // Access body: req.body
    return res.withBody("Response text");
}
```

### SSE Manager

```zig
// Broadcast to all clients
try gs.sse_manager.broadcast("message");

// Send to specific client
try gs.sse_manager.sendToClient(client_id, "message");

// Get connected client count
const count = gs.sse_manager.clientCount();
```

## Running Tests

```bash
zig build test
```

## Dependencies

- Zig 0.15+
- Standard library only (no external dependencies)
- Links against libc for socket operations

## Configuration

### Port
Default port is `29590`. To change, modify `main.zig`:
```zig
const address = try gserverz.Address.init(29590);
```

### SSE Heartbeat
Default heartbeat interval is 15 seconds. To change:
```zig
try gs.sse_manager.startEventLoop(15); // seconds
```