const std = @import("std");
const http_server = @import("http_server.zig");

test "HttpServer init with default port" {
    const allocator = std.testing.allocator;
    var server = http_server.HttpServer.init(allocator, null, 0);
    defer server.deinit();
    
    try std.testing.expectEqual(@as(u16, 8080), server.port);
}

test "HttpServer init with custom port" {
    const allocator = std.testing.allocator;
    var server = http_server.HttpServer.init(allocator, null, 9000);
    defer server.deinit();
    
    try std.testing.expectEqual(@as(u16, 9000), server.port);
}

test "HttpServer can set message handler" {
    const allocator = std.testing.allocator;
    var server = http_server.HttpServer.init(allocator, null, 8080);
    defer server.deinit();
    
    const Handler = struct {
        fn handle(alloc: std.mem.Allocator, data: []const u8, ctx: ?*anyopaque) void {
            _ = alloc;
            _ = data;
            _ = ctx;
        }
    };
    
    server.setMessageHandler(Handler.handle);
    try std.testing.expect(server.message_handler != null);
}

test "HttpServer command parsing extracts command type" {
    const allocator = std.testing.allocator;
    const json = "{\"command_type\":\"run_llm\",\"session_id\":\"test123\",\"content\":\"hello\",\"cwd_session\":\"/tmp\"}";
    
    var cmd = try http_server.parseCommand(allocator, json);
    defer cmd.deinit(allocator);
    
    try std.testing.expectEqualStrings("run_llm", cmd.command_type);
    try std.testing.expectEqualStrings("test123", cmd.session_id);
    try std.testing.expectEqualStrings("hello", cmd.content);
    try std.testing.expectEqualStrings("/tmp", cmd.cwd_session);
}

test "HttpServer command parsing handles missing optional fields" {
    const allocator = std.testing.allocator;
    const json = "{\"command_type\":\"test\"}";
    
    var cmd = try http_server.parseCommand(allocator, json);
    defer cmd.deinit(allocator);
    
    try std.testing.expectEqualStrings("test", cmd.command_type);
    try std.testing.expectEqualStrings("", cmd.session_id);
    try std.testing.expectEqualStrings("", cmd.content);
    try std.testing.expectEqualStrings("", cmd.cwd_session);
}

test "SseEvent formats correctly" {
    const allocator = std.testing.allocator;
    const event = http_server.SseEvent{
        .event_type = "message",
        .data = "Hello, World!",
    };
    
    const formatted = try event.format(allocator);
    defer allocator.free(formatted);
    
    try std.testing.expect(std.mem.containsAtLeast(u8, formatted, 1, "event: message\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, formatted, 1, "data: Hello, World!\n\n"));
}

test "SseEvent handles multiline data" {
    const allocator = std.testing.allocator;
    const event = http_server.SseEvent{
        .event_type = "chunk",
        .data = "line1\nline2",
    };
    
    const formatted = try event.format(allocator);
    defer allocator.free(formatted);
    
    try std.testing.expect(std.mem.containsAtLeast(u8, formatted, 1, "event: chunk\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, formatted, 1, "data: line1\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, formatted, 1, "data: line2\n"));
}

test "SseConnectionManager init and deinit" {
    const allocator = std.testing.allocator;
    var manager = http_server.SseConnectionManager.init(allocator);
    defer manager.deinit();
    
    try std.testing.expect(manager.connections.count() == 0);
}

test "SseConnectionManager can register and get connection" {
    const allocator = std.testing.allocator;
    var manager = http_server.SseConnectionManager.init(allocator);
    defer manager.deinit();
    
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(allocator);
    
    try manager.register("session123", &buf);
    
    const result = manager.get("session123");
    try std.testing.expect(result != null);
}

test "SseConnectionManager can send event" {
    const allocator = std.testing.allocator;
    var manager = http_server.SseConnectionManager.init(allocator);
    defer manager.deinit();
    
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(allocator);
    
    try manager.register("session123", &buf);
    
    const event = http_server.SseEvent{
        .event_type = "message",
        .data = "test",
    };
    
    try manager.sendEvent("session123", event, allocator);
    
    const result = manager.get("session123");
    try std.testing.expect(result != null);
    try std.testing.expect(result.?.items.len > 0);
}
