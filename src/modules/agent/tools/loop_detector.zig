const std = @import("std");

pub const LoopDetector = struct {
    last_command: ?[]const u8 = null,
    repeat_count: usize = 0,

    pub fn check(self: *LoopDetector, command: []const u8) bool {
        if (self.last_command) |last| {
            if (std.mem.eql(u8, last, command)) {
                self.repeat_count += 1;
                return self.repeat_count >= 3;
            }
        }
        self.last_command = command;
        self.repeat_count = 0;
        return false;
    }
};
