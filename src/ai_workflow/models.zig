const sqlite = @import("tree1").sqlite;
const config = @import("tree1").config;

pub const ContextIPCTui = struct {
    db: *sqlite.SqliteBackend,
    llm_config: *const config.LlmConfig,
};
