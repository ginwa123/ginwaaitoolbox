const std = @import("std");

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

    // Check if this looks like chunked encoding (starts with hex number)
    const maybe_chunked = pos < raw.len and
        (std.ascii.isHex(raw[pos]) or raw[pos] == '\r' or raw[pos] == '\n');

    if (maybe_chunked and header_end != null) {
        // Parse chunked encoding
        while (pos < raw.len) {
            // Find end of chunk size line
            const size_end = std.mem.indexOfPos(u8, raw, pos, "\r\n") orelse break;
            const size_str = std.mem.trim(u8, raw[pos..size_end], " \t");
            if (size_str.len == 0) {
                pos = size_end + 2;
                continue;
            }

            // Parse hex chunk size
            const chunk_size = std.fmt.parseInt(usize, size_str, 16) catch {
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
        try out.appendSlice(allocator, raw[pos..]);
    }

    return out.toOwnedSlice(allocator);
}

/// SSE parser
///
/// After chunked decode, SSE lines look like:
///   data: {"event":"chunk","data":"<xml escaped>"}\n\n
///   : keepalive\n\n
///
/// This extracts and unescapes the "data" JSON field value from each data: line,
/// concatenating all of them into one XML string.
pub fn extract_sse_data(allocator: std.mem.Allocator, sse_text: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    var lines = std.mem.splitScalar(u8, sse_text, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, "\r");

        // Skip empty lines (SSE event boundaries)
        if (trimmed.len == 0) continue;

        // Skip comment lines (keepalive, etc.)
        if (std.mem.startsWith(u8, trimmed, ":")) continue;

        // Skip event type lines - we just want the data
        if (std.mem.startsWith(u8, trimmed, "event:")) continue;

        // Extract data lines
        if (std.mem.startsWith(u8, trimmed, "data:")) {
            const payload = trimmed["data:".len..];
            // Add newline separator between data lines (SSE spec)
            if (out.items.len > 0) {
                try out.append(allocator, '\n');
            }
            try out.appendSlice(allocator, payload);
        }
    }

    return out.toOwnedSlice(allocator);
}
