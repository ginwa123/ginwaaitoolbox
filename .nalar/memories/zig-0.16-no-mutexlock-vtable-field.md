# Zig 0.16 — `std.Io.VTable` has NO `mutexLock`/`mutexUnlock` fields

A `noopIo` shim that exposes only `mutexLock`/`mutexUnlock` for
`std.Io.Mutex` does NOT compile in Zig 0.16 — the VTable has no such
fields. The `std.Io.Mutex` lock/unlock paths dispatch through
`io.futexWait` / `io.futexWaitUncancelable` / `io.futexWake`, not
through dedicated mutex vtable entries.

## Symptom

```zig
const noopIo: std.Io = .{
    .userdata = undefined,
    .vtable = &.{
        .mutexLock = noopMutexLock,
        .mutexUnlock = noopMutexUnlock,
    },
};
// mutex.lockUncancelable(noopIo); mutex.unlock(noopIo);
```

Compile error:

```
src/foo.zig:NN:NN: error: no field named 'mutexLock' in struct 'Io.VTable'
        .mutexLock = noopMutexLock,
         ^~~~~~~~~
/usr/local/lib/zig/std/Io.zig:51:20: note: struct declared here
pub const VTable = struct {
```

## Why

`/usr/local/lib/zig/std/Io.zig:1587-1650` — the `Mutex` struct is
`extern struct { state: std.atomic.Value(State), }`. `tryLock` is a
pure atomic CAS. `lock` / `lockUncancelable` use
`io.futexWait`/`io.futexWaitUncancelable` only when the initial CAS
fails. `unlock` uses `io.futexWake` only when transitioning out of
`.contended`. There are no `mutexLock` / `mutexUnlock` vtable
function pointers — mutexes are not a first-class vtable concept in
0.16.

So even if you shimmed `futexWait` / `futexWaitUncancelable` /
`futexWake` in the noopIo, the VTable struct literal in the
`.vtable = &.{...}` expression would still reject the unknown
`mutexLock` field — the vtable type checks are eager, not lazy.

## The fix for module-level global state with no Io

Use `std.atomic.Mutex` (a tiny `enum(u8) { unlocked, locked }` with
`tryLock() bool` and `unlock() void`). It's a lock-free spinlock with
no Io dependency. Critical section must be small (a few hundred ns).

```zig
var map: std.StringHashMapUnmanaged(V) = .empty;
var mutex: std.atomic.Mutex = .unlocked;

fn lock() void {
    while (!mutex.tryLock()) std.atomic.spinLoopHint();
}

pub fn op(...) T {
    lock();
    defer mutex.unlock();
    // critical section
}
```

This is the same pattern used in `src/modules/agent/tools/bash.zig`
for the bash stdout/stderr mutexes — see lines 248-282 of that file.

## When to use each mutex type in Zig 0.16

| Mutex type           | Io required? | Blocking?    | Use when                                          |
|----------------------|--------------|--------------|---------------------------------------------------|
| `std.Io.Mutex`       | yes          | yes (futex)  | Io-runtime code with held-across-IO critical sections |
| `std.atomic.Mutex`   | no           | no (spin)    | `std.Thread.spawn`'d workers, module-level globals, anywhere Io is unavailable or critical section is < 1µs |

## When This Bites

- Writing a module-level global (singleton state, in-memory cache)
  that needs a mutex but has no `io: std.Io` in scope.
- Trying to write unit tests for code that uses `std.Io.Mutex` from
  the test's main thread (the Io runtime's `futexWait` requires
  being called from the Io thread; same workaround as
  `sse_manager.zig`'s `registerClientForTest`).
- Porting 0.15 code that had `std.Thread.Mutex` to 0.16 — the
  natural-feeling "wrap it in a noopIo" doesn't work; use
  `std.atomic.Mutex` instead.

## How to verify after the fix

1. `timeout 180 zig build test --summary all 2>&1 | tail -n 5` — must
   show `test success` and the expected new test count.
2. `git diff` the file and confirm no `.mutexLock` / `.mutexUnlock`
   vtable fields remain.
3. Check the critical section is small (one or two map ops, no
   allocation, no I/O).
