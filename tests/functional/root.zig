//! Test root for the PRIBRIK functional suite.
//!
//! Every `*_test.zig` in this package is listed in `suites` below.
//! Zig only compiles `test` blocks the analysis REACHES from the root
//! source file, so a ported suite that is neither imported nor
//! referenced here simply does not run — silently. That is the whole
//! reason this list is explicit rather than globbed: it is the single
//! place where "this suite exists" is asserted, so a forgotten suite
//! fails loudly (empty `suites`) instead of vanishing.
//!
//! The Python suite relied on pytest's directory auto-discovery; Zig
//! has no equivalent, so when you port a file, add it here.

const std = @import("std");

pub const harness = @import("harness.zig");

// ─── Suites ───────────────────────────────────────────────────────────────
// One `const` per ported suite. A bare `@import` expression on its own
// does NOT pull the file's file-scope `test` blocks into the build;
// naming it as a `const` and referencing that const inside a `test`
// block is what makes the file's tests reachable.
const agent_tools_defaults_test = @import("agent_tools_defaults_test.zig");
const auth_test = @import("auth_test.zig");
const chat_right_sidebar_git_test = @import("chat_right_sidebar_git_test.zig");
const frontend_log_dedup_test = @import("frontend_log_dedup_test.zig");
const git_pr_status_branch_test = @import("git_pr_status_branch_test.zig");
const read_file_raw_content_test = @import("read_file_raw_content_test.zig");
const session_mark_touched_test = @import("session_mark_touched_test.zig");
const smoke_boot_test = @import("smoke_boot_test.zig");
const subagent_identity_test = @import("subagent_identity_test.zig");
const subagent_peek_test = @import("subagent_peek_test.zig");
const subagent_refresh_test = @import("subagent_refresh_test.zig");
const subagent_selected_profile_test = @import("subagent_selected_profile_test.zig");
const system_folder_gitignore_test = @import("system_folder_gitignore_test.zig");
const system_folder_path_validation_test = @import("system_folder_path_validation_test.zig");
const terminal_limits_test = @import("terminal_limits_test.zig");

pub const suites = .{
    agent_tools_defaults_test,
    auth_test,
    chat_right_sidebar_git_test,
    frontend_log_dedup_test,
    git_pr_status_branch_test,
    read_file_raw_content_test,
    session_mark_touched_test,
    smoke_boot_test,
    subagent_identity_test,
    subagent_peek_test,
    subagent_refresh_test,
    subagent_selected_profile_test,
    system_folder_gitignore_test,
    system_folder_path_validation_test,
    terminal_limits_test,
};

test {
    // Referencing each suite here is what pulls its `test` blocks in.
    inline for (suites) |suite| {
        _ = suite;
    }
    // Plus the harness module's own decls, so a helper added to
    // `harness.zig` is analyzed even before a suite uses it.
    std.testing.refAllDecls(harness);
}