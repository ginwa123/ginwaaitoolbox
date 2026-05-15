const std = @import("std");
const event_bus = @import("event.zig");

const CtxCallback = struct {
    data_id: []const u8,
    data_value: []const u8,
};

pub fn main() !void {
    const alloc = std.heap.page_allocator;
    var bus = event_bus.EventBus.init("my-bus", alloc);
    defer bus.deinit();

    const MyCallback = struct {
        fn callback(data: CtxCallback) void {
            std.debug.print("received callback: data={any}\n", .{data});
        }
    };

    try bus.subscribe(CtxCallback, "listener1", MyCallback.callback);

    var ticker: u32 = 0;

    while (ticker < 3) : (ticker += 1) {
        const xxx = CtxCallback{
            .data_id = "xxx",
            .data_value = "xxx",
        };

        bus.emit(CtxCallback, "listener1", xxx);
    }

    bus.unsubscribe("listener1");
    std.debug.print("done\n", .{});
}
