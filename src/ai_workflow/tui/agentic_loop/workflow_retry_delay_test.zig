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
const WORKFLOW_SOURCE_PATH = "src/ai_workflow/tui/agentic_loop/workflow.zig";

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
    // Look at a 1500-byte window from the else marker — enough to cover
    // retry_count += 1, saveRetryAttemptMessage call, retryDelayMs call,
    // and break statements (the saveRetryAttemptMessage call alone is
    // ~600 chars due to its many positional args).
    const window_end: usize = @min(else_marker + 1500, source.len);
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
    if (std.mem.indexOf(u8, else_block, "saveRetryAttemptMessage(") == null) {
        std.debug.print(
            "!! finish_reason else branch does not save retry diagnostic to chat !!\n", .{});
        return error.RetryDiagnosticNotSavedInElse;
    }
}

// ─── Per-retry diagnostic message (saved to chat history) ───
//
// Verifies the workflow saves a per-retry user-role message into
// `llm_history` so the user sees each retry attempt live in their
// chat AND the AI agent has the full retry progression in context
// (instead of only learning about retries after the TooManyRetries
// bail). Decision: `is_input: true` (renders as user-side chat
// entry) + `is_feed_to_llm: true` (AI sees it on next turn).
test "workflow.zig declares saveRetryAttemptMessage helper" {
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

    if (std.mem.indexOf(u8, source, "fn saveRetryAttemptMessage(") == null) {
        std.debug.print(
            "!! workflow.zig does not declare saveRetryAttemptMessage helper !!\n", .{});
        return error.SaveRetryAttemptMessageMissing;
    }
}

test "workflow.zig per-retry message is feed_to_llm (so AI sees full retry history)" {
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

    // The saveRetryAttemptMessage helper must call insertLLMHistories
    // with `is_feed_to_llm: true` so the AI agent has the full retry
    // history in context on its next turn.
    const fn_start = std.mem.indexOf(u8, source, "fn saveRetryAttemptMessage(") orelse
        return error.SaveRetryAttemptMessageMissing;
    const fn_end = std.mem.indexOfPos(u8, source, fn_start + 1, "\nfn ") orelse source.len;
    const body = source[fn_start..fn_end];

    if (std.mem.indexOf(u8, body, "is_feed_to_llm = true") == null) {
        std.debug.print(
            "!! saveRetryAttemptMessage uses is_feed_to_llm: false — AI won't see retry history !!\n", .{});
        return error.RetryMessageNotFedToLlm;
    }
    if (std.mem.indexOf(u8, body, "is_input = true") == null) {
        std.debug.print(
            "!! saveRetryAttemptMessage is_input: false — message won't render as user-side entry !!\n", .{});
        return error.RetryMessageNotUserInput;
    }
    if (std.mem.indexOf(u8, body, "agent.Role.user.to_str()") == null) {
        std.debug.print(
            "!! saveRetryAttemptMessage role != user — chat list won't show it !!\n", .{});
        return error.RetryMessageWrongRole;
    }
    if (std.mem.indexOf(u8, body, "[Retry {d}/{d}]") == null) {
        std.debug.print(
            "!! saveRetryAttemptMessage format missing [Retry X/Y] prefix !!\n", .{});
        return error.RetryMessageFormatWrong;
    }
}

test "workflow.zig calls saveRetryAttemptMessage in callDynamicAgentNew catch" {
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

    // The catch block must call saveRetryAttemptMessage between the
    // retry_count += 1 line and the retryDelayMs call.
    const marker = std.mem.indexOf(u8, source, "last_retry_source = \"callDynamicAgentNew\";") orelse
        return error.RetryCatchBlockNotFound;
    const continue_pos = std.mem.indexOfPos(u8, source, marker + 1, "continue;") orelse
        return error.RetryContinueMissing;
    const between = source[marker..continue_pos];
    if (std.mem.indexOf(u8, between, "saveRetryAttemptMessage(") == null) {
        std.debug.print(
            "!! callDynamicAgentNew catch does not save retry diagnostic to chat !!\n", .{});
        return error.RetryDiagnosticNotSavedInCatch;
    }
}

test "workflow.zig calls saveRetryAttemptMessage in finish_reason else branch" {
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

    // Anchor on the tool_calls branch (preceding the else we care about).
    const tool_calls_marker = std.mem.indexOf(u8, source, "} else if (finish_reason == .tool_calls) {") orelse {
        std.debug.print(
            "!! tool_calls finish_reason branch not found in workflow.zig !!\n", .{});
        return error.ToolCallsBranchNotFound;
    };
    const else_marker = std.mem.indexOfPos(u8, source, tool_calls_marker + 1, "} else {") orelse {
        std.debug.print("!! finish_reason else branch not found in workflow.zig !!\n", .{});
        return error.ElseBranchNotFound;
    };
    // Look at a 1500-byte window to capture retry_count + saveRetryAttemptMessage + delay block.
    const window_end: usize = @min(else_marker + 1500, source.len);
    const window = source[else_marker..window_end];
    if (std.mem.indexOf(u8, window, "saveRetryAttemptMessage(") == null) {
        std.debug.print(
            "!! finish_reason else branch does not save retry diagnostic to chat !!\n", .{});
        return error.RetryDiagnosticNotSavedInElse;
    }
}
// =====================================================================
// Migration 063 — sessions.is_auto_retry_until_stop feature (Chunk 2
// Task 2.1). Static-contract tests verifying that workflow.zig:
//   1. Reads the flag at runAgenticMultiStepnew entry.
//   2. Replaces the hard TooManyRetries bail with a soft bail +
//      `continue` when the flag is on (preserving existing behavior
//      when the flag is off).
//   3. Writes last_finish_reason via updateSessionLastFinishReason
//      after each successful LLM call.
// All three are critical invariants that the lazy-analysis test target
// doesn't reach; behavioral coverage is via install-target compile +
// manual overnight test (per the plan's Task 2.2 decision).
// =====================================================================

/// Helper: locate the body of `runAgenticMultiStepnew` in workflow.zig
/// (which spans from the function declaration to the next top-level
/// `fn ` or `pub const ` at column 0). Returns the source slice.
fn runAgenticMultiStepnewBody(source: []const u8) []const u8 {
    const fn_start = std.mem.indexOf(u8, source, "pub fn runAgenticMultiStepnew(") orelse
        return source[0..0];
    const fn_end_pos = std.mem.indexOfPos(u8, source, fn_start + 1, "\nfn ") orelse
        std.mem.indexOfPos(u8, source, fn_start + 1, "\npub const ") orelse
        source.len;
    return source[fn_start..fn_end_pos];
}

test "workflow.zig reads is_auto_retry_until_stop at runAgenticMultiStepnew entry" {
    const source = std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        WORKFLOW_SOURCE_PATH,
        std.testing.allocator,
        .limited(4 * 1024 * 1024),
    ) catch |err| return err;
    defer std.testing.allocator.free(source);

    const body = runAgenticMultiStepnewBody(source);
    if (body.len == 0) {
        std.debug.print("!! runAgenticMultiStepnew not found in workflow.zig !!\n", .{});
        return error.RunAgenticMultiStepnewMissing;
    }
    if (std.mem.indexOf(u8, body, "is_auto_retry_until_stop") == null) {
        std.debug.print(
            "!! workflow.zig runAgenticMultiStepnew does NOT read is_auto_retry_until_stop !!\n" ++
                "   (the unattended-mode flag must be read at entry via SELECT, " ++
                "before the retry while-loop). !!\n",
            .{},
        );
        return error.AutoRetryFlagReadMissing;
    }
}

test "workflow.zig soft-bails past retry_count > 10 when is_auto_retry_until_stop = 1" {
    const source = std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        WORKFLOW_SOURCE_PATH,
        std.testing.allocator,
        .limited(4 * 1024 * 1024),
    ) catch |err| return err;
    defer std.testing.allocator.free(source);

    const retry_marker = std.mem.indexOf(u8, source, "if (retry_count > 10)") orelse {
        std.debug.print("!! retry_count > 10 threshold (as `if`) removed from workflow.zig !!\n", .{});
        return error.RetryCountThresholdMissing;
    };

    // Walk forward 1500 chars (covers the soft-bail branch + the continue).
    const look_end = @min(retry_marker + 1500, source.len);
    const window = source[retry_marker..look_end];

    if (std.mem.indexOf(u8, window, "if (is_auto_retry_until_stop)") == null) {
        std.debug.print(
            "!! workflow.zig retry_count > 10 block does NOT branch on is_auto_retry_until_stop !!\n" ++
                "   (attended mode off -> existing hard bail preserved; " ++
                "attended mode on -> soft bail with continue). !!\n",
            .{},
        );
        return error.AutoRetrySoftBailMissing;
    }
}

test "workflow.zig writes last_finish_reason via updateSessionLastFinishReason" {
    const source = std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        WORKFLOW_SOURCE_PATH,
        std.testing.allocator,
        .limited(4 * 1024 * 1024),
    ) catch |err| return err;
    defer std.testing.allocator.free(source);

    const body = runAgenticMultiStepnewBody(source);
    if (body.len == 0) return error.RunAgenticMultiStepnewMissing;

    if (std.mem.indexOf(u8, body, "updateSessionLastFinishReason") == null) {
        std.debug.print(
            "!! workflow.zig runAgenticMultiStepnew does NOT call updateSessionLastFinishReason !!\n" ++
                "   (the workflow must persist finish_reason after each LLM call " ++
                "so a server restart picks up where the last turn left off). !!\n",
            .{},
        );
        return error.LastFinishReasonWriteMissing;
    }
}
