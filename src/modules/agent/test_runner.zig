test {
    // Tool tests
    _ = @import("tools/bash_test.zig");
    _ = @import("tools/change_agent_test.zig");
    _ = @import("tools/get_skill_test.zig");
    _ = @import("tools/glob_test.zig");
    _ = @import("tools/list_agents_test.zig");
    _ = @import("tools/read_file_test.zig");
    _ = @import("tools/search_test.zig");
    _ = @import("tools/text_replace_test.zig");
    _ = @import("tools/text_replace_batch_test.zig");
    _ = @import("tools/write_file_test.zig");
    _ = @import("tools/spawn_sub_agent_test.zig");
    _ = @import("tools/skills_test.zig");
    _ = @import("tools/agents_test.zig");
    _ = @import("tools/agents_integration_test.zig");
    // Web search tests
    _ = @import("tools/web_search_help_test.zig");
    _ = @import("tools/web_search_test.zig");
    // LSP tests
    _ = @import("tools/lsp_definition_test.zig");
    _ = @import("tools/lsp_document_symbol_test.zig");
    _ = @import("tools/lsp_hover_test.zig");
    _ = @import("tools/lsp_references_test.zig");
    _ = @import("tools/lsp_workspace_symbol_test.zig");
}
