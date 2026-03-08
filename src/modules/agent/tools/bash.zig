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
        \\⚠ Commands are validated before execution. Banned or malformed commands return
        \\exit_code=1 with a rejection message and suggested alternative. Fix and retry.
        \\
        \\## EXPLORATION (strict order — do not skip steps)
        \\  1. `du -sh <dir>`                                          — size gate first
        \\  2. `tree -I 'node_modules|.git|dist|build|*.lock' --max-depth 3 | head -n 80`
        \\  3. `wc -l <file>`                                         — line count before ANY file read
        \\  4. Read strategy based on line count:
        \\       <= 300 lines  → `cat <file> | head -n 300`           — read full file
        \\       300-1000      → `rg -A 80 '<construct>' <file> | head -n 100`
        \\       > 1000 lines  → `rg -A 50 '<construct>' <file> | head -n 100`
        \\  5. If rg returns zero matches:
        \\       → `grep -n '<partial_name>' <file> | head -n 20`     — partial name fallback
        \\       → if still no match: `cat <file> | head -n 300`      (files <= 1000 lines only)
        \\       → if file > 1000 lines and no match: report gap — do not read the full file
        \\  ALWAYS: re-read after any write to verify the change landed correctly
        \\  ALWAYS: re-read if the file may have changed since your last read
        \\
        \\## PREFERRED TOOLS
        \\  `rg`        — regex search and construct extraction (always prefer over grep)
        \\  `grep -n`   — fallback only when rg returns zero matches
        \\  `cat`       — full file read for files <= 300 lines only
        \\  `rg -A <N>` — construct extraction for all files > 300 lines
        \\  `jq`        — all JSON reads and writes (see JQ WRITE PATTERN below)
        \\  `yq`        — all YAML reads and writes (never awk on YAML)
        \\  `wc -l`     — ALWAYS run before reading any file
        \\  `stat`      — file metadata (never cat for metadata)
        \\  `awk`       — field/row filtering on plain text only
        \\
        \\## JQ WRITE PATTERN (mandatory)
        \\  ALWAYS use temp-file-and-move:
        \\    `jq '<filter>' <file> > <file>.tmp && mv <file>.tmp <file>`
        \\  NEVER: `jq '<filter>' <file> > <file>`    ← truncates file to zero bytes
        \\  After every jq write: `jq '.' <file>`     — confirm valid JSON
        \\
        \\## EDIT WORKFLOW (always follow this order)
        \\  1. `rg -n '<construct_name>' <file> | head -n 20` — locate anchor
        \\     If zero matches: `grep -n '<partial>' <file> | head -n 20`
        \\  2. Write full replacement construct using verbatim current code from tasklist
        \\     Never use line numbers — named constructs only
        \\  3. `rg -A <N> '<construct_name>' <file> | head -n 100` — verify change landed
        \\  4. `ast-check / typecheck` the edited file
        \\  5. If a type definition changed: `rg -l '<type_name>' <src_dir> | head -n 50`
        \\     then typecheck every dependent file found
        \\  NEVER skip steps 3, 4, 5. An unverified edit is a failed edit.
        \\
        \\## TRUNCATION RECOVERY
        \\  If truncated=true after `rg -A <N>`:
        \\  - Step 1: double -A once → `rg -A <2N> '<construct>' <file> | head -n 200`
        \\  - Step 2: if still truncated → split:
        \\      `rg -A <N> '<construct_start>' <file> | head -n 100`
        \\      `rg -A <N> '<construct_end>'   <file> | head -n 100`
        \\  - Step 3: if still truncated → report gap: "construct <name> exceeds extractable size"
        \\  NEVER raise max_output as a response to truncation
        \\
        \\## DONE SIGNAL
        \\  Stop editing when ALL hold:
        \\  - typecheck / ast-check passes with 0 errors on all edited files
        \\  - all dependent files typecheck cleanly
        \\  - tasklist Subtask acceptance criteria are met
    \\
        \\
        \\## LANGUAGE CHECKS
        \\  Zig:        `zig ast-check <file> | head -n 50`
        \\  TypeScript: `tsc --noEmit 2>&1 | head -n 50`
        \\  Rust:       `cargo check 2>&1 | head -n 100`
        \\  Go:         `go vet ./... 2>&1 | head -n 50`
        \\  Check the SPECIFIC file edited — not the whole project — when possible.
        \\
        \\## ERROR HANDLING
        \\  - Read the FULL error before acting
        \\  - If error points to a type definition: read that file first
        \\  - Never re-apply the same fix twice — change strategy
        \\  - If the same error appears after your fix: problem is UPSTREAM
        \\    → fix the source definition, not the call site
        \\  - `as unknown as X` casts are never a valid fix for a type mismatch
        \\
        \\## OUTPUT CAP (mandatory — enforced by validator)
        \\  rg/grep     → head -n 50   / 10000 bytes
        \\  cat         → head -n 300  / 50000 bytes  (files <= 300 lines only)
        \\  rg -A       → head -n 100  / 20000 bytes
        \\  ast-check   → head -n 50   / 20000 bytes
        \\  builds      → head -n 200  / 50000 bytes
        \\  JSON        → head -n 500  / 200000 bytes
        \\  If truncated=true: follow TRUNCATION RECOVERY — never raise max_output
        ,
        .parameters = .{
            .type = "object",
            .properties = &.{
                .{
                    .name = "command",
                    .type = "string",
                    .description =
                    \\REQUIRED format: `timeout <N> <cmd> | head -n <N>`
                    \\Commands missing timeout or head -n cap will be rejected with exit_code=1.
                    \\
                    \\Timeout by type:
                    \\  reads/search = 10s
                    \\  ast-check    = 15s
                    \\  typecheck    = 30s
                    \\  network      = 60s
                    \\  builds       = 120s
                    \\
                    \\Read strategy (always wc -l first):
                    \\  <= 300 lines  → `timeout 10 cat <file> | head -n 300`
                    \\  300-1000      → `timeout 10 rg -A 80 '<construct>' <file> | head -n 100`
                    \\  > 1000 lines  → `timeout 10 rg -A 50 '<construct>' <file> | head -n 100`
                    \\  zero matches  → `timeout 10 grep -n '<partial>' <file> | head -n 20`
                    \\
                    \\GOOD: `timeout 10 wc -l src/get_skill.zig`
                    \\GOOD: `timeout 10 cat src/small_file.zig | head -n 300`
                    \\GOOD: `timeout 10 rg -A 50 'pub fn executeGetSkill' src/get_skill.zig | head -n 100`
                    \\GOOD: `timeout 10 grep -n 'executeGet' src/get_skill.zig | head -n 20`
                    \\GOOD: `timeout 10 rg -A 30 'pub fn executeGetSkill' src/get_skill.zig | head -n 50`
                    \\      (re-read after write — verification)
                    \\GOOD: `jq '.key = "val"' f.json > f.json.tmp && mv f.json.tmp f.json`
                    \\GOOD: `timeout 10 rg -l 'MyStruct' src/ | head -n 50`
                    \\
                    \\BAD: `ls -laR`                               ← REJECTED — unbounded output
                    \\BAD: `sed -n '60,75p' src/main.zig`         ← REJECTED — sed -n banned
                    \\BAD: `sed -i 's/old/new/g' file.zig`        ← REJECTED — sed -i banned
                    \\BAD: `find . -name '*.ts'`                   ← REJECTED — missing -maxdepth
                    \\BAD: `cat src/main.zig`                      ← REJECTED — no timeout, no cap
                    \\BAD: `sudo apt install`                      ← REJECTED — sudo banned
                    \\BAD: `rm -rf node_modules`                   ← REJECTED — destructive delete
                    \\BAD: `jq '.' file.json > file.json`         ← REJECTED — truncates to zero
                    \\BAD: same fix command run twice              ← change strategy instead
                    ,
                },
                .{
                    .name = "cwd",
                    .type = "string",
                    .description =
                    \\Absolute working directory. REQUIRED — always set explicitly.
                    \\Never assume CWD. Verify with `timeout 10 pwd` if uncertain.
                    ,
                },
                .{
                    .name = "max_output",
                    .type = "number",
                    .description =
                    \\Max stdout+stderr bytes. Default: 10000. Max: 1048576.
                    \\  rg/grep      = 10000
                    \\  cat          = 50000
                    \\  rg -A        = 20000
                    \\  ast-check    = 20000
                    \\  builds       = 50000
                    \\  JSON         = 200000
                    \\If truncated=true: follow TRUNCATION RECOVERY — never raise this limit.
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

test {
    _ = @import("bash_test.zig");
}
