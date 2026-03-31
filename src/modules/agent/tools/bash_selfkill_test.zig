const std = @import("std");
const selfkill = @import("bash_selfkill.zig");

test "detect_self_kill - safe commands" {
    // Use a PID (54321) that doesn't match self_pid (12345)
    try std.testing.expect((try selfkill.detect_self_kill(std.testing.allocator, "ls -la", 12345)) == null);
    try std.testing.expect((try selfkill.detect_self_kill(std.testing.allocator, "echo hello", 12345)) == null);
    try std.testing.expect((try selfkill.detect_self_kill(std.testing.allocator, "ps aux", 12345)) == null);
    try std.testing.expect((try selfkill.detect_self_kill(std.testing.allocator, "kill 54321", 12345)) == null);
    try std.testing.expect((try selfkill.detect_self_kill(std.testing.allocator, "pkill firefox", 12345)) == null);
    try std.testing.expect((try selfkill.detect_self_kill(std.testing.allocator, "zig build", 12345)) == null);
    try std.testing.expect((try selfkill.detect_self_kill(std.testing.allocator, "", 12345)) == null);
}

test "detect_self_kill - dangerous commands" {
    // Should detect self-kill
    try std.testing.expect((try selfkill.detect_self_kill(std.testing.allocator, "kill", 12345)) != null);
    try std.testing.expect((try selfkill.detect_self_kill(std.testing.allocator, "killall", 12345)) != null);
    try std.testing.expect((try selfkill.detect_self_kill(std.testing.allocator, "pkill", 12345)) != null);
    try std.testing.expect((try selfkill.detect_self_kill(std.testing.allocator, "pgrep", 12345)) != null);
    try std.testing.expect((try selfkill.detect_self_kill(std.testing.allocator, "killall5", 12345)) != null);
    try std.testing.expect((try selfkill.detect_self_kill(std.testing.allocator, "exit", 12345)) != null);
    try std.testing.expect((try selfkill.detect_self_kill(std.testing.allocator, "exit 0", 12345)) != null);
    try std.testing.expect((try selfkill.detect_self_kill(std.testing.allocator, "kill -9", 12345)) != null);
    try std.testing.expect((try selfkill.detect_self_kill(std.testing.allocator, "kill -SIGKILL", 12345)) != null);
    
    // Numeric PID matching self
    try std.testing.expect((try selfkill.detect_self_kill(std.testing.allocator, "kill 12345", 12345)) != null);
    try std.testing.expect((try selfkill.detect_self_kill(std.testing.allocator, "kill -9 12345", 12345)) != null);
    
    // PID 1 (init)
    try std.testing.expect((try selfkill.detect_self_kill(std.testing.allocator, "kill 1", 12345)) != null);
    try std.testing.expect((try selfkill.detect_self_kill(std.testing.allocator, "kill -9 1", 12345)) != null);
    
    // Negative PIDs
    try std.testing.expect((try selfkill.detect_self_kill(std.testing.allocator, "kill -1", 12345)) != null);
    try std.testing.expect((try selfkill.detect_self_kill(std.testing.allocator, "killall -9 -1", 12345)) != null);
}

test "detect_self_kill - shell variables" {
    // $$ should be detected
    try std.testing.expect((try selfkill.detect_self_kill(std.testing.allocator, "kill $$", 12345)) != null);
    try std.testing.expect((try selfkill.detect_self_kill(std.testing.allocator, "kill -9 $$", 12345)) != null);
    try std.testing.expect((try selfkill.detect_self_kill(std.testing.allocator, "echo $$", 12345)) != null);
    
    // $! is a warning (less certain)
    try std.testing.expect((try selfkill.detect_self_kill(std.testing.allocator, "kill $!", 12345)) != null);
}
