//! Data model for the `session_queue_messages` entity table.
//!
//! Pending user messages queued behind a running session. While the
//! agent is processing a turn, the user can keep typing — each
//! queued message is INSERTed here and drained in FIFO order when
//! the current turn completes.
//!
//! Schema: Migration 007 (`create_session_queue_messages`) +
//! Migration 060 (`add_image_url_to_session_queue_messages`) +
//! Migration 068 (`make_session_queue_messages_message_nullable`).
//!
//! IMPORTANT: this table has NO PRIMARY KEY. The `(id, session_id)`
//! pair is logically unique but not enforced. INSERTs use the
//! generated `id` from `queue.zig` and rely on the FIFO read order
//! (`ORDER BY created_at ASC`).

const std = @import("std");

pub const EntityId = []u8;

id: EntityId,
session_id: []u8,
/// The queued message text. NULL when the queued item is an
/// image-only message (Migration 068 relaxed the NOT NULL
/// constraint for the `image_url`-only case).
message: ?[]u8 = null,
/// Data URL of an attached image (Migration 060).
image_url: ?[]u8 = null,
created_at: []u8,

const Self = @This();

pub const InitArgs = struct {
    id: []const u8,
    session_id: []const u8,
    message: ?[]const u8 = null,
    image_url: ?[]const u8 = null,
    created_at: []const u8 = "",
};

pub fn init(allocator: std.mem.Allocator, args: InitArgs) !Self {
    return .{
        .id = try allocator.dupe(u8, args.id),
        .session_id = try allocator.dupe(u8, args.session_id),
        .message = if (args.message) |m| try allocator.dupe(u8, m) else null,
        .image_url = if (args.image_url) |iu|
            try allocator.dupe(u8, iu)
        else
            null,
        .created_at = try allocator.dupe(u8, args.created_at),
    };
}

pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
    allocator.free(self.id);
    allocator.free(self.session_id);
    if (self.message) |m| allocator.free(m);
    if (self.image_url) |iu| allocator.free(iu);
    allocator.free(self.created_at);
}

pub fn clone(self: *const Self, allocator: std.mem.Allocator) !Self {
    return .init(allocator, .{
        .id = self.id,
        .session_id = self.session_id,
        .message = if (self.message) |m| m else null,
        .image_url = if (self.image_url) |iu| iu else null,
        .created_at = self.created_at,
    });
}