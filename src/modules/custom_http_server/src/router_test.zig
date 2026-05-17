const std = @import("std");
const http_parser = @import("http_parser.zig");
const router = @import("router.zig");

// Helper to create a mock HttpRequest for testing
fn createMockRequest(method: []const u8, path: []const u8, allocator: std.mem.Allocator) http_parser.HttpRequest {
    return http_parser.HttpRequest{
        .method = method,
        .path = path,
        .version = "HTTP/1.1",
        .headers = std.StringHashMap([]const u8).init(allocator),
        .body = "",
        .raw = "",
        .params = std.StringHashMap([]const u8).init(allocator),
        .query = std.StringHashMap([]const u8).init(allocator),
        ._client_fd = -1,
    };
}

// ============================================================================
// Router Initialization Tests
// ============================================================================

test "Router.init creates empty router" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const r = router.Router.init(arena.allocator());
    try std.testing.expectEqual(@as(usize, 0), r.routes.items.len);
}

test "Router.deinit cleans up routes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var r = router.Router.init(arena.allocator());
    r.deinit();
    // If we get here without memory leaks, the test passes
}

// ============================================================================
// Basic Route Registration Tests
// ============================================================================

test "Router.get registers GET route" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var r = router.Router.init(arena.allocator());
    defer r.deinit();

    try r.get("/test", struct {
        fn handle(_: http_parser.HttpContext, _: http_parser.HttpRequest, _: http_parser.HttpResponse) anyerror!http_parser.HttpResponse {
            return http_parser.ok("OK", std.heap.page_allocator);
        }
    }.handle);

    try std.testing.expectEqual(@as(usize, 1), r.routes.items.len);
    try std.testing.expectEqualStrings("GET", r.routes.items[0].method);
    try std.testing.expectEqualStrings("/test", r.routes.items[0].path);
}

test "Router.post registers POST route" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var r = router.Router.init(arena.allocator());
    defer r.deinit();

    try r.post("/api/data", struct {
        fn handle(_: http_parser.HttpContext, _: http_parser.HttpRequest, _: http_parser.HttpResponse) anyerror!http_parser.HttpResponse {
            return http_parser.ok("Created", std.heap.page_allocator);
        }
    }.handle);

    try std.testing.expectEqual(@as(usize, 1), r.routes.items.len);
    try std.testing.expectEqualStrings("POST", r.routes.items[0].method);
}

test "Router.put registers PUT route" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var r = router.Router.init(arena.allocator());
    defer r.deinit();

    try r.put("/api/data/1", struct {
        fn handle(_: http_parser.HttpContext, _: http_parser.HttpRequest, _: http_parser.HttpResponse) anyerror!http_parser.HttpResponse {
            return http_parser.ok("Updated", std.heap.page_allocator);
        }
    }.handle);

    try std.testing.expectEqual(@as(usize, 1), r.routes.items.len);
    try std.testing.expectEqualStrings("PUT", r.routes.items[0].method);
    try std.testing.expectEqualStrings("/api/data/1", r.routes.items[0].path);
}

test "Router.delete registers DELETE route" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var r = router.Router.init(arena.allocator());
    defer r.deinit();

    try r.delete("/api/data/1", struct {
        fn handle(_: http_parser.HttpContext, _: http_parser.HttpRequest, _: http_parser.HttpResponse) anyerror!http_parser.HttpResponse {
            return http_parser.ok("Deleted", std.heap.page_allocator);
        }
    }.handle);

    try std.testing.expectEqual(@as(usize, 1), r.routes.items.len);
    try std.testing.expectEqualStrings("DELETE", r.routes.items[0].method);
}

test "Router.patch registers PATCH route" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var r = router.Router.init(arena.allocator());
    defer r.deinit();

    try r.patch("/api/data/1", struct {
        fn handle(_: http_parser.HttpContext, _: http_parser.HttpRequest, _: http_parser.HttpResponse) anyerror!http_parser.HttpResponse {
            return http_parser.ok("Patched", std.heap.page_allocator);
        }
    }.handle);

    try std.testing.expectEqual(@as(usize, 1), r.routes.items.len);
    try std.testing.expectEqualStrings("PATCH", r.routes.items[0].method);
}

// ============================================================================
// Route Matching Tests
// ============================================================================

test "Router.matchRoute exact match returns handler result" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var r = router.Router.init(arena.allocator());
    defer r.deinit();

    try r.get("/hello", struct {
        fn handle(_: http_parser.HttpContext, _: http_parser.HttpRequest, res: http_parser.HttpResponse) anyerror!http_parser.HttpResponse {
            return res.withBody("hello");
        }
    }.handle);

    var req = createMockRequest("GET", "/hello", arena.allocator());
    defer req.params.deinit();

    const ctx = http_parser.HttpContext{
        .allocator = arena.allocator(),
        .io = undefined,
    };

    const result = r.matchRoute("GET", "/hello", &req, ctx);
    try std.testing.expect(result != null);

    switch (result.?) {
        .handler => |res_data| {
            try std.testing.expectEqual(@as(u16, 200), res_data.res.status_code);
        },
        .sse => {
            try std.testing.expect(false); // Should not be SSE
        },
    }
}

test "Router.matchRoute no match returns null" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var r = router.Router.init(arena.allocator());
    defer r.deinit();

    try r.get("/existing", struct {
        fn handle(_: http_parser.HttpContext, _: http_parser.HttpRequest, _: http_parser.HttpResponse) anyerror!http_parser.HttpResponse {
            return http_parser.ok("OK", std.heap.page_allocator);
        }
    }.handle);

    var req = createMockRequest("GET", "/nonexistent", arena.allocator());
    defer req.params.deinit();

    const ctx = http_parser.HttpContext{
        .allocator = arena.allocator(),
        .io = undefined,
    };

    const result = r.matchRoute("GET", "/nonexistent", &req, ctx);
    try std.testing.expect(result == null);
}

test "Router.matchRoute method mismatch returns null" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var r = router.Router.init(arena.allocator());
    defer r.deinit();

    try r.get("/api", struct {
        fn handle(_: http_parser.HttpContext, _: http_parser.HttpRequest, _: http_parser.HttpResponse) anyerror!http_parser.HttpResponse {
            return http_parser.ok("OK", std.heap.page_allocator);
        }
    }.handle);

    var req = createMockRequest("POST", "/api", arena.allocator());
    defer req.params.deinit();

    const ctx = http_parser.HttpContext{
        .allocator = arena.allocator(),
        .io = undefined,
    };

    const result = r.matchRoute("POST", "/api", &req, ctx);
    try std.testing.expect(result == null);
}

test "Router.matchRoute case sensitive path matching" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var r = router.Router.init(arena.allocator());
    defer r.deinit();

    try r.get("/API", struct {
        fn handle(_: http_parser.HttpContext, _: http_parser.HttpRequest, _: http_parser.HttpResponse) anyerror!http_parser.HttpResponse {
            return http_parser.ok("OK", std.heap.page_allocator);
        }
    }.handle);

    var req_lower = createMockRequest("GET", "/api", arena.allocator());
    defer req_lower.params.deinit();

    const ctx = http_parser.HttpContext{
        .allocator = arena.allocator(),
        .io = undefined,
    };

    const result_lower = r.matchRoute("GET", "/api", &req_lower, ctx);
    try std.testing.expect(result_lower == null); // Case sensitive

    var req_exact = createMockRequest("GET", "/API", arena.allocator());
    defer req_exact.params.deinit();

    const result_exact = r.matchRoute("GET", "/API", &req_exact, ctx);
    try std.testing.expect(result_exact != null);
}

// ============================================================================
// Path Parameter Extraction Tests
// ============================================================================

test "Router.matchRoute extracts path params" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var r = router.Router.init(arena.allocator());
    defer r.deinit();

    try r.get("/users/:id", struct {
        fn handle(_: http_parser.HttpContext, _: http_parser.HttpRequest, _: http_parser.HttpResponse) anyerror!http_parser.HttpResponse {
            return http_parser.ok("OK", std.heap.page_allocator);
        }
    }.handle);

    var req = createMockRequest("GET", "/users/123", arena.allocator());
    defer req.params.deinit();

    const ctx = http_parser.HttpContext{
        .allocator = arena.allocator(),
        .io = undefined,
    };

    const result = r.matchRoute("GET", "/users/123", &req, ctx);
    try std.testing.expect(result != null);

    const id_value = req.params.get("id");
    try std.testing.expect(id_value != null);
    try std.testing.expectEqualStrings("123", id_value.?);
}

test "Router.matchRoute extracts multiple path params" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var r = router.Router.init(arena.allocator());
    defer r.deinit();

    try r.get("/users/:userId/posts/:postId", struct {
        fn handle(_: http_parser.HttpContext, _: http_parser.HttpRequest, _: http_parser.HttpResponse) anyerror!http_parser.HttpResponse {
            return http_parser.ok("OK", std.heap.page_allocator);
        }
    }.handle);

    var req = createMockRequest("GET", "/users/abc/posts/xyz", arena.allocator());
    defer req.params.deinit();

    const ctx = http_parser.HttpContext{
        .allocator = arena.allocator(),
        .io = undefined,
    };

    const result = r.matchRoute("GET", "/users/abc/posts/xyz", &req, ctx);
    try std.testing.expect(result != null);

    try std.testing.expectEqualStrings("abc", req.params.get("userId").?);
    try std.testing.expectEqualStrings("xyz", req.params.get("postId").?);
}

test "Router.matchRoute params mismatch returns null" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var r = router.Router.init(arena.allocator());
    defer r.deinit();

    // Route expects two segments: /users/:id
    try r.get("/users/:id", struct {
        fn handle(_: http_parser.HttpContext, _: http_parser.HttpRequest, _: http_parser.HttpResponse) anyerror!http_parser.HttpResponse {
            return http_parser.ok("OK", std.heap.page_allocator);
        }
    }.handle);

    // Request has extra segment: /users/123/extra
    var req = createMockRequest("GET", "/users/123/extra", arena.allocator());
    defer req.params.deinit();

    const ctx = http_parser.HttpContext{
        .allocator = arena.allocator(),
        .io = undefined,
    };

    const result = r.matchRoute("GET", "/users/123/extra", &req, ctx);
    try std.testing.expect(result == null);
}

test "Router.matchRoute partial param match" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var r = router.Router.init(arena.allocator());
    defer r.deinit();

    // Route: /users/:id
    try r.get("/users/:id", struct {
        fn handle(_: http_parser.HttpContext, _: http_parser.HttpRequest, _: http_parser.HttpResponse) anyerror!http_parser.HttpResponse {
            return http_parser.ok("OK", std.heap.page_allocator);
        }
    }.handle);

    // Request is just /users (missing param)
    var req = createMockRequest("GET", "/users", arena.allocator());
    defer req.params.deinit();

    const ctx = http_parser.HttpContext{
        .allocator = arena.allocator(),
        .io = undefined,
    };

    const result = r.matchRoute("GET", "/users", &req, ctx);
    try std.testing.expect(result == null);
}

// ============================================================================
// SSE Route Tests
// ============================================================================

test "Router.sse registers SSE route" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var r = router.Router.init(arena.allocator());
    defer r.deinit();

    try r.sse("/stream", struct {
        fn handle(_: http_parser.HttpContext, _: http_parser.HttpRequest, _: http_parser.HttpResponse) anyerror!http_parser.HttpResponse {
            return http_parser.ok("", std.heap.page_allocator);
        }
    }.handle);

    try std.testing.expectEqual(@as(usize, 1), r.routes.items.len);
    try std.testing.expectEqualStrings("GET", r.routes.items[0].method);
    try std.testing.expectEqualStrings("/stream", r.routes.items[0].path);
    try std.testing.expectEqual(router.RouteType.sse, r.routes.items[0].route_type);
}

test "Router.sse route returns sse result" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var r = router.Router.init(arena.allocator());
    defer r.deinit();

    try r.sse("/stream", struct {
        fn handle(_: http_parser.HttpContext, _: http_parser.HttpRequest, _: http_parser.HttpResponse) anyerror!http_parser.HttpResponse {
            return http_parser.ok("", std.heap.page_allocator);
        }
    }.handle);

    var req = createMockRequest("GET", "/stream", arena.allocator());
    defer req.params.deinit();

    const ctx = http_parser.HttpContext{
        .allocator = arena.allocator(),
        .io = undefined,
    };

    const result = r.matchRoute("GET", "/stream", &req, ctx);
    try std.testing.expect(result != null);

    switch (result.?) {
        .handler => {
            try std.testing.expect(false); // Should not be handler
        },
        .sse => |sse| {
            _ = sse;
        },
    }
}

// ============================================================================
// HandleRoute Tests
// ============================================================================

test "Router.handleRoute returns 404 when no route matches" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var r = router.Router.init(arena.allocator());
    defer r.deinit();

    var req = createMockRequest("GET", "/nonexistent", arena.allocator());
    defer req.params.deinit();

    const ctx = http_parser.HttpContext{
        .allocator = arena.allocator(),
        .io = undefined,
    };

    const res = r.handleRoute("GET", "/nonexistent", &req, ctx);
    try std.testing.expectEqual(@as(u16, 404), res.status_code);
}

test "Router.handleRoute returns SSE as 404 (backward compat)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var r = router.Router.init(arena.allocator());
    defer r.deinit();

    try r.sse("/stream", struct {
        fn handle(_: http_parser.HttpContext, _: http_parser.HttpRequest, _: http_parser.HttpResponse) anyerror!http_parser.HttpResponse {
            return http_parser.ok("", std.heap.page_allocator);
        }
    }.handle);

    var req = createMockRequest("GET", "/stream", arena.allocator());
    defer req.params.deinit();

    const ctx = http_parser.HttpContext{
        .allocator = arena.allocator(),
        .io = undefined,
    };

    // handleRoute is legacy and doesn't handle SSE properly
    const res = r.handleRoute("GET", "/stream", &req, ctx);
    try std.testing.expectEqual(@as(u16, 404), res.status_code);
}

// ============================================================================
// Multiple Routes Tests
// ============================================================================

test "Router handles multiple routes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var r = router.Router.init(arena.allocator());
    defer r.deinit();

    try r.get("/a", struct {
        fn handle(_: http_parser.HttpContext, _: http_parser.HttpRequest, _: http_parser.HttpResponse) anyerror!http_parser.HttpResponse {
            return http_parser.ok("A", std.heap.page_allocator);
        }
    }.handle);

    try r.post("/b", struct {
        fn handle(_: http_parser.HttpContext, _: http_parser.HttpRequest, _: http_parser.HttpResponse) anyerror!http_parser.HttpResponse {
            return http_parser.ok("B", std.heap.page_allocator);
        }
    }.handle);

    try r.get("/c", struct {
        fn handle(_: http_parser.HttpContext, _: http_parser.HttpRequest, _: http_parser.HttpResponse) anyerror!http_parser.HttpResponse {
            return http_parser.ok("C", std.heap.page_allocator);
        }
    }.handle);

    try std.testing.expectEqual(@as(usize, 3), r.routes.items.len);
}

test "Router matches correct route among multiple" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var r = router.Router.init(arena.allocator());
    defer r.deinit();

    try r.get("/first", struct {
        fn handle(_: http_parser.HttpContext, _: http_parser.HttpRequest, res: http_parser.HttpResponse) anyerror!http_parser.HttpResponse {
            return res.withBody("First");
        }
    }.handle);

    try r.get("/second", struct {
        fn handle(_: http_parser.HttpContext, _: http_parser.HttpRequest, res: http_parser.HttpResponse) anyerror!http_parser.HttpResponse {
            return res.withBody("Second");
        }
    }.handle);

    var req_second = createMockRequest("GET", "/second", arena.allocator());
    defer req_second.params.deinit();

    const ctx = http_parser.HttpContext{
        .allocator = arena.allocator(),
        .io = undefined,
    };

    const result = r.matchRoute("GET", "/second", &req_second, ctx);
    try std.testing.expect(result != null);

    switch (result.?) {
        .handler => |res_data| {
            try std.testing.expectEqual(@as(u16, 200), res_data.res.status_code);
        },
        .sse => {
            try std.testing.expect(false);
        },
    }
}

// ============================================================================
// Context Preservation Tests
// ============================================================================

test "Router.preserves context data" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var r = router.Router.init(arena.allocator());
    defer r.deinit();

    try r.get("/test", struct {
        fn handle(_: http_parser.HttpContext, _: http_parser.HttpRequest, res: http_parser.HttpResponse) anyerror!http_parser.HttpResponse {
            return res.withBody("OK");
        }
    }.handle);

    var req = createMockRequest("GET", "/test", arena.allocator());
    defer req.params.deinit();

    const ctx = http_parser.HttpContext{
        .allocator = arena.allocator(),
        .io = undefined,
    };

    const result = r.matchRoute("GET", "/test", &req, ctx);
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(u16, 200), result.?.handler.res.status_code);
}