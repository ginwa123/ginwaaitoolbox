# Zig 0.16 — `std.Io.Select` race for process timeout (vs busy-poll)

`std.Io.Select` is the proper Zig 0.16 primitive for racing two
async tasks (e.g., deadline-sleep vs child-completion). It replaces
the old `while-true { check; sleep(10ms); }` busy-poll with a
futex-parked deadline task. Only the LOSER of the race still spins
its 10ms poll; the WINNER returns immediately when its futex wakes.

## The pattern

```zig
const Result = union(enum) { timeout: void, child_done: void };

var buf: [1]Result = .{undefined};
var select = std.Io.Select(Result).init(io, &buf);
defer select.cancelDiscard();              // release loser resources

select.async(.timeout,   timeoutSleepFn,   .{ io, timeout_ns });
select.async(.child_done, waitChildFn,     .{ io, &stdout_eof, &stderr_eof });

const result = try select.await();         // ← NO `io` argument
switch (result) {
    .timeout    => kill_child_and_reap(),
    .child_done => call_child_wait(),
}
```

`cancelDiscard()` after `await()` releases the loser's cancelation
token and queue slot. Without it the loser task leaks.

## Pitfalls (all hit during the bash-mandatory-timeout PR)

1. **`select.await()` does NOT take `io`** — Io is stored in the Select
   struct (set by `init(io, buf)`). Calling `select.await(io)` compiles
   to `error: member function expected 0 argument(s), found 1`.
   The signature is `pub fn await(s: *S) Cancelable!U`.

2. **Zig 0.16 has no `goto`** — use a labeled block for cross-branch
   fall-through. The natural-looking pattern when the
   `error.Canceled` branch needs to take the same kill path as the
   `.timeout` winner:
   ```zig
   blk: {
       const r = try select.await() catch |err| switch (err) {
           error.Canceled => { kill_child(); break :blk; },
       };
       switch (r) { .timeout => ..., .child_done => ... }
   }
   ```
   `goto after_switch;` fails to compile.

3. **`testing.expectError` takes `anyerror` (a value), NOT a type** —
   `expectError(error.MandatoryTimeoutMissing, result)` works,
   `expectError(bash.MandatoryTimeoutMissing, result)` fails with
   `expected type 'anyerror', found 'type'`. Even when
   `bash.MandatoryTimeoutMissing` is declared as
   `error{MandatoryTimeoutMissing}` (a type), pass the literal
   `error.X` value.

4. **The `union` field type must exactly match the async function's
   return type** — for `field: void`, the function returns `void`.
   `std.Io.Group.async` internally does
   `_ = @as(Cancelable!void, @call(.auto, function, args)) catch {};`
   so `fn (...) void` is fine for void-field Select arms.

## Background vs foreground in the bash timeout

The `MandatoryTimeoutMissing` validation should EXEMPT the background
spawn path. Background processes detach via `nohup ... &` and have no
deadline enforced by the tool — the caller is responsible for killing
them later. Treating background as foreground would force every
`nohup`-using command to specify an arbitrary deadline.

## Cross-platform

`std.Io.Select` works on `std.Io.Threaded` (Linux + macOS + Windows
via UCRT). The implementation is in
`/usr/local/lib/zig/std/Io/Threaded.zig:2074` (async) and `:2176`
(groupAsync). No special per-platform handling needed beyond
avoiding `std.os.linux.*` syscalls in the bodies.

## Reference

`src/modules/agent/tools/bash.zig` in commit `38791a22` (PR #82,
squash-merged into main) is the working example. The 6 bash_tool
tests pass after the change:

```
bash_tool: foreground echo command runs on host OS...OK
bash_tool: large output is truncated by line count...OK
bash_tool: timeout fires on long-running command...OK        ← io.async path
bash_tool: missing mandatory_timeout returns MandatoryTimeoutMissing...OK
bash_tool: mandatory_timeout = 0 returns MandatoryTimeoutMissing...OK
bash_tool: background mode ignores missing mandatory_timeout...OK
```

## When this bites

- Any tool that runs a subprocess with a deadline and currently polls
  the eof/deadline state via `std.Io.sleep` loops.
- Any "race two async tasks" pattern that would otherwise need a
  semaphore / flag / Channel (Select is the cleaner Io-runtime primitive).
- Any code that calls `select.await(io)` (wrong signature) or uses
  `goto` for fall-through (Zig 0.16 rejects it).

## How to verify

1. `zig build test` — the 3 new contract tests pass:
   missing/zero/background variants of `mandatory_timeout`.
2. `zig build install:linux:system` — `compile exe nalar` succeeds
   (the cp to `/usr/local/bin/nalar` fails harmlessly on permission,
   as expected per the project convention).
3. The existing "timeout fires on long-running command" test now
   exercises the Select path (it was the same test, but the
   underlying mechanism changed from busy-poll to Select).