const std = @import("std");
const bashMod = @import("bash.zig");
const BashInput = @import("models.zig").BashInput;

test "bash execute helloworld" {
    const allocator = std.testing.allocator;
    const input = BashInput{
        .command = "echo \"hello world\"",
        .timeout = null,
        .cwd = null,
        .max_output = null,
    };
    const r = try bashMod.executeBash(allocator, input);
    defer allocator.free(r);

    const expected =
        \\<stdout>hello world
        \\</stdout>
        \\<stderr></stderr>
        \\<exit_code>0</exit_code>
        \\<truncated>false</truncated>
    ;
    try std.testing.expectEqualStrings(expected, r);
}
