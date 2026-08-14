const std = @import("std");
const database = @import("database");
const sqlite = database.sqlite;


pub fn handle(_: ?*anyopaque, now_unix: i64) void {
    std.debug.print("[cronjob] heartbeat fired at now={d}\n", .{now_unix});
}




