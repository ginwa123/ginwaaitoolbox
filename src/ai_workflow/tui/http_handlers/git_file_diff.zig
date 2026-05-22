const std = @import("std");
const http_response = @import("http_response.zig");
const nalar_core = @import("nalarcore");
const gserverz = nalar_core.gserverz;

/// Git file diff response - returns unified diff output
pub const GitFileDiffResponse = struct {
    path: []const u8,
    diff_content: []const u8,  // Unified diff output from git diff
    staged: bool
};

/// Git file read response
pub const GitFileReadResponse = struct {
    content: []const u8,
    encoding: []const u8
};

/// Get git diff for a specific file using git diff command
pub fn gitFileDiffHandler(ctx: gserverz.HttpContext, req: gserverz.HttpRequest, res: gserverz.HttpResponse) !gserverz.HttpResponse {
    const allocator = ctx.allocator;
    const io = ctx.io;

    // Get path and file from query parameters
    const query = req.query;
    const path_param = query.get("path") orelse {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeGitStatusErrorResponse(allocator, "Missing path parameter") });
    };
    const file_param = query.get("file") orelse {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeGitStatusErrorResponse(allocator, "Missing file parameter") });
    };
    const staged_param = query.get("staged") orelse "false";
    const staged = std.mem.eql(u8, staged_param, "true");

    // Use git diff command to get proper diff output
    // For staged: git diff --cached -- <file> (staged vs HEAD)
    // For unstaged: git diff -- <file> (working tree vs staged area)
    var diff_content: []const u8 = "";
    
    if (staged) {
        const argv: [7][]const u8 = .{ "git", "-C", path_param, "diff", "--cached", "--", file_param };
        if (std.process.run(allocator, io, .{ .argv = &argv })) |result| {
            if (result.term.exited == 0 or result.term.exited == 1) {
                diff_content = result.stdout;
            }
        } else |_| {}
    } else {
        const argv: [6][]const u8 = .{ "git", "-C", path_param, "diff", "--", file_param };
        if (std.process.run(allocator, io, .{ .argv = &argv })) |result| {
            if (result.term.exited == 0 or result.term.exited == 1) {
                diff_content = result.stdout;
            }
        } else |_| {}
    }
    
    // For files that are newly added (never committed), git diff returns empty
    // Fall back to reading the working tree file to build a synthetic diff
    // This handles both staged=true (new staged file) and staged=false (new unstaged file)
    if (diff_content.len == 0) {
        const full_file_path = std.fs.path.join(allocator, &.{ path_param, file_param }) catch "";
        if (full_file_path.len > 0) {
            defer allocator.free(full_file_path);
            const file = std.Io.Dir.openFileAbsolute(io, full_file_path, .{}) catch null;
            if (file) |f| {
                defer f.close(io);
                var read_buf: [8192]u8 = undefined;
                var reader = f.reader(io, &read_buf);
                const content = reader.interface.allocRemaining(allocator, .limited(1024 * 1024)) catch "";
                if (content.len > 0) {
                    diff_content = buildNewFileDiff(allocator, file_param, content) catch "";
                    allocator.free(content);
                }
            }
        }
    }

    const response = GitFileDiffResponse{
        .path = file_param,
        .diff_content = diff_content,
        .staged = staged
    };

    return res.jsonResponse(.{ .status_code = 200, .data = try makeGitFileDiffResponse(allocator, response) });
}

/// Read a file from git repository (working tree)
pub fn gitFileReadHandler(ctx: gserverz.HttpContext, req: gserverz.HttpRequest, res: gserverz.HttpResponse) !gserverz.HttpResponse {
    const allocator = ctx.allocator;
    const io = ctx.io;

    // Get path and file from query parameters
    const query = req.query;
    const path_param = query.get("path") orelse {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeGitStatusErrorResponse(allocator, "Missing path parameter") });
    };
    const file_param = query.get("file") orelse {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeGitStatusErrorResponse(allocator, "Missing file parameter") });
    };

    // Build full file path
    const file_path = std.fs.path.join(allocator, &.{ path_param, file_param }) catch |err| {
        return res.jsonResponse(.{ .status_code = 500, .data = try http_response.makeGitStatusErrorResponse(allocator, @errorName(err)) });
    };
    defer allocator.free(file_path);

    // Read the file using std.Io.Dir
    const file = std.Io.Dir.openFileAbsolute(io, file_path, .{}) catch |err| {
        return res.jsonResponse(.{ .status_code = 404, .data = try http_response.makeGitStatusErrorResponse(allocator, @errorName(err)) });
    };
    defer file.close(io);

    var read_buffer: [4096]u8 = undefined;
    var reader = file.reader(io, &read_buffer);
    const content = reader.interface.allocRemaining(allocator, .limited(10 * 1024 * 1024)) catch |err| {
        return res.jsonResponse(.{ .status_code = 500, .data = try http_response.makeGitStatusErrorResponse(allocator, @errorName(err)) });
    };

    const response = GitFileReadResponse{
        .content = content,
        .encoding = "utf-8"
    };

    return res.jsonResponse(.{ .status_code = 200, .data = try makeGitFileReadResponse(allocator, response) });
}

/// Build a synthetic unified diff for a newly staged file (never committed before)
/// This shows the file as being added from /dev/null to the staged content
fn buildNewFileDiff(allocator: std.mem.Allocator, file_path: []const u8, staged_content: []const u8) ![]const u8 {
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(allocator);
    
    // Count lines in staged content
    var line_count: usize = 0;
    for (staged_content) |c| {
        if (c == '\n') line_count += 1;
    }
    if (staged_content.len > 0 and staged_content[staged_content.len - 1] != '\n') {
        line_count += 1;
    }
    
    // Build the diff header
    try buf.appendSlice(allocator, "diff --git a/");
    try buf.appendSlice(allocator, file_path);
    try buf.appendSlice(allocator, " b/");
    try buf.appendSlice(allocator, file_path);
    try buf.appendSlice(allocator, "\nnew file mode");
    try buf.appendSlice(allocator, "\n--- /dev/null\n+++ b/");
    try buf.appendSlice(allocator, file_path);
    try buf.appendSlice(allocator, "\n@@ -0,0 +1,");
    try buf.appendSlice(allocator, try std.fmt.allocPrint(allocator, "{}", .{line_count}));
    try buf.appendSlice(allocator, " @@\n");
    
    // Append each line with + prefix
    var start: usize = 0;
    while (std.mem.indexOfScalar(u8, staged_content[start..], '\n')) |idx| {
        try buf.appendSlice(allocator, "+");
        try buf.appendSlice(allocator, staged_content[start .. start + idx]);
        try buf.append(allocator, '\n');
        start += idx + 1;
    }
    // Handle last line without newline
    if (start < staged_content.len) {
        try buf.appendSlice(allocator, "+");
        try buf.appendSlice(allocator, staged_content[start..]);
        try buf.append(allocator, '\n');
    }
    
    return try buf.toOwnedSlice(allocator);
}

/// Custom JSON serialization for GitFileDiffResponse
fn makeGitFileDiffResponse(allocator: std.mem.Allocator, response: GitFileDiffResponse) ![]u8 {
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(allocator);
    
    // Helper to escape a string for JSON
    const escapeString = struct {
        fn escape(a: std.mem.Allocator, s: []const u8) ![]u8 {
            var result = std.ArrayList(u8).empty;
            defer result.deinit(a);
            
            for (s) |c| {
                switch (c) {
                    '"' => try result.appendSlice(a, "\\\""),
                    '\\' => try result.appendSlice(a, "\\\\"),
                    '\n' => try result.appendSlice(a, "\\n"),
                    '\r' => try result.appendSlice(a, "\\r"),
                    '\t' => try result.appendSlice(a, "\\t"),
                    else => try result.append(a, c)
                }
            }
            return try result.toOwnedSlice(a);
        }
    }.escape;
    
    try buf.appendSlice(allocator, "{\"path\":\"");
    const escaped_path = try escapeString(allocator, response.path);
    try buf.appendSlice(allocator, escaped_path);
    try buf.appendSlice(allocator, "\", \"diff_content\":\"");
    const escaped_diff = try escapeString(allocator, response.diff_content);
    try buf.appendSlice(allocator, escaped_diff);
    try buf.appendSlice(allocator, "\", \"staged\":");
    try buf.appendSlice(allocator, if (response.staged) "true" else "false");
    try buf.appendSlice(allocator, "}");
    
    return try buf.toOwnedSlice(allocator);
}

/// Custom JSON serialization for GitFileReadResponse
fn makeGitFileReadResponse(allocator: std.mem.Allocator, response: GitFileReadResponse) ![]u8 {
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(allocator);
    
    // Helper to escape a string for JSON
    const escapeString = struct {
        fn escape(a: std.mem.Allocator, s: []const u8) ![]u8 {
            var result = std.ArrayList(u8).empty;
            defer result.deinit(a);
            
            for (s) |c| {
                switch (c) {
                    '"' => try result.appendSlice(a, "\\\""),
                    '\\' => try result.appendSlice(a, "\\\\"),
                    '\n' => try result.appendSlice(a, "\\n"),
                    '\r' => try result.appendSlice(a, "\\r"),
                    '\t' => try result.appendSlice(a, "\\t"),
                    else => try result.append(a, c)
                }
            }
            return try result.toOwnedSlice(a);
        }
    }.escape;
    
    try buf.appendSlice(allocator, "{\"content\":\"");
    const escaped_content = try escapeString(allocator, response.content);
    try buf.appendSlice(allocator, escaped_content);
    try buf.appendSlice(allocator, "\", \"encoding\":\"");
    try buf.appendSlice(allocator, response.encoding);
    try buf.appendSlice(allocator, "\"}");
    
    return try buf.toOwnedSlice(allocator);
}