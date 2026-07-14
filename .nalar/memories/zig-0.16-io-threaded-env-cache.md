# Zig 0.16 — `std.Io.Threaded` env cache blocks runtime env propagation

`std.Io.Threaded` memoizes the process environment (HOME, PATH, etc.) at
construction time, reading from the env block passed to `init()`. Once
memoized, the cache is **permanent** for the lifetime of the Io — there is
no public API to re-scan or invalidate it.

## Symptom

You `setenv("PATH", ...)` (via libc) at runtime, then call
`std.process.spawn(io, .{.argv = "my-binary"})`. The child process is
spawned, but:
- The kernel uses the libc env (which has your updated PATH) to resolve
  `argv[0]` — so the binary IS findable.
- The Io runtime uses its CACHED `t.environ.string.PATH` (from the env
  block captured at Io init time) to build the child's `envp` — so the
  child gets the STALE PATH, HOME, and other env vars.

This is invisible until the sub-process tries to use a stale env var (e.g.,
opens a file at the wrong HOME) and fails silently.

## Why

Look at `std/Io/Threaded.zig`:

- Line 75-76: `environ_initialized: bool` and `environ: Environ` are
  memoized fields.
- Line 1628: `init` sets `environ_initialized = options.environ.block.isEmpty()`.
  If a non-empty env block is passed (the normal case for a test binary
  started with an inherited env), `environ_initialized = false`.
- Line 14802: `scanEnviron` checks `if (t.environ_initialized) return;`
  then `t.environ_initialized = true;` — first call reads libc env
  and caches it; subsequent calls are no-ops.
- Line 14947-14948: `processSpawnPosix` calls `t.scanEnviron(); // for PATH`
  to get the PATH for `argv[0]` resolution. If the cache is from
  before your `setenv`, you get the stale value.
- Line 14937: `t.environ.process_environ.createPosixBlock(...)` — the
  env block passed to the child is built from the Io's cached env,
  not from the libc env at spawn time.

## The fix (for production code)

There is no public API to re-scan or invalidate the cache. Options:

1. **Set env BEFORE the Io is constructed.** If the test or production
   code can set the env at process startup (before `std.Io.Threaded.init`),
   the Io will see the correct values. This works for:
   - Production: env is set by the user's shell.
   - Tests: env is set in the shell before `zig build test` is invoked.

2. **Pass `environ_map` to the spawn.** The scheduler in
   `src/ai_workflow/tui/routines/Scheduler.zig` does NOT pass it. The
   child gets the Io's cached env. To use this approach, the scheduler
   would need to take an `environ_map` parameter and pass it through.

3. **Use raw syscalls to spawn.** The test (or production code) can use
   `std.os.linux.fork` + `std.os.linux.execve` with a custom env block,
   bypassing the Io entirely. This works but is platform-specific.

## The fix (for test code)

For tests that need to spawn sub-processes with specific env:
- The test must be invoked with the env set at the shell level:
  `env FOO=bar PATH="$PATH:zig-out/bin" zig build test`
- The Io sees the env at startup, caches it, and the sub-process gets
  the right env.
- The test code itself cannot modify the env effectively.

## The test pattern (used in `scheduler_test.zig` Task 3.3)

The integration test in `src/ai_workflow/tui/routines/scheduler_test.zig`
documents this limitation in its header comment. It checks the prereqs
at runtime and returns a `TestPrereqMissingXxx` error if the env isn't
set correctly. The prereqs are:
- `PATH` includes `zig-out/bin` (so the kernel can find the binary)
- `HOME` points to a writable temp dir (so the sub-process creates
  the test DB at the right location)
- `ROUTINE_FIRE_TEST_SKIP_LLM=1` (so fire.zig short-circuits the LLM emit)

Without these, the test fails (expected behavior — the user must set them
at the shell level).

## When this bites

- Any test that spawns a sub-process and needs the sub-process to see
  a specific env (different from the test's startup env).
- Any production code that wants to dynamically change the env (e.g.,
  per-request env) and have the sub-process see the change.
- The scheduler's `spawnDueRoutines` in `src/ai_workflow/tui/routines/Scheduler.zig`
  can NOT be reused in tests where the sub-process needs a custom env.
  A new `Scheduler.startWithEnv(allocator, db, io, env_map)` would be
  needed (out of scope for the current task).

## How to verify

If a test's sub-process fails to spawn, write a quick standalone test
that calls `std.process.spawn` directly and prints the sub-process's
exit code. If the spawn succeeds and the sub-process exits non-zero,
the issue is the sub-process's logic. If the spawn itself fails, the
issue is the Io's env cache.
