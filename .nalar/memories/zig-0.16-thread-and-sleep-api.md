# Zig 0.16 — std.Thread, std.time.sleep, and child.kill API Changes

Three API changes in Zig 0.16 that bit me when porting `bash.zig` from 0.15 to cross-platform. All three were in the plan but couldn't be used as written.

## 1. `std.Thread.Mutex` does not exist

There is **no** `std.Thread.Mutex` in Zig 0.16. The `std.Thread` module exposes only thread spawning/name/handle APIs, no synchronization primitives.

Available mutex options in 0.16:
- `std.Io.Mutex` — futex-based, but `lock(io)` / `lockUncancelable(io)` / `unlock(io)` all require an `Io` reference (the vtable is dispatched through `Io.futexWait`)
- `std.atomic.Mutex` — a tiny `enum(u8) { unlocked, locked }` with `tryLock() bool` and `unlock() void`. **No blocking `lock` method.**

### The pattern: `std.atomic.Mutex` as a spinlock

```zig
var mutex: std.atomic.Mutex = .unlocked;

// Acquire (spin):
while (!mutex.tryLock()) {
    std.atomic.spinLoopHint();
}
defer mutex.unlock();
```

Critical section: must be small (a few hundred ns) for the spin to be acceptable. `std.atomic.spinLoopHint()` exists and emits a `pause` instruction on x86 / yields on ARM.

When NOT to use this:
- Long critical sections (allocation, I/O, syscalls) — use `std.Io.Mutex.lockUncancelable(io)` instead
- When the thread doing the lock doesn't have a stable `Io` reference (e.g. a `std.Thread.spawn`'d worker) — use the spinlock

## 2. `std.time.sleep` is gone

The legacy `std.time.sleep(ns: u64)` is removed. Replaced with the Io-aware `std.Io.sleep`:

```zig
pub fn sleep(io: Io, duration: Duration, clock: Clock) Cancelable!void
```

Where:
- `std.Io.Duration = struct { nanoseconds: i96 }` — with `fromMilliseconds(ms: i64)`, `fromSeconds`, etc.
- `Clock = enum { real, monotonic, ... }`

### The pattern

```zig
try std.Io.sleep(io, .{ .nanoseconds = 10 * std.time.ns_per_ms }, .real);
```

The `try` is required because `sleep` is `Cancelable!void` — the Io runtime can cancel it.

## 3. `child.kill` returns `void`, not `Term`

In Zig 0.15, `std.process.Child.kill(child: *Child, io: Io) Term` returned a `Term` (you discarded with `_ = `). In Zig 0.16, it returns **`void`** AND blocks until the child terminates AND cleans up resources:

```zig
pub fn kill(child: *Child, io: Io) void {
    if (child.id == null) {
        assert(child.stdin == null);
        assert(child.stdout == null);
        assert(child.stderr == null);
        return;
    }
    io.vtable.childKill(io.userdata, child);
    assert(child.id == null);
}
```

The `assert(child.id == null)` AFTER the kill means you **cannot** call `child.wait(io)` after `kill(io)` — it will panic on the `assert(child.id != null)` inside `wait`.

### The pattern

```zig
// To kill and capture the Term:
// 1. Save Term BEFORE killing (e.g. as .{ .signal = .KILL })
// 2. Call kill — it blocks
// 3. Don't call wait after kill

if (elapsed > timeout_ns) {
    timeout_hit = true;
    child.kill(io);  // void, blocks until child dies
    child_term = .{ .signal = .KILL };  // record what happened
    break;
}
```

The old `_ = child.kill(io);` style still compiles in 0.16 — Zig allows `_ = ` on void expressions (no-op). The first time you see this, the `assert(child.id == null)` will fire if you naively add `child.wait(io)` after the kill.

## When this bites

- Porting threaded code from 0.15 → 0.16 (any code that needs a `std.Thread.Mutex`)
- Porting code that uses `std.time.sleep` in a polling loop (very common: the "check for data every 10ms" pattern)
- Porting code that has `_ = child.kill(io)` immediately followed by `child.wait(io)` — the wait will assert-fail at runtime
</content>
</invoke>