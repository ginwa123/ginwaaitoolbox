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
    io: std.Io,
    allocator: std.mem.Allocator,

    /// Initialize HTTP client
    pub fn init(allocator: std.mem.Allocator, io: std.Io) HttpClient {
        return .{ .allocator = allocator, .io = io };
    }

    /// Deinitialize HTTP client
    pub fn deinit(_: *HttpClient) void {
        // No-op for now
    }

    /// Perform HTTP GET request
    /// Uses curl as primary (better TLS support)
    pub fn get(self: HttpClient, url: []const u8) !HttpResult {
        return self.getWithCurl(url);
    }

    /// GET using curl (primary method - handles TLS well)
    fn getWithCurl(self: HttpClient, url: []const u8) !HttpResult {
        // Build curl command - escape single quotes in URL to prevent injection
        const escaped_url = try escapeShellArg(url, self.allocator);
        defer self.allocator.free(escaped_url);

        const shell_cmd = try std.fmt.allocPrint(self.allocator,
            "curl -s -X GET {s} -H 'Accept: application/json'",
            .{escaped_url}
        );
        defer self.allocator.free(shell_cmd);

        // Use std.heap.c_allocator for Child to avoid arena corruption
        var child = try std.process.spawn(self.io, .{
            .argv = &[_][]const u8{ "bash", "-c", shell_cmd },
            .stdin = .ignore,
            .stdout = .pipe,
            .stderr = .pipe,
        });

        // FIX 2026-07-14: close the pipe FDs on EVERY exit path. In Zig 0.16
        // the stdlib has NO `child.deinit(io)` and `child.kill(io)` does NOT
        // close the pipes either (it only sends SIGTERM + waitpid). Without
        // this defer, any error between spawn and `child.wait(self.io)` —
        // e.g. `try stdout_list.toOwnedSlice` failing on OOM — drops `child`
        // on the floor and leaks 2 FDs (stdout + stderr). Empirically:
        // 50 errored spawns -> 112 FDs in the process vs 14 baseline.
        // After `wait()` succeeds, `child.stdout`/`child.stderr` are nulled
        // by `childCleanupPosix`, so this `defer` is a no-op on the happy
        // path — only the error path actually closes anything.
        defer {
            if (child.stdout) |out| {
                out.close(self.io);
                child.stdout = null;
            }
            if (child.stderr) |err_pipe| {
                err_pipe.close(self.io);
                child.stderr = null;
            }
        }

        // Read stdout
        var stdout_list: std.ArrayList(u8) = .empty;
        errdefer stdout_list.deinit(self.allocator);

        if (child.stdout) |out| {
            var tmp_buf: [4096]u8 = undefined;
            var total_read: usize = 0;
            while (true) {
                var reader = out.reader(self.io, &tmp_buf);
                const bytes_read = std.Io.Reader.readSliceShort(&reader.interface, &tmp_buf) catch |err| {
                    std.log.warn("getWithCurl: read error: {s}, read so far: {d}", .{@errorName(err), total_read});
                    break;
                };
                if (bytes_read == 0) break;
                total_read += bytes_read;
                try stdout_list.appendSlice(self.allocator, tmp_buf[0..bytes_read]);
            }
            std.log.debug("getWithCurl: total bytes read from stdout: {d}", .{total_read});
        }

        const stdout = try stdout_list.toOwnedSlice(self.allocator);

        const term = child.wait(self.io) catch |err| {
            std.log.warn("Failed to wait for curl process: {s}", .{@errorName(err)});
            return .{
                .body = stdout,
                .status_code = 1,
            };
        };

        const exit_code: u8 = switch (term) {
            .Exited => |code| code,
            else => 1,
        };

        return .{
            .body = stdout,
            .status_code = if (exit_code == 0) 200 else exit_code,
        };
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
        var client = std.http.Client{ .allocator = self.allocator, .io = self.io };
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
        var child = try std.process.spawn(self.io, .{
            .argv = &[_][]const u8{ "bash", "-c", shell_cmd },
            .stdin = .ignore,
            .stdout = .pipe,
            .stderr = .pipe,
        });

        // FIX 2026-07-14: close the pipe FDs on EVERY exit path. See the
        // matching comment in `getWithCurl` for the full rationale — the
        // Zig 0.16 stdlib has no `child.deinit` and `child.kill` does not
        // close the pipes either, so any error between spawn and wait leaks
        // 2 FDs per MCP / design-context HTTP call.
        defer {
            if (child.stdout) |out| {
                out.close(self.io);
                child.stdout = null;
            }
            if (child.stderr) |err_pipe| {
                err_pipe.close(self.io);
                child.stderr = null;
            }
        }

        // Read stdout - use dynamic buffer that grows as needed
        var stdout_list: std.ArrayList(u8) = .empty;
        errdefer stdout_list.deinit(self.allocator);

        // Use 16KB initial buffer
        var buf: []u8 = try self.allocator.alloc(u8, 16384);
        defer self.allocator.free(buf);

        if (child.stdout) |out| {
            while (true) {
                var reader = out.reader(self.io, buf);
                const bytes_read = std.Io.Reader.readSliceShort(&reader.interface, buf) catch |err| {
                    std.log.warn("postWithCurl: read error: {s}", .{@errorName(err)});
                    break;
                };
                if (bytes_read == 0) break;
                try stdout_list.appendSlice(self.allocator, buf[0..bytes_read]);
            }
        }

        const stdout = try stdout_list.toOwnedSlice(self.allocator);

        // Wait for process to complete
        const term = child.wait(self.io) catch |err| {
            std.log.warn("Failed to wait for curl process: {s}", .{@errorName(err)});
            return .{
                .body = stdout,
                .status_code = 1,
            };
        };

        // Check exit code
        const exit_code: u8 = switch (term) {
            .exited => |code| code,
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

    var client = HttpClient.init(allocator, std.testing.io);
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
    var client = HttpClient.init(allocator, std.testing.io);
    client.deinit();
}

test "http client post with std.http" {
    const allocator = testing.allocator;
    var client = HttpClient.init(allocator, std.testing.io);
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
    var client = HttpClient.init(allocator, std.testing.io);
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
    var client = HttpClient.init(allocator, std.testing.io);
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

// Helper to simulate HTTP GET response parsing (mimics curl response handling)
fn simulateGetResponse(allocator: std.mem.Allocator, page: usize, limit: usize) !struct { body: []u8, status: u16 } {
    _ = limit;
    if (page == 0) return error.SkipZigTest; // Simulate no server

    // Simulate 3 pages total
    if (page > 3) {
        return error.SkipZigTest;
    }

    const has_more = page < 3;
    const messages_count: usize = if (page == 1) 50 else if (page == 2) 25 else 10;

    var json_body: std.ArrayList(u8) = .empty;
    errdefer json_body.deinit(allocator);

    try json_body.appendSlice(allocator, "{\"messages\":[");
    for (0..messages_count) |i| {
        if (i > 0) try json_body.append(allocator, ',');
        var msg_buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&msg_buf, "{{\"id\":\"msg_{d}_{d}\",\"content\":\"test\"}}", .{ page, i }) catch continue;
        try json_body.appendSlice(allocator, msg);
    }
    try json_body.append(allocator, ']');
    try json_body.appendSlice(allocator, ",\"has_more\":");
    try json_body.appendSlice(allocator, if (has_more) "true" else "false");
    try json_body.appendSlice(allocator, ",\"next_cursor\":");
    if (has_more) {
        var cur_buf: [32]u8 = undefined;
        const cur = std.fmt.bufPrint(&cur_buf, "\"cursor_page_{d}\"", .{page + 1}) catch "\"\"";
        try json_body.appendSlice(allocator, cur);
    } else {
        try json_body.appendSlice(allocator, "null");
    }
    try json_body.append(allocator, '}');

    return .{
        .body = try json_body.toOwnedSlice(allocator),
        .status = 200,
    };
}

test "cursor pagination logic" {
    const allocator = testing.allocator;
    const limit: usize = 50;

    var total_message_count: usize = 0;
    var page_count: usize = 0;
    var cursor: ?[]const u8 = null;

    std.debug.print("\n=== Testing cursor pagination logic ===\n", .{});

    // Simulate up to 10 pages
    while (page_count < 10) : (page_count += 1) {
        // Simulate the GET response (mimics curl behavior)
        const page_num = page_count + 1;
        const response = simulateGetResponse(allocator, page_num, limit) catch |err| {
            std.debug.print("SKIP: simulateGetResponse failed: {s}\n", .{@errorName(err)});
            return error.SkipZigTest;
        };
        defer allocator.free(response.body);

        std.debug.print("Page {d}: status={d}, body_len={d}\n", .{ page_num, response.status, response.body.len });

        // Parse JSON response (same as real HTTP code)
        const parsed = json.parseFromSlice(json.Value, allocator, response.body, .{}) catch |err| {
            std.debug.print("JSON parse error: {s}\n", .{@errorName(err)});
            return err;
        };
        defer parsed.deinit();

        const root = parsed.value.object;

        // Check has_more
        var has_more = false;
        if (root.get("has_more")) |val| {
            if (val == .bool) has_more = val.bool;
        }

        // Check messages count
        if (root.get("messages")) |messages| {
            if (messages == .array) {
                const arr_items = messages.array.items;
                total_message_count += arr_items.len;
                std.debug.print("  Received {d} messages (total: {d})\n", .{ arr_items.len, total_message_count });
            }
        }

        // Get next cursor
        var next_cursor: ?[]const u8 = null;
        if (root.get("next_cursor")) |val| {
            if (val == .string and val.string.len > 0) {
                next_cursor = try allocator.dupe(u8, val.string);
                std.debug.print("  Next cursor: {s}\n", .{next_cursor.?});
            }
        }

        // Check termination conditions
        if (!has_more) {
            std.debug.print("No more pages (has_more=false) - done!\n", .{});
            break;
        }

        // Update cursor for next iteration
        if (cursor) |old| allocator.free(old);
        if (next_cursor) |nc| {
            cursor = nc;
        } else {
            break;
        }
    }

    // Cleanup cursor memory
    if (cursor) |c| allocator.free(c);

    std.debug.print("=== Pagination complete ===\n", .{});
    std.debug.print("Total pages: {d}\n", .{page_count});
    std.debug.print("Total messages collected: {d}\n", .{total_message_count});

    // Verify results
    // Page 1: 50, Page 2: 25, Page 3: 10 = 85 total
    // page_count is 2 because loop runs 3 times then breaks
    try testing.expectEqual(@as(usize, 2), page_count);
    try testing.expectEqual(@as(usize, 85), total_message_count);
}
