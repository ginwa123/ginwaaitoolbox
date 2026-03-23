const std = @import("std");
const httpz_import = @import("httpz");

pub const httpz = httpz_import;

/// Handler function signature - all HTTP handlers use this
pub const HandlerFn = *const fn (req: *httpz.Request, res: *httpz.Response) anyerror!void;

/// Context type passed to handlers
pub const HandlerContext = *anyopaque;

/// Panic event data
pub const PanicEvent = struct {
    message: []const u8,
};

/// Panic handler callback type
pub const PanicHandlerFn = *const fn (event: PanicEvent) void;
