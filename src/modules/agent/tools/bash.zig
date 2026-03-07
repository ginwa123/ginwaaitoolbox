const std = @import("std");
const posix = std.posix;
const BashInput = @import("models.zig").BashInput;
const ToolProperty = @import("models.zig").ToolProperty;
const ToolParameters = @import("models.zig").ToolParameters;
const AgentToolFunction = @import("models.zig").AgentToolFunction;
const AgentTool = @import("models.zig").AgentTool;

pub fn executeBash(allocator: std.mem.Allocator, input: BashInput) ![]const u8 {
    const max_output = input.max_output orelse 1024 * 1024;
    const timeout_sec = input.timeout orelse 30;

    var child = std.process.Child.init(&.{ "bash", "-c", input.command }, allocator);
    if (input.cwd) |cwd| {
        child.cwd = cwd;
    }
    child.stdin_behavior = if (input.stdin_data != null) .Pipe else .Close;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    try child.spawn();

    if (input.stdin_data) |data| {
        if (child.stdin) |stdin| {
            try stdin.writeAll(data);
            stdin.close();
            child.stdin = null;
        }
    }

    const timeout_ns = @as(u64, timeout_sec) * std.time.ns_per_s;
    const start_time = std.time.nanoTimestamp();

    const ArrayList = std.ArrayList;
    var stdout_data: ArrayList(u8) = .empty;
    var stderr_data: ArrayList(u8) = .empty;
    errdefer {
        stdout_data.deinit(allocator);
        stderr_data.deinit(allocator);
    }

    var buf: [4096]u8 = undefined;
    var timeout_hit = false;
    var child_term: ?std.process.Child.Term = null;

    // Prepare poll fds for stdout and stderr
    var poll_fds: [2]posix.pollfd = undefined;
    var poll_count: usize = 0;
    var stdout_idx: ?usize = null;
    var stderr_idx: ?usize = null;

    if (child.stdout) |_| {
        stdout_idx = poll_count;
        poll_fds[poll_count] = .{
            .fd = child.stdout.?.handle,
            .events = posix.POLL.IN,
            .revents = 0,
        };
        poll_count += 1;
    }

    if (child.stderr) |_| {
        stderr_idx = poll_count;
        poll_fds[poll_count] = .{
            .fd = child.stderr.?.handle,
            .events = posix.POLL.IN,
            .revents = 0,
        };
        poll_count += 1;
    }

    while (true) {
        // Check timeout first
        const elapsed = std.time.nanoTimestamp() - start_time;
        if (elapsed > timeout_ns) {
            timeout_hit = true;
            _ = child.kill() catch {};
            child_term = child.wait() catch .{ .Unknown = 1 };
            break;
        }

        // Calculate remaining time for poll (max 100ms per poll call)
        const remaining_ns = timeout_ns - @as(u64, @intCast(elapsed));
        const poll_timeout_ms = @min(100, @as(i32, @intCast(@divFloor(remaining_ns, std.time.ns_per_ms))));

        // Poll for available data - this won't block longer than poll_timeout_ms
        const ready = posix.poll(poll_fds[0..poll_count], poll_timeout_ms) catch 0;

        if (ready == 0) {
            // Poll timed out with no data - loop back to check overall timeout
            continue;
        }

        // Read from ready file descriptors
        var any_read = false;

        // Check stdout using stored index
        if (stdout_idx) |idx| {
            if (poll_fds[idx].revents & posix.POLL.IN != 0) {
                const bytes_read = child.stdout.?.read(&buf) catch 0;
                if (bytes_read > 0) {
                    any_read = true;
                    try stdout_data.appendSlice(allocator, buf[0..bytes_read]);
                    if (stdout_data.items.len >= max_output) break;
                }
            }
        }

        // Check stderr using stored index
        if (stderr_idx) |idx| {
            if (poll_fds[idx].revents & posix.POLL.IN != 0) {
                const bytes_read = child.stderr.?.read(&buf) catch 0;
                if (bytes_read > 0) {
                    any_read = true;
                    try stderr_data.appendSlice(allocator, buf[0..bytes_read]);
                    if (stderr_data.items.len >= max_output) break;
                }
            }
        }

        // Check if child has exited (pipes closed = process ended)
        const all_closed = for (poll_fds[0..poll_count]) |pf| {
            if (pf.revents & (posix.POLL.HUP | posix.POLL.ERR) == 0) break false;
        } else true;

        if (all_closed or (!any_read and ready > 0)) {
            // Pipes closed or poll returned but no data = process likely exited
            child_term = child.wait() catch .{ .Unknown = 1 };
            break;
        }
    }

    if (child_term == null) {
        child_term = child.wait() catch .{ .Unknown = 1 };
    }

    const exit_code: i32 = switch (child_term.?) {
        .Exited => |code| @as(i32, @intCast(code)),
        .Signal => |sig| -@as(i32, @intCast(sig)),
        .Stopped => |code| -@as(i32, @intCast(code)),
        .Unknown => -1,
    };

    const was_truncated = stdout_data.items.len >= max_output or stderr_data.items.len >= max_output;

    var trunc_buf: [53]u8 = undefined;
    const truncated_command = if (input.command.len > 50) blk: {
        trunc_buf[0..50].* = input.command[0..50].*;
        trunc_buf[50..53].* = "...".*;
        break :blk trunc_buf[0..53];
    } else input.command;

    const output = try std.fmt.allocPrint(allocator,
        \\<command>{s}</command>
        \\<stdout>{s}</stdout>
        \\<stderr>{s}</stderr>
        \\<exit_code>{d}</exit_code>
        \\<truncated>{}</truncated>
        \\<timeout>{}</timeout>
    , .{
        truncated_command,
        if (stdout_data.items.len == 0) "No output produced." else stdout_data.items,
        if (stderr_data.items.len == 0) "No errors." else stderr_data.items,
        exit_code,
        was_truncated,
        timeout_hit,
    });

    stdout_data.deinit(allocator);
    stderr_data.deinit(allocator);

    return output;
}

pub const bashTool = AgentTool{
    .type = "function",
    .function = .{
        .name = "bash",
        .description =
        \\Execute a bash command. Returns stdout, stderr, exit_code, truncated, timeout flags.
        \\
        \\## EXPLORATION (strict order — do not skip steps)
        \\  1. `du -sh <dir>`                                          — size gate first
        \\  2. `tree -I 'node_modules|.git|dist|build|*.lock' --max-depth 3` — structure
        \\  3. `rg -n <pattern> <path> --max-count 20`                 — targeted search
        \\  4. `sed -n 'X,Yp' <file>`                                  — read only needed range
        \\  NEVER: ls -laR, cat on unknown files, find without -maxdepth, unscoped globs
        \\
        \\## PREFERRED TOOLS
        \\  `rg`        — regex search (always prefer over grep)
        \\  `grep -n`   — line-numbered fallback only
        \\  `sed -n`    — line range extraction only (never sed -i without rg confirm first)
        \\  `jq`        — all JSON reads and writes (never sed/awk on JSON)
        \\  `yq`        — all YAML reads and writes (never sed/awk on YAML)
        \\  `wc -l`     — line count before reading any file
        \\  `stat`      — file metadata (never cat for metadata)
        \\  `awk`       — field/row filtering on plain text only
        \\
        \\## EDIT WORKFLOW (always follow this order)
        \\  1. rg — find target line number
        \\  2. sed -n 'X,Yp' — verify surrounding context
        \\  3. sed -i — make the edit
        \\  4. rg — confirm the change landed correctly
        \\  5. ast-check / typecheck — verify no new errors introduced
        \\  NEVER skip step 4 or 5. An unverified edit is a failed edit.
        \\
        \\## LANGUAGE CHECKS (run before any build)
        \\  Zig:       `zig ast-check <file>`
        \\  TypeScript:`tsc --noEmit 2>&1 | head -n 50`
        \\  Rust:      `cargo check 2>&1 | head -n 100`
        \\  Go:        `go vet ./... 2>&1 | head -n 50`
        \\  Always check the SPECIFIC file edited, not the whole project, when possible.
        \\
        \\## ERROR HANDLING (critical — prevents loops)
        \\  After a failed command:
        \\  - Read the FULL error before acting
        \\  - If the error points to a type/interface definition: read that file first
        \\  - Never re-apply the same fix twice — if it failed once, change strategy
        \\  - `as unknown as X` casts are never a valid fix for a type mismatch
        \\  - If the same error appears after your fix: the problem is UPSTREAM
        \\    → find and fix the source definition, not the call site
        \\
        \\## OUTPUT CAP (mandatory — no exceptions)
        \\  rg/grep/sed   → head -n 50   (max_output: 10000)
        \\  ast-check     → head -n 50   (max_output: 20000)
        \\  builds        → head -n 200  (max_output: 50000)
        \\  JSON dumps    → head -n 500  (max_output: 200000)
        \\  If truncated=true: STOP — narrow scope with sed ranges, do NOT raise max_output
        \\
        \\## HARD RULES (violations break the task)
        \\  1. `timeout <N>` is REQUIRED on every command — bare commands are rejected
        \\  2. NO sudo / su / doas / pkexec
        \\  3. NO full-file cat — use head / tail / sed -n ranges only
        \\  4. NO unbounded output — every pipeline needs an explicit cap
        \\  5. NO sed/awk on JSON or YAML — use jq/yq only
        \\  6. NO find without -maxdepth and path exclusions
        \\  7. NO sed -i without rg confirmation afterward
        \\  8. NO re-applying an identical fix after it already failed
        \\  9. ALWAYS set cwd explicitly — never assume working directory
        ,
        .parameters = .{
            .type = "object",
            .properties = &.{
                .{
                    .name = "command",
                    .type = "string",
                    .description =
                    \\REQUIRED format: `timeout <N> <cmd> | head -n <N>`
                    \\
                    \\Timeout by type:
                    \\  reads/search = 10s
                    \\  ast-check    = 15s
                    \\  typecheck    = 30s
                    \\  network      = 60s
                    \\  builds       = 120s
                    \\
                    \\Output cap by type:
                    \\  rg/grep/sed  = 50 lines
                    \\  ast-check    = 50 lines
                    \\  builds       = 200 lines
                    \\  JSON         = 500 lines
                    \\
                    \\GOOD: `timeout 10 tree . -I 'node_modules|.git' --max-depth 3 | head -n 80`
                    \\GOOD: `timeout 10 rg -n 'createSystemMessage' src/ --max-count 20 | head -n 50`
                    \\GOOD: `timeout 10 sed -n '120,140p' src/store/messageStore.ts`
                    \\GOOD: `timeout 10 wc -l src/types/index.ts`
                    \\GOOD: `timeout 30 tsc --noEmit 2>&1 | head -n 50`
                    \\
                    \\BAD: `ls -laR`                         ← unbounded output
                    \\BAD: `cat src/main.zig`                ← full file read
                    \\BAD: `find . -name '*.ts'`             ← missing -maxdepth and filter
                    \\BAD: `sed -i 's/x/y/g' file.ts`       ← edit without rg confirm after
                    \\BAD: same fix command run twice        ← loop, change strategy instead
                    ,
                },
                .{
                    .name = "cwd",
                    .type = "string",
                    .description =
                    \\Absolute working directory. REQUIRED — always set explicitly.
                    \\Never assume CWD. Verify with `pwd` if uncertain.
                    ,
                },
                .{
                    .name = "max_output",
                    .type = "number",
                    .description =
                    \\Max stdout+stderr bytes. Default: 10000. Max: 1048576.
                    \\  rg/grep/sed  = 10000
                    \\  ast-check    = 20000
                    \\  builds       = 50000
                    \\  JSON         = 200000
                    \\If truncated=true: narrow your command scope with sed ranges.
                    \\Do NOT raise this limit as a first response to truncation.
                    ,
                },
                .{
                    .name = "stdin_data",
                    .type = "string",
                    .description =
                    \\Stdin for the command. If omitted, stdin closes immediately.
                    \\Never run interactive commands without providing this field.
                    ,
                },
            },
            .required = &.{ "command", "cwd" },
        },
    },
};

// example how to use this tool
// const bashTool = AgentTool{
//     .type = "function",
//     .function = .{
//         .name = "bash",
//         .description = "Execute a bash command and return stdout and stderr output",
//         .parameters = .{
//             .type = "object",
//             .properties = &.{
//                 .{
//                     .name = "command",
//                     .type = "string",
//                     .description = "The bash command to execute",
//                 },
//                 .{
//                     .name = "timeout",
//                     .type = "number",
//                     .description = "Timeout in seconds, default 30",
//                 },
//                 .{
//                     .name = "cwd",
//                     .type = "string",
//                     .description = "Working directory to run the command in",
//                 },
//                 .{
//                     .name = "max_output",
//                     .type = "number",
//                     .description = "Max output size in bytes, default 1048576 (1MB). Increase if output is truncated",
//                 },
//             },
//             .required = &.{"command"},
//         },
//     },
// };

test {
    _ = @import("bash_test.zig");
}
