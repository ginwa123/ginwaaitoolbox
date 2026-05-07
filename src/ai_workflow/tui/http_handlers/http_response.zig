const std = @import("std");

pub fn makeErrorResponse(allocator: std.mem.Allocator, msg: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{{\"error\":\"{s}\"}}", .{msg});
}

pub fn makeWorkspaceResponse(allocator: std.mem.Allocator, id: []const u8, name: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{{\"id\":\"{s}\",\"name\":\"{s}\"}}", .{ id, name });
}