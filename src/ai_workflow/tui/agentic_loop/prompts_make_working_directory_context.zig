const std = @import("std");

const memory_files = [_][]const u8{ "NALAR.md", "CLAUDE.md", "AGENTS.md" };
pub fn makeWorkingDirectoryContext(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
) ![]const u8 {
    var result: std.ArrayList(u8) = .empty;
    defer result.deinit(allocator);

    const effective_cwd = if (cwd.len == 0) "." else cwd;
    const absolute_cwd = if (std.fs.path.isAbsolute(effective_cwd))
        try allocator.dupe(u8, effective_cwd)
    else
        try std.Io.Dir.cwd().realPathFileAlloc(io, effective_cwd, allocator);
    defer allocator.free(absolute_cwd);

    for (memory_files) |filename| {
        const file_path = try std.fs.path.join(allocator, &[_][]const u8{ absolute_cwd, filename });
        defer allocator.free(file_path);

        const file = std.Io.Dir.openFileAbsolute(io, file_path, .{
            .mode = .read_write,
        }) catch |err| {
            if (err == error.FileNotFound) {
                const new_file = try std.Io.Dir.createFileAbsolute(io, file_path, .{});
                std.Io.File.close(new_file, io);
                continue;
            }
            return err;
        };
        defer std.Io.File.close(file, io);

        const content = try std.Io.Dir.cwd().readFileAlloc(io, file_path, allocator, std.Io.Limit.limited(std.math.maxInt(usize)));
        defer allocator.free(content);

        try result.appendSlice(allocator, content);

        if (content.len > 0 and content[content.len - 1] != '\n') {
            try result.append(allocator, '\n');
        }
    }

    return try result.toOwnedSlice(allocator);
}
