const std = @import("std");
const root_mod = @import("nalarcore");
const http_server = root_mod.http_server;
const activity_registry = root_mod.session.activity_registry;

const httpz = http_server.httpz;

/// List all workers
/// Query params:
///   - limit: max number of workers to return (u32, default: 50)
///   - status: filter by status (running, idle, stopped, all - default: all)
/// Returns JSON array of worker info
pub fn worker_list_handler(_: *http_server.HttpServer.ServerHandler, req: *httpz.Request, res: *httpz.Response) anyerror!void {
    const alloc = req.arena;
    res.content_type = .JSON;

    const query = try req.query();
    const limit_str = query.get("limit") orelse "50";
    const status_filter = query.get("status") orelse "all";

    const limit = std.fmt.parseInt(u32, limit_str, 10) catch 50;

    if (activity_registry.get_global_registry()) |registry| {
        var worker_list = std.ArrayList(u8).empty;
        defer worker_list.deinit(alloc);
        const writer = worker_list.writer(alloc);

        try writer.writeAll("[");
        var count: u32 = 0;
        var iter = registry.sessions.iterator();

        // Determine filter type
        const filter_running = std.mem.eql(u8, status_filter, "running");
        const filter_idle = std.mem.eql(u8, status_filter, "idle");
        const filter_stopped = std.mem.eql(u8, status_filter, "stopped");

        while (iter.next()) |entry| {
            if (count >= limit) break;

            const sid = entry.key_ptr.*;
            const is_stopped = registry.is_stopped(sid);
            const is_running = registry.is_running(sid);

            // Apply status filter
            const matches_filter = if (filter_running)
                is_running
            else if (filter_idle)
                !is_stopped and !is_running
            else if (filter_stopped)
                is_stopped
            else
                true; // "all" or unknown

            if (!matches_filter) continue;

            const status = if (is_stopped) "stopped" else if (is_running) "running" else "idle";

            var queue_count: u32 = 0;
            if (registry.message_queues.get(sid)) |queue| {
                queue_count = @intCast(queue.items.len);
            }

            if (count > 0) {
                try writer.writeAll(",");
            }

            try writer.print(
                "{{\"id\":\"{s}\",\"status\":\"{s}\",\"is_running\":{},\"queue_count\":{}}}",
                .{ sid, status, is_running, queue_count }
            );
            count += 1;
        }

        try writer.writeAll("]");

        res.status = 200;
        res.body = try std.fmt.allocPrint(alloc,
            "{{\"workers\":{s},\"count\":{}}}",
            .{ worker_list.items, count }
        );
        return;
    }

    res.status = 500;
    res.body = "{\"error\":\"Activity registry not available\"}";
}
