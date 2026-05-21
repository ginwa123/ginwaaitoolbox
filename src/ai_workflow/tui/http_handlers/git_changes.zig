const std = @import("std");
const http_response = @import("http_response.zig");
const nalar_core = @import("nalarcore");
const gserverz = nalar_core.gserverz;

/// Git file change structure
pub const GitFileChange = struct {
    index_status: []const u8,  // Status in staging area
    worktree_status: []const u8,  // Status in working tree
    path: []const u8
};

/// Git changes response with staged and unstaged files
pub const GitChangesResponse = struct {
    is_git_repo: bool,
    branch: ?[]const u8 = null,
    has_changes: bool = false,
    staged_files: []const GitFileChange = &.{},
    modified_files: []const GitFileChange = &.{},
    untracked_files: []const GitFileChange = &.{}
};

/// Parse git status --porcelain output and separate staged/unstaged files
fn parseGitStatus(allocator: std.mem.Allocator, output: []const u8) GitChangesResponse {
    var staged_files = std.ArrayList(GitFileChange).empty;
    var modified_files = std.ArrayList(GitFileChange).empty;
    var untracked_files = std.ArrayList(GitFileChange).empty;
    
    var start: usize = 0;
    while (start < output.len) {
        // Find end of line
        const end = std.mem.indexOfScalar(u8, output[start..], '\n') orelse output.len;
        const line = output[start..start+end];
        
        if (line.len >= 3) {
            const indexStatus = line[0..1];
            const worktreeStatus = line[1..2];
            const path = line[3..];
            
            const change = GitFileChange{
                .index_status = indexStatus,
                .worktree_status = worktreeStatus,
                .path = path
            };
            
            // Untracked files start with '??'
            if (std.mem.eql(u8, indexStatus, "??")) {
                untracked_files.append(allocator, change) catch {};
            }
            // Staged changes have non-space in first position
            else if (!std.mem.eql(u8, indexStatus, " ")) {
                staged_files.append(allocator, change) catch {};
            }
            // Modified files in worktree (not staged)
            if (!std.mem.eql(u8, worktreeStatus, " ") and !std.mem.eql(u8, indexStatus, "??")) {
                modified_files.append(allocator, change) catch {};
            }
        }
        
        start += end + 1;
    }
    
    return GitChangesResponse{
        .is_git_repo = true,
        .staged_files = staged_files.toOwnedSlice(allocator) catch &.{},
        .modified_files = modified_files.toOwnedSlice(allocator) catch &.{},
        .untracked_files = untracked_files.toOwnedSlice(allocator) catch &.{},
        .has_changes = staged_files.items.len > 0 or modified_files.items.len > 0 or untracked_files.items.len > 0
    };
}

/// Git changes endpoint - returns staged, unstaged, and untracked files
pub fn gitChangesHandler(ctx: gserverz.HttpContext, req: gserverz.HttpRequest, res: gserverz.HttpResponse) !gserverz.HttpResponse {
    const allocator = ctx.allocator;
    const io = ctx.io;

    // Get path from query parameter
    const query = req.query;
    const path_param = query.get("path") orelse {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeGitStatusErrorResponse(allocator, "Missing path parameter") });
    };

    // Check if we're in a git repo by running git rev-parse --git-dir with -C
    const git_check = std.process.run(allocator, io, .{
        .argv = &.{ "git", "-C", path_param, "rev-parse", "--git-dir" },
    }) catch |err| {
        return res.jsonResponse(.{ .status_code = 500, .data = try http_response.makeGitStatusErrorResponse(allocator, @errorName(err)) });
    };

    // Determine if it's a git repo based on rev-parse exit code
    const is_git_repo = git_check.term.exited == 0;

    // If not a git repo, return early
    if (!is_git_repo) {
        const response = GitChangesResponse{
            .is_git_repo = false,
            .staged_files = &.{},
            .modified_files = &.{},
            .untracked_files = &.{}
        };
        return res.jsonResponse(.{ .status_code = 200, .data = try makeGitChangesResponse(allocator, response) });
    }

    // Get current branch using: git -C <path> branch --show-current
    const branch_result = std.process.run(allocator, io, .{
        .argv = &.{ "git", "-C", path_param, "branch", "--show-current" },
    }) catch |err| {
        return res.jsonResponse(.{ .status_code = 500, .data = try http_response.makeGitStatusErrorResponse(allocator, @errorName(err)) });
    };
    const branch_name = std.mem.trim(u8, branch_result.stdout, " \n\r");

    // Get status using: git -C <path> status --porcelain
    const status_result = std.process.run(allocator, io, .{
        .argv = &.{ "git", "-C", path_param, "status", "--porcelain" },
    }) catch |err| {
        return res.jsonResponse(.{ .status_code = 500, .data = try http_response.makeGitStatusErrorResponse(allocator, @errorName(err)) });
    };

    // Parse the status output
    var response = parseGitStatus(allocator, status_result.stdout);
    response.is_git_repo = true;
    response.branch = branch_name;

    return res.jsonResponse(.{ .status_code = 200, .data = try makeGitChangesResponse(allocator, response) });
}

/// Custom JSON serialization for GitChangesResponse using std.json
fn makeGitChangesResponse(allocator: std.mem.Allocator, response: GitChangesResponse) ![]u8 {
    // Build JSON manually with proper escaping
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
    
    try buf.appendSlice(allocator, "{\"is_git_repo\":");
    try buf.appendSlice(allocator, if (response.is_git_repo) "true" else "false");
    
    try buf.appendSlice(allocator, ", \"branch\":");
    if (response.branch) |b| {
        const escaped = try escapeString(allocator, b);
        try buf.appendSlice(allocator, "\"");
        try buf.appendSlice(allocator, escaped);
        try buf.appendSlice(allocator, "\"");
    } else {
        try buf.appendSlice(allocator, "null");
    }
    
    try buf.appendSlice(allocator, ", \"has_changes\":");
    try buf.appendSlice(allocator, if (response.has_changes) "true" else "false");
    
    // staged_files
    try buf.appendSlice(allocator, ", \"staged_files\":[");
    for (response.staged_files, 0..) |file, i| {
        if (i > 0) try buf.appendSlice(allocator, ",");
        try buf.appendSlice(allocator, "{\"index_status\":\"");
        try buf.appendSlice(allocator, file.index_status);
        try buf.appendSlice(allocator, "\", \"worktree_status\":\"");
        try buf.appendSlice(allocator, file.worktree_status);
        try buf.appendSlice(allocator, "\", \"path\":\"");
        const escaped_path = try escapeString(allocator, file.path);
        try buf.appendSlice(allocator, escaped_path);
        try buf.appendSlice(allocator, "\"}");
    }
    try buf.appendSlice(allocator, "]");
    
    // modified_files
    try buf.appendSlice(allocator, ", \"modified_files\":[");
    for (response.modified_files, 0..) |file, i| {
        if (i > 0) try buf.appendSlice(allocator, ",");
        try buf.appendSlice(allocator, "{\"index_status\":\"");
        try buf.appendSlice(allocator, file.index_status);
        try buf.appendSlice(allocator, "\", \"worktree_status\":\"");
        try buf.appendSlice(allocator, file.worktree_status);
        try buf.appendSlice(allocator, "\", \"path\":\"");
        const escaped_path = try escapeString(allocator, file.path);
        try buf.appendSlice(allocator, escaped_path);
        try buf.appendSlice(allocator, "\"}");
    }
    try buf.appendSlice(allocator, "]");
    
    // untracked_files
    try buf.appendSlice(allocator, ", \"untracked_files\":[");
    for (response.untracked_files, 0..) |file, i| {
        if (i > 0) try buf.appendSlice(allocator, ",");
        try buf.appendSlice(allocator, "{\"index_status\":\"");
        try buf.appendSlice(allocator, file.index_status);
        try buf.appendSlice(allocator, "\", \"worktree_status\":\"");
        try buf.appendSlice(allocator, file.worktree_status);
        try buf.appendSlice(allocator, "\", \"path\":\"");
        const escaped_path = try escapeString(allocator, file.path);
        try buf.appendSlice(allocator, escaped_path);
        try buf.appendSlice(allocator, "\"}");
    }
    try buf.appendSlice(allocator, "]}");
    
    return try buf.toOwnedSlice(allocator);
}