const std = @import("std");
const sse = @import("sse.zig");

test "decode_chuncked: simple single chunk" {
    const raw = "Hello";
    const result = try sse.decode_chuncked(std.testing.allocator, raw);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("Hello", result);
}

test "decode_chuncked: single chunk with headers" {
    const raw = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\n5\r\nHello\r\n0\r\n\r\n";
    const result = try sse.decode_chuncked(std.testing.allocator, raw);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("Hello", result);
}

test "decode_chuncked: multiple chunks" {
    const raw = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nHello\r\n6\r\n World\r\n0\r\n\r\n";
    const result = try sse.decode_chuncked(std.testing.allocator, raw);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("Hello World", result);
}

test "decode_chuncked: hex sized chunks (1A)" {
    // 1A = 26 bytes, need exactly 26 chars of data
    const raw = "HTTP/1.1 200 OK\r\n\r\n1A\r\n0123456789ABCDEF0123456789\r\n0\r\n\r\n";
    const result = try sse.decode_chuncked(std.testing.allocator, raw);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("0123456789ABCDEF0123456789", result);
}

test "decode_chuncked: hex sized chunks (FF)" {
    const raw = "HTTP/1.1 200 OK\r\n\r\nFF\r\n0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0\r\n0\r\n\r\n";
    const result = try sse.decode_chuncked(std.testing.allocator, raw);
    defer std.testing.allocator.free(result);
    // FF = 255 bytes
    try std.testing.expect(255 == result.len);
}

test "decode_chuncked: zero terminator only" {
    const raw = "HTTP/1.1 200 OK\r\n\r\n0\r\n\r\n";
    const result = try sse.decode_chuncked(std.testing.allocator, raw);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("", result);
}

test "decode_chuncked: chunks with leading newline before size" {
    const raw = "HTTP/1.1 200 OK\r\n\r\n5\r\nHello\r\n0\r\n\r\n";
    const result = try sse.decode_chuncked(std.testing.allocator, raw);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("Hello", result);
}

test "decode_chuncked: no headers, raw body only" {
    const raw = "Hello World";
    const result = try sse.decode_chuncked(std.testing.allocator, raw);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("Hello World", result);
}

test "decode_chuncked: passthrough when not chunked" {
    const raw = "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nHello";
    const result = try sse.decode_chuncked(std.testing.allocator, raw);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("Hello", result);
}

test "decode_chuncked: binary data" {
    const raw = "HTTP/1.1 200 OK\r\n\r\n8\r\n\x00\x01\x02\x03\x04\x05\x06\x07\r\n0\r\n\r\n";
    const result = try sse.decode_chuncked(std.testing.allocator, raw);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0, 1, 2, 3, 4, 5, 6, 7 }, result);
}

test "decode_chuncked: empty input" {
    const raw = "";
    const result = try sse.decode_chuncked(std.testing.allocator, raw);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("", result);
}
