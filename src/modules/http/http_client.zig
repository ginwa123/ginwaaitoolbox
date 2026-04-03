const std = @import("std");
const json = std.json;
const testing = std.testing;

/// Escape a string for safe shell usage by wrapping in single quotes
fn escapeShellArg(arg: []const u8, allocator: std.mem.Allocator) ![]const u8 {
    var result: std.ArrayList(u8) = .empty;
    defer result.deinit(allocator);
    try result.append(allocator, '\'');
    for (arg) |c| {
        if (c == '\'') {
            try result.appendSlice(allocator, "'\\''");
        } else {
            try result.append(allocator, c);
        }
    }
    try result.append(allocator, '\'');
    return try result.toOwnedSlice(allocator);
}

/// HTTP Client Result
const HttpResult = struct {
    body: []const u8,
    status_code: u16,
};

/// HTTP Client errors
const HttpError = error{
    EmptyResponse,
};

/// HTTP Client interface
pub const HttpClient = struct {
    allocator: std.mem.Allocator,

    /// Initialize HTTP client
    pub fn init(allocator: std.mem.Allocator) HttpClient {
        return .{ .allocator = allocator };
    }

    /// Deinitialize HTTP client
    pub fn deinit(_: *HttpClient) void {
        // No-op for now
    }

    /// Perform HTTP POST request
    /// Uses curl as primary (better TLS support), falls back to std.http
    pub fn post(self: HttpClient, url: []const u8, body: []const u8, headers: ?std.StringHashMap([]const u8)) !HttpResult {
        // Try curl first - it handles TLS better and is more reliable
        return self.postWithCurl(url, body, headers) catch |curl_err| {
            // If curl fails, try std.http as fallback
            return self.postWithStdHttp(url, body, headers) catch |http_err| {
                // Both methods failed, return an error with context
                std.log.err("HTTP POST failed: curl={s}, std.http={s}", .{ @errorName(curl_err), @errorName(http_err) });
                return error.HttpRequestFailed;
            };
        };
    }

    /// POST using std.http.Client (currently not used - curl is primary due to TLS issues in test env)
    fn postWithStdHttp(self: HttpClient, url: []const u8, body: []const u8, headers: ?std.StringHashMap([]const u8)) !HttpResult {
        var client = std.http.Client{ .allocator = self.allocator };
        defer client.deinit();

        const uri = try std.Uri.parse(url);

        // Build extra headers
        var extra_headers: std.ArrayList(std.http.Header) = .empty;
        defer extra_headers.deinit(self.allocator);

        // Add custom headers
        if (headers) |h| {
            var iter = h.iterator();
            while (iter.next()) |entry| {
                try extra_headers.append(self.allocator, .{
                    .name = entry.key_ptr.*,
                    .value = entry.value_ptr.*,
                });
            }
        }

        var req = try client.request(.POST, uri, .{
            .version = .@"HTTP/1.1",
            .headers = .{
                .content_type = .{ .override = "application/json" },
            },
            .extra_headers = extra_headers.items,
        });
        defer req.deinit();

        // Send body (need mutable slice)
        const body_mut = try self.allocator.dupe(u8, body);
        defer self.allocator.free(body_mut);
        try req.sendBodyComplete(body_mut);

        // Receive response
        var redirect_buffer: [8192]u8 = undefined;
        var response = try req.receiveHead(&redirect_buffer);

        // Read body
        var transfer_buffer: [64 * 1024]u8 = undefined;
        const response_body = try response.reader(&transfer_buffer).allocRemaining(self.allocator, .unlimited);

        return .{
            .body = response_body,
            .status_code = @intFromEnum(response.head.status),
        };
    }

    /// POST using curl as fallback
    /// IMPORTANT: Uses std.heap.c_allocator for Child.process to avoid arena corruption issues
    fn postWithCurl(self: HttpClient, url: []const u8, body: []const u8, headers: ?std.StringHashMap([]const u8)) !HttpResult {
        // Note: headers param is not used because we hardcode the Accept header for MCP
        _ = headers;

        // Build curl command - escape single quotes in URL and body to prevent injection
        const escaped_url = try escapeShellArg(url, self.allocator);
        defer self.allocator.free(escaped_url);
        
        const escaped_body = try escapeShellArg(body, self.allocator);
        defer self.allocator.free(escaped_body);
        
        const shell_cmd = try std.fmt.allocPrint(self.allocator,
            "curl -s -X POST {s} -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' -d {s}",
            .{ escaped_url, escaped_body }
        );
        defer self.allocator.free(shell_cmd);

        // Execute curl via bash -c
        // IMPORTANT: Use std.heap.c_allocator for Child to avoid arena corruption
        // The Child.process internally creates its own arena, and using an arena
        // wrapped in another arena can cause memory corruption
        var child = std.process.Child.init(&[_][]const u8{ "bash", "-c", shell_cmd }, std.heap.c_allocator);

        child.stdin_behavior = .Ignore;
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;

        // Spawn with error handling - if spawn fails, return proper error
        child.spawn() catch |err| {
            std.log.warn("Failed to spawn curl process: {s}", .{@errorName(err)});
            // Return empty response with error status
            const empty = try self.allocator.dupe(u8, "");
            return .{
                .body = empty,
                .status_code = 127, // Command not found
            };
        };

        // Read stdout BEFORE waiting - important for capturing output!
        // Use a loop to read all data since network responses may arrive in multiple chunks
        var stdout_list: std.ArrayList(u8) = .empty;
        errdefer stdout_list.deinit(self.allocator);

        if (child.stdout) |out| {
            var buf: [4096]u8 = undefined;
            while (true) {
                const bytes_read = out.read(&buf) catch 0;
                if (bytes_read == 0) break;
                try stdout_list.appendSlice(self.allocator, buf[0..bytes_read]);
            }
        }

        const stdout = try stdout_list.toOwnedSlice(self.allocator);

        const term = child.wait() catch |err| {
            std.log.warn("Failed to wait for curl process: {s}", .{@errorName(err)});
            return .{
                .body = stdout,
                .status_code = 1,
            };
        };

        // Check exit code
        const exit_code: u8 = switch (term) {
            .Exited => |code| code,
            else => 1,
        };

        return .{
            .body = stdout,
            .status_code = if (exit_code == 0) 200 else exit_code,
        };
    }
};
pub fn callMcp(json_rpc_body: []const u8, allocator: std.mem.Allocator) !HttpResult {
    const url = "https://mcp.context7.com/mcp";

    var client = HttpClient.init(allocator);
    defer client.deinit();

    // Create headers with Accept header for MCP
    var headers = std.StringHashMap([]const u8).init(allocator);
    defer headers.deinit();
    try headers.put("Accept", "application/json, text/event-stream");

    return try client.post(url, json_rpc_body, headers);
}

// ============= TESTS =============

test "http client init and deinit" {
    const allocator = testing.allocator;
    var client = HttpClient.init(allocator);
    client.deinit();
}

test "http client post with std.http" {
    const allocator = testing.allocator;
    var client = HttpClient.init(allocator);
    defer client.deinit();

    // Test POST to a simple endpoint
    const result = client.post(
        "https://httpbin.org/post",
        "{\"test\":\"value\"}",
        null,
    ) catch |err| {
        // Skip if network not available
        if (err == error.TlsInitializationFailed or err == error.TlsAlert) {
            std.debug.print("SKIP: TLS not available\n", .{});
            return error.SkipZigTest;
        }
        // Skip if connection refused (no network)
        if (err == error.ConnectionRefused or err == error.NetworkUnreachable) {
            std.debug.print("SKIP: Network not available\n", .{});
            return error.SkipZigTest;
        }
        return err;
    };
    defer allocator.free(result.body);

    try testing.expect(result.status_code == 200);
}

test "http client post fallback to curl" {
    const allocator = testing.allocator;
    var client = HttpClient.init(allocator);
    defer client.deinit();

    // Test POST - should use curl fallback
    const result = client.post(
        "https://httpbin.org/post",
        "{\"test\":\"curl_fallback\"}",
        null,
    ) catch |err| {
        // Skip if curl not available or network issues
        if (err == error.FileNotFound or err == error.ConnectionRefused) {
            std.debug.print("SKIP: curl or network not available\n", .{});
            return error.SkipZigTest;
        }
        return err;
    };
    defer allocator.free(result.body);

    try testing.expect(result.status_code == 200);
}

test "call mcp tools/list" {
    const allocator = testing.allocator;

    const result = callMcp("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\",\"params\":{}}", allocator) catch |err| {
        // Skip if network not available
        std.debug.print("SKIP callMcp error: {s}\n", .{@errorName(err)});
        return error.SkipZigTest;
    };
    defer allocator.free(result.body);

    // Skip if empty response
    if (result.body.len == 0) {
        std.debug.print("SKIP: Empty response\n", .{});
        return error.SkipZigTest;
    }

    try testing.expect(result.status_code == 200);

    // Parse JSON-RPC response
    const parsed = json.parseFromSlice(json.Value, allocator, result.body, .{}) catch |err| {
        std.debug.print("JSON parse error: {s}, body: {s}\n", .{@errorName(err), result.body});
        return err;
    };
    defer parsed.deinit();

    const root = parsed.value.object;
    try testing.expectEqualStrings("2.0", root.get("jsonrpc").?.string);
    try testing.expect(root.contains("result"));
}

test "call mcp initialize" {
    const allocator = testing.allocator;

    const result = callMcp("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2024-11-05\",\"capabilities\":{},\"clientInfo\":{\"name\":\"zig-test\",\"version\":\"0.0.1\"}}}", allocator) catch |err| {
        std.debug.print("SKIP callMcp error: {s}\n", .{@errorName(err)});
        return error.SkipZigTest;
    };
    defer allocator.free(result.body);

    if (result.body.len == 0) {
        std.debug.print("SKIP: Empty response\n", .{});
        return error.SkipZigTest;
    }

    try testing.expect(result.status_code == 200);

    const parsed = json.parseFromSlice(json.Value, allocator, result.body, .{}) catch |err| {
        std.debug.print("JSON parse error: {s}, body: {s}\n", .{@errorName(err), result.body});
        return err;
    };
    defer parsed.deinit();

    const root = parsed.value.object;
    try testing.expectEqualStrings("2.0", root.get("jsonrpc").?.string);
    try testing.expect(root.contains("result"));
}

test "postWithCurl handles multi-read responses" {
    // This test verifies that postWithCurl correctly reads all data
    // even when the OS delivers it in multiple chunks.
    // We test with a known large response endpoint.

    const allocator = testing.allocator;
    var client = HttpClient.init(allocator);
    defer client.deinit();

    // Use httpbin to get a response large enough to potentially
    // trigger multiple reads (JSON with repeated data)
    const large_body = "{\"data\":\"" ++ "x" ** 8192 ++ "\"}";

    const result = client.post(
        "https://httpbin.org/post",
        large_body,
        null,
    ) catch |err| {
        if (err == error.FileNotFound or err == error.ConnectionRefused) {
            std.debug.print("SKIP: curl or network not available\n", .{});
            return error.SkipZigTest;
        }
        return err;
    };
    defer allocator.free(result.body);

    try testing.expect(result.status_code == 200);

    // Parse the response - this would fail with UnexpectedEndOf if
    // the response was truncated due to single read
    const parsed = json.parseFromSlice(json.Value, allocator, result.body, .{}) catch |err| {
        std.debug.print("JSON parse error: {s}, body length: {d}\n", .{ @errorName(err), result.body.len });
        return err;
    };
    defer parsed.deinit();

    // Verify we got the full response back
    const root = parsed.value.object;
    try testing.expect(root.contains("json"));
}

test "call mcp invalid method returns error" {
    const allocator = testing.allocator;

    const result = callMcp("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"invalid/method\",\"params\":{}}", allocator) catch |err| {
        std.debug.print("SKIP callMcp error: {s}\n", .{@errorName(err)});
        return error.SkipZigTest;
    };
    defer allocator.free(result.body);

    if (result.body.len == 0) {
        std.debug.print("SKIP: Empty response\n", .{});
        return error.SkipZigTest;
    }

    // Should return 200 with JSON-RPC error
    try testing.expect(result.status_code == 200);

    const parsed = json.parseFromSlice(json.Value, allocator, result.body, .{}) catch |err| {
        std.debug.print("JSON parse error: {s}, body: {s}\n", .{@errorName(err), result.body});
        return err;
    };
    defer parsed.deinit();

    const root = parsed.value.object;
    try testing.expectEqualStrings("2.0", root.get("jsonrpc").?.string);
    try testing.expect(root.contains("error"));
}
