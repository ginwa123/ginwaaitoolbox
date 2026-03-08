const std = @import("std");


pub fn run(allocator: std.mem.Allocator, cwd: []const u8) ![]const u8 {
    var memoryMd: std.ArrayList(u8) = .empty;
    defer memoryMd.deinit(allocator);

    // get current cwd and get the MEMORY.MD file if not exist create if found just return the content
    const memory_path = try std.fs.path.join(allocator, &[_][]const u8{ cwd, "MEMORY.MD" });
    defer allocator.free(memory_path);

    // Try to open the file - if it doesn't exist, create it
    const file = std.fs.openFileAbsolute(memory_path, .{
        .mode = .read_write,
    }) catch |err| {
        if (err == error.FileNotFound) {
            // Create the file with empty content
            const new_file = try std.fs.createFileAbsolute(memory_path, .{});
            defer new_file.close();
            return try memoryMd.toOwnedSlice(allocator);
        }
        return err;
    };
    defer file.close();

    // Read the file contents
    const content = try file.readToEndAlloc(allocator, std.math.maxInt(usize));
    return content;
}



test {
    _ = @import("build_memory_for_agent_test.zig");
}
