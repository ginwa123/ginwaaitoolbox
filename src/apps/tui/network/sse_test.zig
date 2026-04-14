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

test "decode_chuncked: JSON with numbers should NOT be parsed as chunked" {
    // JSON like {"id": 12345} contains hex chars but should NOT be treated as chunked
    const raw = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n{\"id\": 12345, \"data\": \"test\"}";
    const result = try sse.decode_chuncked(std.testing.allocator, raw);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("{\"id\": 12345, \"data\": \"test\"}", result);
}

test "decode_chuncked: JSON with hex-like content should NOT be parsed as chunked" {
    // JSON with content that looks like chunked but isn't (no CRLF after size)
    const raw = "HTTP/1.1 200 OK\r\n\r\n{\"chunk\": \"abc123def\"}";
    const result = try sse.decode_chuncked(std.testing.allocator, raw);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("{\"chunk\": \"abc123def\"}", result);
}

test "decode_chuncked: valid JSON starting with hex-looking number" {
    // JSON starting with a hex-like number without chunked headers
    const raw = "{\"status\": 200, \"message\": \"ok\"}";
    const result = try sse.decode_chuncked(std.testing.allocator, raw);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("{\"status\": 200, \"message\": \"ok\"}", result);
}

// ============================================================================
// extract_sse_data tests
// ============================================================================

test "extract_sse_data: basic single data line" {
    const sse_text = "data: <xml>hello</xml>\n\n";
    const result = try sse.extract_sse_data(std.testing.allocator, sse_text);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings(" <xml>hello</xml>", result);
}

test "extract_sse_data: multiple data lines concatenated with newlines" {
    // SSE spec: multiple data: lines are concatenated with single newline
    const sse_text = "data: <xml>part1</xml>\ndata: <xml>part2</xml>\n\n";
    const result = try sse.extract_sse_data(std.testing.allocator, sse_text);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings(" <xml>part1</xml>\n <xml>part2</xml>", result);
}

test "extract_sse_data: skips comment lines" {
    const sse_text = ": keepalive\ndata: <xml>hello</xml>\n\n";
    const result = try sse.extract_sse_data(std.testing.allocator, sse_text);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings(" <xml>hello</xml>", result);
}

test "extract_sse_data: skips event type lines" {
    const sse_text = "event: chunk\ndata: <xml>hello</xml>\n\n";
    const result = try sse.extract_sse_data(std.testing.allocator, sse_text);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings(" <xml>hello</xml>", result);
}

test "extract_sse_data: mixed content real SSE format" {
    const sse_text =
        \\: keepalive
        \\event: chunk
        \\data: {"event":"chunk","data":"<xml>escaped</xml>"}
        \\
    ;
    const result = try sse.extract_sse_data(std.testing.allocator, sse_text);
    defer std.testing.allocator.free(result);
    // Space after "data:" is preserved
    try std.testing.expectEqualStrings(
        \\ {"event":"chunk","data":"<xml>escaped</xml>"}
    , result);
}

test "extract_sse_data: empty input returns empty" {
    const sse_text = "";
    const result = try sse.extract_sse_data(std.testing.allocator, sse_text);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("", result);
}

test "extract_sse_data: no data lines returns empty" {
    const sse_text = ": keepalive\nevent: ping\n\n";
    const result = try sse.extract_sse_data(std.testing.allocator, sse_text);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("", result);
}

test "extract_sse_data: data with carriage returns" {
    const sse_text = "data: <xml>hello</xml>\r\n\n";
    const result = try sse.extract_sse_data(std.testing.allocator, sse_text);
    defer std.testing.allocator.free(result);
    // Space after "data:" is preserved
    try std.testing.expectEqualStrings(" <xml>hello</xml>", result);
}

test "extract_sse_data: three data lines" {
    const sse_text = "data: line1\ndata: line2\ndata: line3\n\n";
    const result = try sse.extract_sse_data(std.testing.allocator, sse_text);
    defer std.testing.allocator.free(result);
    // Space after "data:" is preserved
    try std.testing.expectEqualStrings(" line1\n line2\n line3", result);
}

test "extract_sse_data: strips carriage return from data payload" {
    const sse_text = "data: payload\r\n\n";
    const result = try sse.extract_sse_data(std.testing.allocator, sse_text);
    defer std.testing.allocator.free(result);
    // Space after "data:" is preserved
    try std.testing.expectEqualStrings(" payload", result);
}

test "extract_sse_data: data without space after colon" {
    // Some SSE implementations may not have space after "data:"
    const sse_text = "data:<xml>hello</xml>\n\n";
    const result = try sse.extract_sse_data(std.testing.allocator, sse_text);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("<xml>hello</xml>", result);
}

test "extract_sse_data: id field is skipped" {
    const sse_text = "id: 123\nevent: message\ndata: <xml>hello</xml>\n\n";
    const result = try sse.extract_sse_data(std.testing.allocator, sse_text);
    defer std.testing.allocator.free(result);
    // Space after "data:" is preserved
    try std.testing.expectEqualStrings(" <xml>hello</xml>", result);
}

test "extract_sse_data: consecutive empty lines are skipped" {
    const sse_text = "\n\ndata: <xml>hello</xml>\n\n\n\n";
    const result = try sse.extract_sse_data(std.testing.allocator, sse_text);
    defer std.testing.allocator.free(result);
    // Space after "data:" is preserved
    try std.testing.expectEqualStrings(" <xml>hello</xml>", result);
}

test "extract_sse_data: retry field is skipped" {
    const sse_text = "retry: 5000\nevent: message\ndata: <xml>hello</xml>\n\n";
    const result = try sse.extract_sse_data(std.testing.allocator, sse_text);
    defer std.testing.allocator.free(result);
    // Space after "data:" is preserved
    try std.testing.expectEqualStrings(" <xml>hello</xml>", result);
}

test "extract_sse_data: comment with space after colon is skipped" {
    const sse_text = ": This is a comment\ndata: <xml>hello</xml>\n\n";
    const result = try sse.extract_sse_data(std.testing.allocator, sse_text);
    defer std.testing.allocator.free(result);
    // Space after "data:" is preserved
    try std.testing.expectEqualStrings(" <xml>hello</xml>", result);
}
