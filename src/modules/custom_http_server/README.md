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
# Root endpoint
curl http://127.0.0.1:29590/
# → Returns: ID: 100

# Health check
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

## Architecture

```
src/
├── main.zig           # Server entry point and route setup
├── http_server.zig    # Core server: Address, GinwaServer, RequestBuffer
├── http_parser.zig    # HTTP request/response parsing
├── router.zig        # Route matching with parameter extraction
├── sse_manager.zig   # SSE client management and event loop
└── build.zig         # Build configuration
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