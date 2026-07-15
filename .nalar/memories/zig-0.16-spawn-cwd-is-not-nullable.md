# Zig 0.16 — `std.process.spawn` `.cwd` field is `process.Child.Cwd` union, NOT nullable

In Zig 0.16, `std.process.spawn(io, options)`'s `.cwd` field requires a
`process.Child.Cwd` tagged-union value. The three valid variants are:

```zig
pub const Cwd = union(enum) {
    /// CWD of the child is the same as the current CWD.
    inherit,
    /// On POSIX systems, `fchdir` is called after `fork` using this handle.
    dir: Io.Dir,
    /// On POSIX systems, `chdir` is called after `fork` using this path.
    path: []const u8,
};
```

**`null` is NOT a valid value** — the field's type is `Cwd`, not `?Cwd`.
This is a compile error:

```
src/.../file.zig:NN:NN: error: expected type 'process.Child.Cwd',
                                   found '@TypeOf(null)'
        .cwd = null,
              ~~~~
```

## Symptom

`zig build test` passes (so the CI green-light goes red AFTER merge), then
`zig build install:<target>` (or any `addExecutable` step) fails with the
error above. The test target's module graph did NOT import the spawn call
site (it only reaches the public API), so the broken line was never
type-checked. The production binary compile is what catches it.

## Common cases

| Intent                              | Correct `.cwd = `              |
|-------------------------------------|---------------------------------|
| "use the parent's cwd"              | `.inherit`                     |
| "chdir to an absolute path"         | `.{ .path = "/abs/path" }`     |
| "fchdir to a Dir handle"            | `.{ .dir = someIoDir }`        |
| "I have no idea, just default"      | OMIT the `.cwd = ` line entirely (defaults to `.inherit`) |

`null` is never correct.

## When This Bites

- Porting spawn code from older Zig (0.10, 0.11, 0.12, 0.13, 0.14, 0.15) where
  `.cwd` was a `?[]const u8` (nullable path string). In 0.16 the
  `?[]const u8` shape is gone — `null` no longer means "default to inherit".
- Copying a spawn snippet from a tool that DID set `.cwd = .{ .path = ... }`
  and writing `.cwd = null` in a different function "because we don't need
  a specific cwd". The intent is `.cwd = .inherit` (or just omit the line).
- The other fields (`stdin`, `stdout`, `stderr`) DO take nullable
  `.pipe = null` in some stdlib versions — `.cwd` does NOT follow the same
  pattern in 0.16.

## Why `zig build test` didn't catch it (in this project)

In nalar, the test target (`addTest("test", ...)`) compiles a SEPARATE
module graph rooted at the test runner. The test file imports the
production code's PUBLIC API, but Zig's lazy analysis may not pull in
private helpers that aren't transitively reachable from a tested
function. Spawn calls in private `runGit*` helpers (not exercised by
the test's public-API calls) can sit un-type-checked in the test build
but still appear in the `addExecutable` build (which compiles the full
`src/main.zig` → `nalarcore` graph).

## How to verify after a fix

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
timeout 180 zig build install:linux:system 2>&1 | tail -n 15
# Expected: 4/6 steps succeed. The 5th is the cp /usr/local/bin/nalar
# which fails harmlessly with permission denied.
# If you see "compile exe nalar" → 1 errors, the cwd bug is back.
```

## Related: the other Zig 0.16 spawn API gotchas

- `child.kill(io)` returns `void` (not `Term`) AND asserts
  `child.id == null` after returning. You cannot call `child.wait(io)`
  after a successful `kill(io)`.
- `std.process.spawn(io, options)` takes `io: Io` as the FIRST argument
  (not allocator). The `Child` struct has no `.allocator` field.
- See global memory `zig-0.15-process-spawn-api.md` for the 0.15 baseline
  (which DOES allow `?[]const u8` for cwd and returns `Term` from `kill`).
</content>
</invoke>