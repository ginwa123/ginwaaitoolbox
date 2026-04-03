const std = @import("std");
const root_mod = @import("nalarcore");
const http_server = root_mod.http_server;
const activity_registry = root_mod.session.activity_registry;

const httpz = http_server.httpz;

/// Delete a specific message from the session's message queue
/// Path param: session_id
/// Query param: message (the exact message string to delete)
/// Returns JSON with deletion status
pub fn sessionQueueDeleteHandler(
    _: *http_server.HttpServer.ServerHandler,
    req: *httpz.Request,
    res: *httpz.Response,
) anyerror!void {
    res.content_type = .JSON;

    const session_id = req.param("session_id") orelse {
        res.status = 400;
        res.body = "{\"error\":\"Missing session_id\"}";
        return;
    };

    // Get message from query parameter
    const query = req.query() catch {
        res.status = 400;
        res.body = "{\"error\":\"Failed to parse query parameters\"}";
        return;
    };
    const message = query.get("message") orelse {
        res.status = 400;
        res.body = "{\"error\":\"Missing message query parameter\"}";
        return;
    };

    // Call the activity registry method
    if (activity_registry.get_global_registry()) |registry| {
        registry.delete_queue_messages(session_id, message);
        res.status = 200;
        res.body = try std.fmt.allocPrint(
            req.arena,
            "{{\"status\":\"deleted\",\"session_id\":\"{s}\",\"message\":\"{s}\"}}",
            .{ session_id, message },
        );
        return;
    }

    res.status = 500;
    res.body = "{\"error\":\"Activity registry not available\"}";
}
