const std = @import("std");
const command_defs = @import("command_defs.zig");

test "command_defs: /compact is in command names" {
    const names = command_defs.getCommandNames();
    var found = false;
    for (names) |name| {
        if (std.mem.eql(u8, name, "/compact")) {
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
}

test "command_defs: /compact has correct description" {
    const commands = command_defs.getCommands();
    var found = false;
    for (commands) |cmd| {
        if (std.mem.eql(u8, cmd.name, "/compact")) {
            found = true;
            // Verify description mentions compaction
            try std.testing.expect(std.mem.indexOf(u8, cmd.description, "compaction") != null);
            break;
        }
    }
    try std.testing.expect(found);
}

test "command_defs: all commands have unique names" {
    const names = command_defs.getCommandNames();
    var i: usize = 0;
    while (i < names.len) : (i += 1) {
        var j: usize = i + 1;
        while (j < names.len) : (j += 1) {
            try std.testing.expect(!std.mem.eql(u8, names[i], names[j]));
        }
    }
}

test "command_defs: command names match commands descriptions count" {
    const names = command_defs.getCommandNames();
    const commands = command_defs.getCommands();
    try std.testing.expectEqual(names.len, commands.len);
}
