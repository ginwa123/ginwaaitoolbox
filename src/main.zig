const std = @import("std");
const tree1 = @import("tree1");
const agentMod = @import("modules/agent/agent.zig");
const ipc = @import("modules/ipc/ipc.zig");

test {
    _ = @import("modules/databases/sqlite/sqlite_test.zig");
    _ = @import("modules/agent/tools/bash_test.zig");
    _ = @import("modules/agent/agent_test.zig");
    _ = @import("modules/ipc/ipc_test.zig");
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const allocator = gpa.allocator();

    var server = ipc.IpcServer.init(allocator);

    server.messageIncoming(struct {
        fn handler(data: []const u8) void {
            std.debug.print("Received: {s}\n", .{data});
        }
    }.handler);

    try server.run();
}
