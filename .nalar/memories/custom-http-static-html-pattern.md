# custom_http_server — static HTML landing page pattern

## What

`GET /` in `src/modules/custom_http_server/src/main.zig` serves a
real HTML page (~9 KB) compiled into the binary as a comptime string
constant `LANDING_PAGE_HTML`. The page documents every endpoint with
curl examples and includes a live SSE demo via the browser's
`EventSource` API.

## Why

The previous root returned plain text `ID: 100` — a placeholder that
didn't show off what the server actually does. A real HTML page with
inline CSS/JS demoing every feature is a far better developer
experience.

## The pattern (4 things, in order)

### 1. Comptime string constant

```zig
const LANDING_PAGE_HTML =
    \\<!doctype html>
    \\<html lang="en">
    \\... (use \\\\ to escape backslashes in JS regex literals)
    \\</html>
;
```

Lives in rodata. No on-disk file to ship alongside the binary.

### 2. Arena-dup, don't alias

```zig
fn landingPageHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    _ = req;
    const body = ctx.allocator.dupe(u8, LANDING_PAGE_HTML) catch {
        return gserverz.response.internalError("Failed to allocate", ctx.allocator);
    };
    var out = res.withBody(body);
    out.headers.put("Content-Type", "text/html; charset=utf-8") catch {
        return gserverz.response.internalError("Failed to set Content-Type", ctx.allocator);
    };
    return out;
}
```

`ctx.allocator` is the per-request arena (reaped by GinwaServer.handle
on response). The dup is request-scoped; the const lives in rodata.

### 3. Set Content-Type explicitly

`withBody` only sets `Content-Length`. Without an explicit
`Content-Type: text/html; charset=utf-8`, browsers may sniff and fall
back to plain-text rendering. The `withJson` helper does set
`Content-Type` automatically — but `withBody` does not.

### 4. Register on the router

```zig
try gs.router.get("/", landingPageHandler);
```

Replaces the previous `indexHandler` (which returned plain text).

## Pitfalls (cross-platform + Zig 0.16)

### `std.fs.cwd()` was removed in Zig 0.16

In tests that read source files for static-contract assertions, use:

```zig
const std = @import("std");

fn readMainSource(allocator: std.mem.Allocator) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "src/main.zig",  // path RELATIVE TO THE BUILD INVOCATION CWD
        allocator,
        .limited(1 << 20),
    );
}
```

NOT `std.fs.cwd().openFile(...)` (removed).

### `std.c.fseek` / `std.c.ftell` are NOT in Zig 0.16's std.c

If you go the libc route instead, declare both as module-scope
`extern "c" fn` (Zig 0.16 forbids `extern "c"` inside function
bodies). Use the `Clong` alias for `long`:

```zig
const Clong = if (@bitSizeOf(usize) == 64 and @import("builtin").os.tag != .windows)
    i64
else
    i32;

extern "c" fn fseek(stream: *std.c.FILE, offset: Clong, whence: c_int) c_int;
extern "c" fn ftell(stream: *std.c.FILE) Clong;
```

The `Io.Dir.cwd().readFileAlloc` path is preferred over the libc
path — fewer moving parts, no `Clong` / `SEEK_END` / `SEEK_SET` literals.

### The test binary's cwd is the BUILD invocation directory, not the source dir

When `zig build test` runs from
`src/modules/custom_http_server/`, the test binary's cwd is that
directory. So `"src/main.zig"` is the correct relative path from the
test binary's perspective — NOT `"main.zig"`.

If you see `error.FileNotFound` from `readFileAlloc` in all your
tests but the source file is right there, the path is wrong. Drop
into the test's cwd to introspect:

```bash
cd /home/ginwa/.../src/modules/custom_http_server
ls .zig-cache/o/<hash>/test 2>/dev/null
cd .zig-cache/o/<hash>/ && ls -la  # ← this is the test binary's cwd
```

### Cross-compile verification (Windows + macOS)

The `zig build` step in `src/modules/custom_http_server/build.zig`
only builds for the host. To verify the code compiles for every
target (Linux/macOS/Windows), use `zig build-obj` with a tiny stub
in the same directory as `main.zig`:

```bash
# /tmp/cross_test.zig — lives in src/ so @import("main.zig") resolves
cat > src/test_mod_cross.zig <<'EOF'
const m = @import("main.zig");
pub fn main() void { _ = m; }
EOF

# Windows
cd src/modules/custom_http_server/src/
zig build-obj -fno-emit-bin -target x86_64-windows-gnu -lc \
    -Mroot=test_mod_cross.zig

# macOS
zig build-obj -fno-emit-bin -target aarch64-macos -lc \
    -Mroot=test_mod_cross.zig

# Cleanup
rm test_mod_cross.zig
```

Both must exit 0 — no actual binary is produced (`-fno-emit-bin`),
just type-check. Don't commit the stub file.

## Static-contract test pattern

`src/main_static_html_test.zig` adds 8 tests that grep `main.zig`
for required substrings (constant name, function name, route
registration, Content-Type header, doctype, required endpoint paths
in the HTML table, EventSource demo). Each test has a unique error
name so a failure points to the exact contract violated.

The test file uses `std.Io.Dir.cwd().readFileAlloc(std.testing.io, ...)`
to read `main.zig` from the test binary's cwd.

## Verification

```bash
cd /home/ginwa/ginwaaitoolbox/.worktrees/custom-http-static-html/src/modules/custom_http_server
timeout 120 zig build test --summary all
# Build Summary: 3/3 steps succeeded; 173/173 tests passed

# Build the binary
rm -rf zig-out
timeout 180 zig build install
# ls -la zig-out/bin/custom_http_server  # 17 MB

# Smoke (port 29590 — NOT the 8081 nalar port)
nohup zig-out/bin/custom_http_server </dev/null > /tmp/srv.log 2>&1 &
disown 2>/dev/null
sleep 2
curl -sS -i http://127.0.0.1:29590/ | head -n 6
# HTTP/1.1 200 OK
# Server: Server/1.0
# Connection: close
# Content-Type: text/html; charset=utf-8
# Content-Length: 8904

# Cleanup
pkill -f custom_http_server
```

Cross-compile is clean for `x86_64-windows-gnu` and `aarch64-macos`
(proven via `zig build-obj -fno-emit-bin`).

## Reference

- Commit: `d554a95a feat(custom-http-server): serve static HTML landing page at GET /`
- Branch: `worktree/custom-http-static-html`
- Files: `main.zig`, `main_static_html_test.zig`, `test_runner.zig`, `README.md`
- Tests: 173/173 pass (was 165 + 8 new static-contract tests)
