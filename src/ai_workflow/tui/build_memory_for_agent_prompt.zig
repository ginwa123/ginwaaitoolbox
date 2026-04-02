const std = @import("std");

const memory_files = [_][]const u8{ "MEMORY.md", "AGENT.md", "CLAUDE.md" };

pub fn BuildMemoryForAgent(allocator: std.mem.Allocator, cwd: []const u8) ![]const u8 {
    var result: std.ArrayList(u8) = .empty;
    defer result.deinit(allocator);

    // Ensure cwd is absolute - use "." if empty to get current directory
    const effective_cwd = if (cwd.len == 0) "." else cwd;
    const absolute_cwd = if (std.fs.path.isAbsolute(effective_cwd))
        try allocator.dupe(u8, effective_cwd)
    else
        try std.fs.cwd().realpathAlloc(allocator, effective_cwd);
    defer allocator.free(absolute_cwd);

    for (memory_files) |filename| {
        // Build the full path for this file
        const file_path = try std.fs.path.join(allocator, &[_][]const u8{ absolute_cwd, filename });
        defer allocator.free(file_path);

        // Try to open the file - if it doesn't exist, create it
        const file = std.fs.openFileAbsolute(file_path, .{
            .mode = .read_write,
        }) catch |err| {
            if (err == error.FileNotFound) {
                // Create the file with empty content
                const new_file = try std.fs.createFileAbsolute(file_path, .{});
                new_file.close();
                continue;
            }
            return err;
        };
        defer file.close();

        // Read the file contents
        const content = try file.readToEndAlloc(allocator, std.math.maxInt(usize));
        defer allocator.free(content);

        // Append content to result
        try result.appendSlice(allocator, content);

        // Add a newline separator between files if content doesn't end with one
        if (content.len > 0 and content[content.len - 1] != '\n') {
            try result.append(allocator, '\n');
        }
    }

    return try result.toOwnedSlice(allocator);
}



