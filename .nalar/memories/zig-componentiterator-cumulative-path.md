# nalar — `std.fs.path.componentIterator` yields cumulative `.path` (cumulative, not per-segment)

Zig 0.16's `std.fs.path.componentIterator` (in `std/fs/path.zig:1927`) yields
`Component { .name, .path }` per iter. The two fields are NOT the same:

- `component.name` — JUST the current segment (e.g. `"b"`)
- `component.path` — the CUMULATIVE path-so-far (e.g. `"/a/b"` when iterating
  over `"/a/b/c"` and on the second component)

Verified via `std/fs/path.zig:2140-2180` (POSIX test cases):

```
path = "/a/b/c/"
  next() #1: .name="a", .path="/a"
  next() #2: .name="b", .path="/a/b"
  next() #3: .name="c", .path="/a/b/c"
```

## Symptom

You write a `mkdir -p` walk that hand-rolls the slash-join:

```zig
var iter = std.fs.path.componentIterator(parent_dir);
var accum_buf: [std.fs.max_path_bytes]u8 = undefined;
var accum_len: usize = 0;
while (iter.next()) |component| {
    if (accum_len + 1 + component.path.len > accum_buf.len) return error.PathTooLong;
    if (accum_len > 0) {
        accum_buf[accum_len] = '/';
        accum_len += 1;
    }
    @memcpy(accum_buf[accum_len..][0..component.path.len], component.path);  // ← BUG
    accum_len += component.path.len;
    ...
}
```

For `parent_dir = "/tmp/foo"`, the loop produces:
- iter 1: append `/` (because accum_len=0 — but the `> 0` guard skips this); copy `"tmp"` → `accum_buf = "tmp"`. mkdirat(`"tmp"`). **Fails** — relative to cwd, not to `/`.
- iter 2: append `/` (accum_len=3>0); copy `"foo"` → `accum_buf = "tmp/foo"`. mkdirat(`"tmp/foo"`). **Fails** — still relative to cwd.

Result: a `mkdir -p` for `parent = "/home/x/.local/share/nalar"` fails because
the path gets resolved relative to the user's shell cwd, not as an absolute
path. With the smoke test isolating `$HOME` to a fresh tmpdir, the daemon
fails with `ENOENT` on the very first mkdir.

A second variant of the bug — the one I actually hit — uses `component.path`
thinking it's the new segment:

```zig
while (iter.next()) |component| {
    @memcpy(accum_buf[accum_len..][0..component.path.len], component.path);
    // ↑ iter 2 copies "/tmp/foo" OVER what was already there, plus the
    //   leading "/" we already prepended → "//tmp//tmp/foo" — double slash
    //   and the cumulative path replaces itself.
}
```

## Fix (use `.path` directly)

`.path` is ALREADY the cumulative absolute path. Use it verbatim:

```zig
var iter = std.fs.path.componentIterator(parent_dir);
while (iter.next()) |component| {
    var prefix_z: [std.fs.max_path_bytes:0]u8 = undefined;
    if (component.path.len >= prefix_z.len) return error.PathTooLong;
    @memcpy(prefix_z[0..component.path.len], component.path);
    prefix_z[component.path.len] = 0;
    const rc = std.os.linux.mkdirat(std.os.linux.AT.FDCWD, &prefix_z, 0o755);
    if (rc > std.math.maxInt(i32)) {
        const err = std.os.linux.errno(rc);
        if (err != .EXIST) return error.MkdirFailed;
    }
}
```

This is the right pattern for `mkdir -p` on POSIX. The first iter is the
shortest prefix (e.g. `/tmp`), and each subsequent iter is one component
deeper. `mkdirat(2)` with `AT_FDCWD` handles absolute paths correctly because
`component.path` starts with `/` when the input is absolute.

## When this bites

- Any `mkdir -p` implementation in Zig 0.16 (replacement for
  `std.fs.path.dirname` + `makePath` style APIs).
- Any path-component walk where you need the cumulative prefix for each
  mkdir/open/readdir (cache the parent, stat a subdir, etc.).
- Cross-iteration accumulation where you'd otherwise need a separate
  `StringBuilder` or `ArrayList(u8)`. Use `component.path` and skip the
  manual concat entirely.

## How to verify

```bash
# Direct test (assuming you have a smoke test):
env -i HOME=$(mktemp -d) ./zig-out/bin/nalar service start --port 18080
test -f $HOME/.local/state/nalar/state.json && echo "OK: mkdir-p works"
```

The pre-fix behavior: `error: service start: OpenLogFailed` because
the parent of the log file doesn't exist AND mkdirat's path was resolved
relative to cwd, not $HOME.

The post-fix behavior: state.json appears within 2s of the service start,
the daemon's `~/.local/share/nalar/service.log` is created, and the
smoke test's 5 steps all pass.

## Reference fix in this repo

- `src/daemon.zig:79-95` — `pub fn mkdirP` extracted as a unit-testable helper
- `src/state_file.zig:135-152` — inline mkdir-p walk in `writeStateFile`
  (could be deduped by calling `daemon.mkdirP` but kept inline to avoid a
  cross-module dependency from `ai_workflow/tui/state_file.zig` to
  `ai_workflow/tui/daemon.zig` which would be circular in some build
  configurations)

## Real example in this repo

This memory was written while fixing the daemon's `redirectStdioToLog` bug
that surfaced via `scripts/service-lifecycle-smoke.sh` Step 2 failing
with "state.json not written" against a fresh `$HOME`. The bug went
through three iterations:
1. Naive `iter.next().?.path` joined to nothing → `mkdirat("tmp")` (relative)
2. Manually prepended `/` to accum_buf → `mkdirat("//tmp//tmp/foo")` (double slash)
3. Realized `component.path` is ALREADY cumulative → just use it directly

Lesson: when a stdlib API has TWO semantically similar fields (`.name` vs
`.path`), READ THE TEST CASES in the stdlib source. The 100-line test
block at `std/fs/path.zig:2105-2200` answers the question definitively.
