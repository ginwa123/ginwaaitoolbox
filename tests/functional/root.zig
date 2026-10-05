//! Test root for the PRIBRIK functional suite.
//!
//! Every `*_test.zig` in this package is listed in `suites` below.
//! Zig only compiles `test` blocks the analysis REACHES from the root
//! source file, so a ported suite that is neither imported nor
//! referenced here simply does not run - silently. That is the whole
//! reason this list is explicit rather than globbed: it is the single
//! place where "this suite exists" is asserted, so a forgotten suite
//! fails loudly (an empty `suites`) instead of vanishing.
//!
//! The Python suite relied on pytest's directory auto-discovery; Zig
//! has no equivalent. When you port a file, add it here.
//
//! REGENERATING: this file is fully derived from the `*_test.zig` files
//! present in this directory. If a ported suite is missing from `suites`,
//! it is not running - that is the failure mode this list exists to
//! prevent, so check here first when a port "passes" but its tests never
//! appear in the count.

const std = @import("std");

pub const harness = @import("harness.zig");

// -- Suites ----------------------------------------------------------------
// One `const` per ported suite. A bare `@import` expression on its own
// does NOT pull the file's file-scope `test` blocks into the build;
// naming it as a `const` and referencing that const inside a `test`
// block is what makes the file's tests reachable.
const agent_tools_defaults_test = @import("agent_tools_defaults_test.zig");
const auth_test = @import("auth_test.zig");
const background_process_sse_test = @import("background_process_sse_test.zig");
const chat_right_sidebar_git_test = @import("chat_right_sidebar_git_test.zig");
const cross_project_cwd_prompt_test = @import("cross_project_cwd_prompt_test.zig");
const frontend_log_dedup_test = @import("frontend_log_dedup_test.zig");
const git_file_diffs_test = @import("git_file_diffs_test.zig");
const git_file_relative_path_crash_test = @import("git_file_relative_path_crash_test.zig");
const git_pr_status_branch_test = @import("git_pr_status_branch_test.zig");
const graceful_shutdown_test = @import("graceful_shutdown_test.zig");
const kanban_task_long_description_test = @import("kanban_task_long_description_test.zig");
const llm_stream_get_test = @import("llm_stream_get_test.zig");
const new_chat_session_not_found_test = @import("new_chat_session_not_found_test.zig");
const progressive_tool_search_regex_test = @import("progressive_tool_search_regex_test.zig");
const read_file_raw_content_test = @import("read_file_raw_content_test.zig");
const server_port_bind_test = @import("server_port_bind_test.zig");
const session_mark_touched_test = @import("session_mark_touched_test.zig");
const sidebar_git_branch_test = @import("sidebar_git_branch_test.zig");
const smoke_boot_test = @import("smoke_boot_test.zig");
const spawn_sub_agent_tools_required_test = @import("spawn_sub_agent_tools_required_test.zig");
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
    background_process_sse_test,
    chat_right_sidebar_git_test,
    cross_project_cwd_prompt_test,
    frontend_log_dedup_test,
    git_file_diffs_test,
    git_file_relative_path_crash_test,
    git_pr_status_branch_test,
    graceful_shutdown_test,
    kanban_task_long_description_test,
    llm_stream_get_test,
    new_chat_session_not_found_test,
    progressive_tool_search_regex_test,
    read_file_raw_content_test,
    server_port_bind_test,
    session_mark_touched_test,
    sidebar_git_branch_test,
    smoke_boot_test,
    spawn_sub_agent_tools_required_test,
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
    // `harness.zig` is analyzed even before a suite uses it. (Note this
    // forces DECLARATION analysis only - harness.zig carries its own
    // `comptime` block that forces BODY analysis of every public fn,
    // because a function body is otherwise never type-checked until
    // something calls it.)
    std.testing.refAllDecls(harness);
}
