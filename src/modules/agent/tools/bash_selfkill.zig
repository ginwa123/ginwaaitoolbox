const std = @import("std");
const process = @import("nalarcore").helpers.process;

/// Self-kill detection result: null = safe, error message = dangerous
pub const SelfKillResult = ?[]const u8;

/// Get the current process ID (cross-platform).
///
/// Returns `i32` directly (not `std.c.pid_t`) so the value is comparable
/// to `i32` parsed from shell command arguments. On Windows,
/// `std.c.pid_t` is `*anyopaque` (no real PID concept in Windows libc),
/// so using `i32` is the cross-platform correct choice.
pub fn get_self_pid() i32 {
    return process.getCurrentProcessId();
}

/// Detect if a command attempts to kill the current process
/// Returns an error message if self-kill is detected, null otherwise
pub fn detect_self_kill(allocator: std.mem.Allocator, command: []const u8, self_pid: i32) !SelfKillResult {
    _ = allocator; // Reserved for future use
    const trimmed = std.mem.trim(u8, command, " \t\n\r");

    // Empty command is safe
    if (trimmed.len == 0) return null;

    // === Check 1: Command starts with exit (exits shell) ===
    if (std.mem.startsWith(u8, trimmed, "exit")) {
        const rest = trimmed[4..];
        const after = std.mem.trim(u8, rest, " \t");
        // "exit" alone or "exit 0" etc - this exits the shell
        if (after.len == 0 or std.mem.startsWith(u8, after, "0") or
            std.mem.startsWith(u8, after, "1") or
            std.mem.startsWith(u8, after, "SIG"))
        {
            return "Command 'exit' will terminate the current shell process.";
        }
    }

    // === Check 2: Command starts with kill ===
    if (std.mem.startsWith(u8, trimmed, "kill")) {
        const rest = trimmed[4..];
        const after = std.mem.trim(u8, rest, " \t");

        // "kill" with no arguments - kills current process (SIGTERM=15)
        if (after.len == 0) {
            return "Command 'kill' with no arguments will kill the current process. " ++
                "Use 'kill <pid>' to target a specific process.";
        }

        // "kill -9" or "kill -KILL" or "kill -SIGKILL" - force kill
        if (std.mem.startsWith(u8, after, "-9") or
            std.mem.startsWith(u8, after, "-KILL") or
            std.mem.startsWith(u8, after, "-SIGKILL"))
        {
            // Check what's after the signal
            const signal_part = if (std.mem.startsWith(u8, after, "-9"))
                after[2..]
            else if (std.mem.startsWith(u8, after, "-KILL"))
                after[5..]
            else
                after[8..];
            const after_signal = std.mem.trim(u8, signal_part, " \t");

            if (after_signal.len == 0) {
                return "Command 'kill -9' with no target will force-kill the current process. " ++
                    "This is IMMEDIATE and cannot be intercepted.";
            }

            // Check for shell variables that reference current process
            if (detectShellPidVar(after_signal)) |_| {
                return "Command 'kill -9 <shell_var>' targets the current process. " ++
                    "This is IMMEDIATE and cannot be intercepted.";
            }

            // Check for numeric PID
            if (parsePid(after_signal)) |target_pid| {
                if (target_pid == self_pid) {
                    return "Command 'kill -9 <self_pid>' targets YOUR OWN PROCESS. " ++
                        "This is IMMEDIATE and cannot be intercepted.";
                }
                // Warn about PID 1 (init) - catastrophic if killed
                if (target_pid == 1) {
                    return "Command 'kill -9 1' targets PID 1 (init/systemd). Killing init will crash the system!";
                }
            }
        }

        // Check for shell variables in arguments
        if (detectShellPidVar(after)) |_| {
            return "Command 'kill <shell_var>' targets the current process.";
        }

        // Check for numeric PID
        if (parsePid(after)) |target_pid| {
            if (target_pid == self_pid) {
                return "Command 'kill <self_pid>' targets YOUR OWN PROCESS.";
            }
            // Warn about PID 1 (init) - catastrophic if killed
            if (target_pid == 1) {
                return "Command targets PID 1 (init/systemd). Killing init will crash the system!";
            }
            // Warn about negative PIDs (-1 kills all processes user can access)
            if (target_pid < 0) {
                return "Command 'kill <negative_pid>' may affect multiple processes including the current one.";
            }
        }
    }

    // === Check 3: Command starts with killall ===
    if (std.mem.startsWith(u8, trimmed, "killall")) {
        const rest = trimmed[7..];
        const after = std.mem.trim(u8, rest, " \t");

        // "killall" with no arguments - kills current process
        if (after.len == 0) {
            return "Command 'killall' with no arguments will kill processes. " ++
                "Use 'killall <name>' to target specific processes.";
        }

        // "killall -9" without target
        if (std.mem.startsWith(u8, after, "-9") or
            std.mem.startsWith(u8, after, "-SIGKILL"))
        {
            const signal_part = if (std.mem.startsWith(u8, after, "-9"))
                after[2..]
            else
                after[8..];
            const after_signal = std.mem.trim(u8, signal_part, " \t");

            if (after_signal.len == 0) {
                return "Command 'killall -9' without target is dangerous - may kill many processes.";
            }

            // Check for negative PIDs
            if (parsePid(after_signal)) |target_pid| {
                if (target_pid < 0) {
                    return "Command 'killall -9 -1' will kill ALL processes! This is catastrophic.";
                }
            }
        }

        // Check for negative PIDs
        if (parsePid(after)) |target_pid| {
            if (target_pid < 0) {
                return "Command 'killall <negative_pid>' may affect multiple processes.";
            }
        }
    }

    // === Check 4: Command starts with pkill or pgrep ===
    if (std.mem.startsWith(u8, trimmed, "pkill") or
        std.mem.startsWith(u8, trimmed, "pgrep"))
    {
        const rest = if (std.mem.startsWith(u8, trimmed, "pkill"))
            trimmed[5..]
        else
            trimmed[5..];
        const after = std.mem.trim(u8, rest, " \t");

        // "pkill" with no arguments - matches all processes
        if (after.len == 0) {
            return "Command 'pkill' without pattern will match ALL processes. Use 'pkill <pattern>' with care.";
        }

        // Check for patterns that might match self
        if (std.mem.indexOf(u8, after, "nala") != null) {
            return "Command may match the current 'nalar' process by name pattern.";
        }
    }

    // === Check 5: Command starts with killall5 ===
    if (std.mem.startsWith(u8, trimmed, "killall5")) {
        return "Command 'killall5' is dangerous - may kill many processes including init.";
    }

    // === Check 6: Command contains $$ (current shell PID) ===
    if (std.mem.indexOf(u8, trimmed, "$$") != null) {
        return "Command contains '$$' which expands to current shell PID. " ++
            "This may target the current process.";
    }

    // === Check 7: Command contains $! (last background job PID) ===
    if (std.mem.indexOf(u8, trimmed, "$!") != null) {
        return "Command contains '$!' which may reference a background job PID.";
    }

    // === Check 8: Command contains kill -0 (existence check) ===
    if (std.mem.indexOf(u8, trimmed, "kill -0") != null or
        std.mem.indexOf(u8, trimmed, "kill -s 0") != null)
    {
        const kill_0_pos = std.mem.indexOf(u8, trimmed, "kill -0") orelse
            std.mem.indexOf(u8, trimmed, "kill -s 0") orelse 0;
        const after = std.mem.trim(u8, trimmed[kill_0_pos + 7 ..], " \t");
        if (after.len == 0) {
            return "Command 'kill -0' without target checks the current process existence.";
        }
    }

    return null;
}

/// Check if a string contains shell variables that reference current process
fn detectShellPidVar(s: []const u8) ?[]const u8 {
    if (std.mem.indexOf(u8, s, "$$") != null) return "$$";
    if (std.mem.indexOf(u8, s, "$!") != null) return "$!";
    if (std.mem.indexOf(u8, s, "$PPID") != null) return "$PPID";
    return null;
}

/// Try to parse a PID from a string
/// Returns null if not a valid PID number
fn parsePid(s: []const u8) ?i32 {
    // Skip leading minus for negative PIDs
    const start: usize = if (s.len > 0 and s[0] == '-') 1 else 0;
    if (start >= s.len) return null;

    var pid: i32 = 0;
    for (s[start..]) |c| {
        if (c < '0' or c > '9') return null;
        pid = pid * 10 + @as(i32, @intCast(c - '0'));
        // Reasonable PID upper bound check (PIDs rarely exceed 2^22)
        if (pid > 4194304) return null;
    }

    return if (s[0] == '-') -pid else pid;
}
