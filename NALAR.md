Nalar AI agent backend (Zig 0.16) with Vue 3 desktop app. See `.nalar/memories/` for detailed patterns and `~/.config/nalar/memories/` for cross-project lessons.

## Memories

Detailed patterns live in:
- Local: `.nalar/memories/` (project-specific: backend, frontend, data, infra)
- Global: `~/.config/nalar/memories/` (cross-project: Zig stdlib, Vue 3 patterns, SQLite gotchas)

## Language & Environment Facts

<!-- Known API changes, syntax rules, and environment behaviors for this codebase. -->
<!-- Format: - [lang@version] <fact in one sentence> -->

- [zig@0.16] **CRITICAL: `std.Io.Threaded` does NOT honor user-space deadlines on blocking socket reads** — when a worker thread is parked in `recv()` waiting for data, the main thread's deadline check is dead code. The worker only unblocks when the kernel returns (RST/FIN/error/timeout). To enforce a read deadline on a TCP stream, you MUST set `SO_RCVTIMEO` on the underlying socket fd, OR drive the Io's `select`/`async` with a timeout. Symptom: an "idle timeout" loop never fires when the server stalls without sending RST/FIN. See `src/modules/agent/Agent.zig` callStreaming read loop and the SKIP comment in `call_streaming_test.zig` for the live example.
- [zig@0.16] `std.Thread.Mutex` does NOT exist — `std.Thread` only exposes spawn/join/detach APIs. For a mutex in a `std.Thread.spawn`'d worker, use `std.atomic.Mutex` (a lock-free `enum(u8) { unlocked, locked }` with `tryLock() bool` and `unlock() void`) as a spinlock with `while (!m.tryLock()) std.atomic.spinLoopHint()`. For mutexes held by Io-runtime code, use `std.Io.Mutex` (lock takes `io: Io`). The critical section must be small (a few hundred ns) for the spinlock to be acceptable.
- [zig@0.16] **`std.process.spawn` takes `io: Io` as first arg** (not allocator). Signature: `spawn(io: Io, options: SpawnOptions) SpawnError!Child`. The `Child` struct has no `.allocator` field — its handle is owned by the Io runtime. Forgetting `io` and passing an allocator is a common mistake (the allocator will be treated as an Io and the type check fails).
- [zig@0.16] **`std.process.Child.kill(child, io)` is the all-in-one "terminate + wait + cleanup"** — it sends SIGTERM (or Windows equivalent), blocks until the child exits, sets `child.id = null`, and reaps. You MUST NOT call `child.wait(io)` after `kill(io)` because `wait` asserts `child.id != null` and will panic. There is no "kill but don't wait" API in 0.16.
- [zig@0.16] **Zig 0.16 has no public `std.posix.socket/bind/listen/accept/connect/recv/send/close`** — they live in `std.os.linux.*` (or `.windows.*`, `.darwin.*`) and return a raw `usize` (success value on success, `-errno` cast to `usize` on failure). Check return against `std.math.maxInt(i32)` to detect errors, then `@intCast` to `i32` for the fd. The `errno()` helper inside `posix.zig` is private.
- [desktop-app] `nalar-desktop` is the new native webview wrapper at `src/apps/desktop_app/`. It spawns `nalar` as a child process and opens a native webview window (WebKitGTK 4.1 on Linux via manual `extern "c"` + C shim at `platform/webview_linux.c`, WKWebView on macOS via Objective-C++ shim at `platform/macos/nalar_webview.mm`, WebView2 on Windows via C++ shim at `platform/windows/nalar_webview.cpp`). Build: `zig build nalar-desktop`. The Vue webapp is embedded as comptime bytes via the codegen step `zig build codegen:webapp-assets` (which depends on `zig build build:webapp` to run `bun run build` first). Runtime startup: extract assets to `$XDG_RUNTIME_DIR/nalar-desktop-webapp-<pid>/`, spawn `nalar --port <port> --static-dir <webapp-dir>`, wait for `/api/health`, open the webview at `http://127.0.0.1:<port>/`. 21/21 unit tests pass via `zig build test:desktop-app`. The output binary is ~29 MB (includes 4.7 MB of embedded webapp assets + the 17 MB nalarcore link).

# Mandatory
- Dont ever kill the process port 8081 or process nalar !!!
- If you want to test use process port 8080 and process nalar !!!
- When create a test make sure its work on platform linux, mac and windows
