

const sqlite = @import("../modules/databases/sqlite/sqlite.zig");

pub const ContextIPCTui = struct {
    db: *sqlite.SqliteBackend
};

