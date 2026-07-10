

pub const SseEvent = struct {
    session_id: []const u8,
    data: []const u8,
    event_type: ?[]const u8 = null,
};

