//! Static-contract tests for the `retryDelayMs` helper in `workflow.zig`.
//!
//! Why static-contract instead of behavioral:
//! 1. workflow.zig is 1162 lines and `runAgenticMultiStepnew` requires a
//!    live singleton (LlmConfig, db, event_bus, active_loops). Standing
//!    up that fixture in a unit test is too much boilerplate.
//! 2. The behavioral contract is "sleep for ~delay_ms, exit early on
//!    cancel". Testing that with real time introduces flakiness.
//! 3. The CRITICAL invariant (use nanosleep, NOT std.Io.sleep) is
//!    source-greppable. Behavioral tests can't see this distinction.
//!
//! The tests below read workflow.zig and grep for the contract strings.
//! If the helper is missing or wrong, they fail with a clear diagnostic.

const std = @import("std");
const testing = std.testing;

/// Path to the source file under test.
const WORKFLOW_SOURCE_PATH = "src/ai_workflow/tui/workflow.zig";

test "workflow.zig declares retryDelayMs helper" {
    const source = std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        WORKFLOW_SOURCE_PATH,
        std.testing.allocator,
        .limited(4 * 1024 * 1024),
    ) catch |err| {
        std.debug.print("!! cannot read {s}: {{}} !!\n", .{WORKFLOW_SOURCE_PATH});
        return err;
    };
    defer std.testing.allocator.free(source);

    if (std.mem.indexOf(u8, source, "fn retryDelayMs(") == null) {
        std.debug.print(
            "!! workflow.zig does not declare retryDelayMs helper !!\n",
            .{},
        );
        return error.RetryDelayMsMissing;
    }
}

test "workflow.zig retryDelayMs uses raw libc nanosleep, not std.Io.sleep" {
    const source = std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        WORKFLOW_SOURCE_PATH,
        std.testing.allocator,
        .limited(4 * 1024 * 1024),
    ) catch |err| {
        std.debug.print("!! cannot read {s}: {{}} !!\n", .{WORKFLOW_SOURCE_PATH});
        return err;
    };
    defer std.testing.allocator.free(source);

    // Find the retryDelayMs function body. Crude heuristic — find the
    // function declaration, then scan forward to the next top-level
    // declaration (`\nfn ` or `\npub const `) at column 0. Works for
    // this codebase because the helper sits between two top-level
    // functions.
    const fn_start = std.mem.indexOf(u8, source, "fn retryDelayMs(") orelse {
        std.debug.print(
            "!! retryDelayMs function not found in workflow.zig !!\n",
            .{},
        );
        return error.RetryDelayMsMissing;
    };
    const fn_end = std.mem.indexOfPos(u8, source, fn_start + 1, "\nfn ")
        orelse std.mem.indexOfPos(u8, source, fn_start + 1, "\npub const ")
        orelse source.len;
    const body = source[fn_start..fn_end];

    // CRITICAL: must NOT use std.Io.sleep — deadlocks the Io.Group.
    if (std.mem.indexOf(u8, body, "std.Io.sleep") != null) {
        std.debug.print(
            "!! retryDelayMs uses std.Io.sleep — this deadlocks the Io.Group !!\n" ++
                "   (see src/modules/agent/tools/bash.zig:4-17 for the deadlock pattern). !!\n",
            .{},
        );
        return error.RetryDelayMsUsesIoSleep;
    }

    // The function body delegates to a Zig wrapper (e.g. `workflowNanosleep`).
    // The wrapper itself is the `extern "c" fn` declared at module scope —
    // often ABOVE the function definition, so we have to grep the full source
    // for the libc symbol `nanosleep` to verify the extern declaration exists.
    // We accept either `nanosleep` (raw libc symbol) or a wrapper name like
    // `workflowNanosleep` (case-insensitive contains "nanosleep").
    const has_extern_nanosleep = blk: {
        // Walk every `extern "c" fn` declaration in the file and check
        // whether its declaration line (one statement, ends at first `(`)
        // contains `nanosleep` (case-insensitive).
        var idx: usize = 0;
        var found = false;
        while (std.mem.indexOfPos(u8, source, idx, "extern \"c\" fn")) |pos| {
            const sig_end = std.mem.indexOfPos(u8, source, pos + 12, "(") orelse break;
            const decl = source[pos..sig_end];
            // Case-insensitive contains check.
            if (std.ascii.indexOfIgnoreCase(decl, "nanosleep") != null) {
                found = true;
                break;
            }
            idx = sig_end + 1;
        }
        break :blk found;
    };
    if (!has_extern_nanosleep) {
        std.debug.print(
            "!! retryDelayMs does not declare an 'extern \"c\" fn ... nanosleep(...) at module scope !!\n" ++
                "   The implementation must call raw libc nanosleep via the bash.zig:4-17 pattern. !!\n",
            .{},
        );
        return error.RetryDelayMsMissingNanosleep;
    }
}

// ─── Task 3.2: callDynamicAgentNew catch must call retryDelayMs ───
test "workflow.zig calls retryDelayMs in the callDynamicAgentNew catch" {
    const source = std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        WORKFLOW_SOURCE_PATH,
        std.testing.allocator,
        .limited(4 * 1024 * 1024),
    ) catch |err| {
        std.debug.print("!! cannot read {s}: {{}} !!\n", .{WORKFLOW_SOURCE_PATH});
        return err;
    };
    defer std.testing.allocator.free(source);

    // The catch block (after the `last_retry_source = "callDynamicAgentNew";` line)
    // must call retryDelayMs and read config.retry_delay_ms before `continue`.
    const marker = std.mem.indexOf(u8, source, "last_retry_source = \"callDynamicAgentNew\";") orelse {
        std.debug.print("!! callDynamicAgentNew catch block not found in workflow.zig !!\n", .{});
        return error.RetryCatchBlockNotFound;
    };
    // Find the next `continue;` after the catch marker.
    const continue_pos_raw = std.mem.indexOfPos(u8, source, marker + 1, "continue;") orelse {
        std.debug.print("!! no `continue;` after callDynamicAgentNew catch marker !!\n", .{});
        return error.RetryContinueMissing;
    };
    const continue_pos: usize = continue_pos_raw;
    const between = source[marker..continue_pos];

    if (std.mem.indexOf(u8, between, "retryDelayMs(") == null) {
        std.debug.print(
            "!! callDynamicAgentNew catch does not call retryDelayMs before continue !!\n", .{});
        return error.RetryDelayNotCalled;
    }
    if (std.mem.indexOf(u8, between, "config.retry_delay_ms") == null) {
        std.debug.print(
            "!! callDynamicAgentNew catch does not read config.retry_delay_ms !!\n", .{});
        return error.RetryDelayConfigNotRead;
    }
}

// ─── Task 3.3: finish_reason else branch must call retryDelayMs ───
test "workflow.zig calls retryDelayMs in the finish_reason else branch" {
    const source = std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        WORKFLOW_SOURCE_PATH,
        std.testing.allocator,
        .limited(4 * 1024 * 1024),
    ) catch |err| {
        std.debug.print("!! cannot read {s}: {{}} !!\n", .{WORKFLOW_SOURCE_PATH});
        return err;
    };
    defer std.testing.allocator.free(source);

    // The else branch handles finish_reason values other than
    // .stop / .length / .tool_calls. Find the else marker (after
    // `} else if (finish_reason == .tool_calls) {`).
    const tool_calls_marker = std.mem.indexOf(u8, source, "} else if (finish_reason == .tool_calls) {") orelse {
        std.debug.print(
            "!! tool_calls finish_reason branch not found in workflow.zig !!\n", .{});
        return error.ToolCallsBranchNotFound;
    };
    // The else branch is the next `} else {` (with leading brace+space) after tool_calls.
    const else_marker = std.mem.indexOfPos(u8, source, tool_calls_marker + 1, "} else {") orelse {
        std.debug.print("!! finish_reason else branch not found in workflow.zig !!\n", .{});
        return error.ElseBranchNotFound;
    };
    // Look at a 500-byte window from the else marker — enough to cover
    // the retry_count += 1, retryDelayMs call, and break statements.
    const window_end: usize = @min(else_marker + 500, source.len);
    const else_block = source[else_marker..window_end];

    if (std.mem.indexOf(u8, else_block, "retryDelayMs(") == null) {
        std.debug.print(
            "!! finish_reason else branch does not call retryDelayMs !!\n", .{});
        return error.RetryDelayNotCalledInElse;
    }
    if (std.mem.indexOf(u8, else_block, "retry_count += 1;") == null) {
        std.debug.print(
            "!! finish_reason else branch does not increment retry_count !!\n", .{});
        return error.RetryCountNotIncrementedInElse;
    }
}