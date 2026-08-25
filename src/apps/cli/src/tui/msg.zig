//! Messages: the events that flow through the event loop into
//! `Model.update`.

const std = @import("std");
const key_mod = @import("key.zig");

pub const Msg = union(enum) {
    /// A key was pressed.
    key: key_mod.Key,
    /// Terminal was resized.
    resize: Size,
    /// Periodic tick (drives spinner + polling). `millis` is the tick
    /// interval that produced it.
    tick: u64,
    /// Streaming chunk arrived from the backend.
    stream_chunk: []const u8,
    /// The streaming transfer finished (success or error).
    stream_done: ?[]const u8, // error message, if any
    /// Application quit requested.
    quit,
};

pub const Size = struct { width: u16, height: u16 };

/// A deferred side-effect returned by `Model.update`. The Program
/// executes it after update returns and feeds any resulting Msg back
/// into the loop. Mirrors Bubble Tea's `Cmd`.
pub const Cmd = union(enum) {
    none,
    /// Send a chat message to the backend.
    send_msg: []const u8,
    /// Poll GET /api/llm/session/:id/messages once.
    poll_messages,
    /// Schedule the next TickMsg after `millis`.
    tick_after: u64,
};
