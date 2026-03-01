
const sqlite = @import("tree1").sqlite;

pub const ContextIPCTui = struct {
    db: *sqlite.SqliteBackend
};
