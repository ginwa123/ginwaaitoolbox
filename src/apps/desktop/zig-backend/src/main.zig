const std = @import("std");
const server = @import("server.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Default port
    var port: u16 = 3000;

    // Get command line arguments
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    // Parse arguments (skip program name at index 0)
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--port") or std.mem.eql(u8, arg, "-p")) {
            if (i + 1 < args.len) {
                i += 1;
                port = std.fmt.parseInt(u16, args[i], 10) catch {
                    std.log.err("Invalid port number: {s}", .{args[i]});
                    return error.InvalidPort;
                };
            } else {
                std.log.err("Missing port number after --port", .{});
                return error.MissingPort;
            }
        }
    }

    std.log.info("Starting desktop backend server on port {d}", .{port});

    try server.run(allocator, port);
}