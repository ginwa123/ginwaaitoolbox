const std = @import("std");
const common = @import("common.zig");

const SqliteBackend = common.SqliteBackend;
const addColumnIfMissing = common.addColumnIfMissing;
const dropColumnIfExists = common.dropColumnIfExists;
const renameColumnIfExists = common.renameColumnIfExists;
const helpers = @import("helpers");

pub const Migration079AddContentToAgentKnowledge = struct {
    pub const version: u32 = 79;
    pub const name = "add_content_to_agent_knowledge";

    pub fn up(db: *SqliteBackend, allocator: std.mem.Allocator) anyerror!void {
        try addColumnIfMissing(
            .{ .db = db },
            allocator,
            "agent_knowledge",
            "content",
            "content TEXT NOT NULL DEFAULT ''",
        );
    }
};
