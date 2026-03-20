const std = @import("std");

test "workflow module imports" {
    // Test that the module can be imported without errors
    const tui_workflow = @import("workflow.zig");
    _ = tui_workflow;
    try std.testing.expect(true);
}
