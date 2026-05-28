test {
    // Image content tests
    _ = @import("image_content_test.zig");
    
    // Tool tests
    _ = @import("tools/change_agent_test.zig");
    _ = @import("tools/diff_test.zig");
    _ = @import("tools/text_replace_test.zig");
    _ = @import("tools/list_skills_test.zig");
    _ = @import("tools/glob_test.zig");
    _ = @import("tools/add_skill_test.zig");
    _ = @import("tools/edit_skill_test.zig");
    _ = @import("tools/remove_skill_test.zig");
    _ = @import("tools/view_skill_test.zig");
    _ = @import("tools/cloak_browser_test.zig");
}
