# Zig 0.15 — Process Spawn API (std.process.spawn)

In Zig 0.15 the old `std.process.Child.init(argv, allocator)` + `child.spawn()` pattern is **gone**. There is no `init` and no `spawn` method on the `Child` struct.

## The new API

```zig
// Spawn a process. Returns the Child; you do NOT call .wait() for fire-and-forget.
const child = std.process.spawn(io, .{
    .argv = argv,
    .stdin = .ignore,   // or .inherit, .file, .pipe, .close
    .stdout = .ignore,
    .stderr = .ignore,
    .cwd = .inherit,    // or Child.Cwd.dir/.path
    .expand_arg0 = .no_expand,
}) catch |err| { ... };

// wait blocks until the child terminates — DO NOT call this if you
// want fire-and-forget (the OS reaps the child when it exits).
const term = child.wait(io);
```

Key changes from the old API:
- The `io: std.Io` parameter is now mandatory (replaces the implicit global).
- `stdin`/`stdout`/`stderr` are `StdIo` tagged unions, not the old `*Pipe`/`Ignore` enums.
- `Child.init` is gone — the spawn call IS the constructor.
- `child.wait(io)` blocks (don't call for fire-and-forget).

## Common error: ignoring the return value

```zig
std.process.spawn(io, opts) catch return error.BinaryNotFound;
```

This will fail to compile with "value of type 'process.Child' ignored". You MUST bind the result:

```zig
const child = std.process.spawn(io, opts) catch return error.BinaryNotFound;
if (child.id == null) return error.BinaryNotFound;  // touch it so compiler doesn't warn
```

## Error variants

`SpawnError` includes `FileNotFound`, `PermissionDenied`, `AccessDenied`, `IsDir`, `OutOfMemory`, etc. Treat any of them as "spawn failed" — collapse into a single error in your wrapper.

## Fire-and-forget pattern

For short-lived child processes (notification daemons, build commands) where the parent doesn't need to wait:

```zig
const child = std.process.spawn(io, .{
    .argv = argv,
    .stdin = .ignore,
    .stdout = .ignore,
    .stderr = .ignore,
}) catch return error.BinaryNotFound;

// Don't call child.wait(io). The OS reaps the child when it exits.
// The parent's process table holds the zombie briefly; this is
// acceptable for short-lived children.
```

The compiler may still warn about an unused `child` variable. Two options:
1. `if (child.id == null) ...` to touch it
2. `_ = child;` to explicitly discard

The check-`child.id` pattern is preferred because it documents the fire-and-forget intent.

## When This Bites

- Any new code that spawns subprocesses.
- Porting code from older Zig (0.10, 0.11, 0.12) to 0.15+.
- The `init` pattern still appears in older code in the same project — don't copy it.

## How to verify

If your code calls `std.process.Child.init`, the Zig 0.15 compiler will say: "no member named 'init' in struct 'process.Child'". Fix by using `std.process.spawn(io, options)` instead.
