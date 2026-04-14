const std = @import("std");
const debug = @import("debug.zig");

/// Chunked transfer encoding decoder
///
/// HTTP/1.1 chunked format:
///   <hex size>\r\n
///   <data>\r\n
///   0\r\n\r\n   <- end
///
/// Strips HTTP headers and chunk size lines, returns raw SSE text.
pub fn decode_chuncked(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    // Skip HTTP response headers if present
    const header_end = std.mem.indexOf(u8, raw, "\r\n\r\n");
    var pos: usize = if (header_end) |end| end + 4 else 0;

    // Check if this looks like chunked encoding:
    // 1. Must have HTTP headers (header_end != null)
    // 2. After headers, position must have hex chars followed by CRLF
    const looks_like_chunked = block: {
        if (header_end == null) break :block false;
        if (pos >= raw.len) break :block false;

        // Must start with hex digit (chunk size)
        if (!std.ascii.isHex(raw[pos])) break :block false;

        // Must find CRLF after the hex number (chunk size line)
        const maybe_crlf = std.mem.indexOf(u8, raw[pos..], "\r\n");
        if (maybe_crlf == null or maybe_crlf.? == 0) break :block false;

        // The chunk size line should be valid hex
        const size_end = pos + maybe_crlf.?;
        const size_str = std.mem.trim(u8, raw[pos..size_end], " \t");
        if (size_str.len == 0) break :block false;

        // Try to parse - if it fails, it's not chunked
        const chunk_size = std.fmt.parseInt(usize, size_str, 16) catch break :block false;
        _ = chunk_size; // suppress unused warning

        break :block true;
    };

    if (looks_like_chunked) {
        // Parse chunked encoding
        debug.logVerbose("decode_chuncked: parsing chunked encoding, pos={d}, raw_len={d}", .{pos, raw.len});
        while (pos < raw.len) {
            // Find end of chunk size line
            const size_end = std.mem.indexOfPos(u8, raw, pos, "\r\n") orelse {
                debug.logError("decode_chuncked: failed to find CRLF at pos={d}", .{pos});
                break;
            };
            const size_str = std.mem.trim(u8, raw[pos..size_end], " \t");
            if (size_str.len == 0) {
                pos = size_end + 2;
                continue;
            }

            // Parse hex chunk size
            const chunk_size = std.fmt.parseInt(usize, size_str, 16) catch {
                debug.logError("decode_chuncked: failed to parse chunk size '{s}'", .{size_str});
                pos = size_end + 2;
                continue;
            };

            if (chunk_size == 0) break; // end of chunked stream

            pos = size_end + 2;
            if (pos + chunk_size > raw.len) break; // incomplete, wait for more data

            try out.appendSlice(allocator, raw[pos .. pos + chunk_size]);
            pos += chunk_size;

            // Skip trailing \r\n after chunk data
            if (pos + 2 <= raw.len and raw[pos] == '\r' and raw[pos + 1] == '\n') {
                pos += 2;
            }
        }
    } else {
        // No chunked encoding - just return body (or entire input if no headers)
        debug.logVerbose("decode_chuncked: no chunked encoding detected, returning {d} bytes", .{raw.len});
        try out.appendSlice(allocator, raw[pos..]);
    }

    return out.toOwnedSlice(allocator);
}

/// SSE parser
///
/// After chunked decode, SSE events look like:
///   event: <type>
///   <raw xml content>
///
///
///   : keepalive
///
///
/// This extracts the raw XML content from each event, skipping
/// the event: line and comment lines.
pub fn extract_sse_data(allocator: std.mem.Allocator, sse_text: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    debug.logVerbose("extract_sse_data: processing {d} bytes of SSE text", .{sse_text.len});

    var lines = std.mem.splitScalar(u8, sse_text, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, "\r");

        // Skip empty lines (SSE event boundaries)
        if (trimmed.len == 0) continue;

        // Skip comment lines (keepalive, etc.)
        if (std.mem.startsWith(u8, trimmed, ":")) continue;

        // Skip SSE metadata fields - we only want data content
        if (std.mem.startsWith(u8, trimmed, "event:")) continue;
        if (std.mem.startsWith(u8, trimmed, "id:")) continue;
        if (std.mem.startsWith(u8, trimmed, "retry:")) continue;

        // Strip "data:" prefix if present (keep space after data:)
        var content = trimmed;
        if (std.mem.startsWith(u8, content, "data:")) {
            content = content["data:".len..];
        }

        // Pass through raw content after stripping data: prefix
        debug.logVerbose("extract_sse_data: found content line, len={d}", .{content.len});
        if (out.items.len > 0) {
            try out.append(allocator, '\n');
        }
        try out.appendSlice(allocator, content);
    }

    debug.logVerbose("extract_sse_data: extracted {d} bytes", .{out.items.len});

    return out.toOwnedSlice(allocator);
}
