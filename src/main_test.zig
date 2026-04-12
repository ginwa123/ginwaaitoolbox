const std = @import("std");
const root = @import("root.zig");

test "root module exports expected symbols" {
    // Test that key types are exported from root module
    // These are compile-time checks - if they compile, the exports exist
    
    // Agent types
    try std.testing.expect(@hasDecl(root, "agent"));
    
    // SQLite
    try std.testing.expect(@hasDecl(root, "sqlite"));
    
    // HTTP client
    try std.testing.expect(@hasDecl(root, "http_client"));
    
    // Config
    try std.testing.expect(@hasDecl(root, "config"));
    
    // Logger
    try std.testing.expect(@hasDecl(root, "logger"));
    
    // Session
    try std.testing.expect(@hasDecl(root, "session"));
    
    // Tools
    try std.testing.expect(@hasDecl(root, "bash_tool"));
    try std.testing.expect(@hasDecl(root, "read_file"));
    try std.testing.expect(@hasDecl(root, "write_file"));
    try std.testing.expect(@hasDecl(root, "text_replace_tool"));
    
    // Tool models
    try std.testing.expect(@hasDecl(root, "tool_models"));
    
    // Prompts
    try std.testing.expect(@hasDecl(root, "prompt"));
    
    // TUI helpers
    try std.testing.expect(@hasDecl(root, "tui_check_session_exists"));
    try std.testing.expect(@hasDecl(root, "kerjabot_get_session"));
    try std.testing.expect(@hasDecl(root, "kerjabot_create_session"));
    try std.testing.expect(@hasDecl(root, "kerjabot_get_list_session"));
    
    // Skills
    try std.testing.expect(@hasDecl(root, "skills"));
}
