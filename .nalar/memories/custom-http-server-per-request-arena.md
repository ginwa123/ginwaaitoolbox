# nalar — Custom HTTP server uses per-request arena allocator

`GinwaServer` in `src/modules/custom_http_server/src/http_server.zig` gives every
HTTP request its own `std.heap.ArenaAllocator` built on top of the server's
long-lived allocator. The arena is `.deinit()`'d by `GinwaServer.handle`
when the request finishes, so **every allocation made with the request's
`ctx.allocator` is automatically freed** — no explicit `defer` needed.

## Symptom

A code review (or your own diff) flags a handler for adding unnecessary
`defer parsed.deinit()`, `defer allocator.free(...)`, or
`defer some_arena_allocator.deinit()` calls on data that lives only for
the duration of the request. These are dead code — the arena owns the
memory, the request owns the arena, and `handle` tears it down.

## Why

Look at `src/modules/custom_http_server/src/http_server.zig`:

- Line ~164: `const arena = self.allocator.create(std.heap.ArenaAllocator) ...`
- Line ~168: `arena.* = std.heap.ArenaAllocator.init(self.allocator);`
- Line ~173: `fn handle(server: *GinwaServer, arena_allocator: *std.heap.ArenaAllocator, fd: i32) void {`
- Line ~175: `arena_allocator.deinit();` ← frees ALL request allocations
- Line ~176: `server.allocator.destroy(arena_allocator);`

The per-request `ctx.allocator` exposed to handlers is
`arena_allocator.allocator()` (line ~179). Every `try allocator.alloc(...)`,
`try allocator.dupe(...)`, `try allocator.create(...)` made during the
handler returns memory from the arena. The arena owns it; the request
owns the arena; `handle` destroys the arena on return. The leak detector
in tests (if any) is satisfied because each test request gets its own
arena.

## Fix

In HTTP handlers, **don't add `defer ... .deinit()` or `defer ... .free(...)`
for request-scoped allocations**. The arena does it. Just let the
allocations go out of scope and trust the runtime cleanup.

```zig
pub fn myHandler(ctx: HttpContext, ...) !HttpResponse {
    const allocator = ctx.allocator;  // ← per-request arena; freed by GinwaServer.handle

    // OK — no defer needed
    const parsed = try std.json.parseFromSlice(MyStruct, allocator, body, .{});

    // OK — no defer needed
    const buf = try allocator.alloc(u8, 1024);

    // OK — no defer needed
    const typed = try allocator.create(MyType);
    typed.* = ...;

    return res.jsonResponse(...);
}
```

**Exception — when NOT to skip the defer:**

- Allocations on a different allocator than `ctx.allocator` (e.g. a
  shared `di.allocator` that lives across requests) DO need explicit
  cleanup.
- The `defer errdefer allocator.free(out)` pattern for transient
  scratch buffers inside a `blk:` is still fine — that frees on error
  during construction, not at the end of the request.
- The `errdefer` cleanup for partial-init structs is also fine.

## When This Bites

- Adding a `defer` to "be safe" in a new HTTP handler, especially after
  refactoring config / state that previously had no defer.
- Following the convention from a different codebase or the Zig stdlib
  examples — Zig's `std.json.parseFromSlice` returns a `Parsed(T)` that
  the docs say you must `deinit()`, but in nalar's HTTP handlers that's
  the arena's job.
- Adding a `defer` because another handler in the same project has one
  (the codebase is inconsistent on this — 3 handlers DO have
  `defer parsed.deinit()`, the rest don't; the convention is "don't").

## How to verify

If you've added a `defer` in an HTTP handler under
`src/ai_workflow/tui/http_handlers/`, ask: is the deferred thing
allocated from `ctx.allocator`? If yes, the defer is dead code —
remove it. The arena in `GinwaServer.handle` reaps it.

For non-arena-owned memory (e.g. `di.allocator`), keep the defer.
For transient scratch inside a `blk:` / error path, keep the
`errdefer`.
