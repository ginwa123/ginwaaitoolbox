# nalar — HTTP Handler Thin-Wrapper Pattern (for CRUD endpoints)

When adding a new thin-wrapper HTTP handler in `src/ai_workflow/tui/http_handlers/`
that delegates to a helper in `src/modules/agent/tools/*.zig`, the project's
established conventions are:

## 1. Use `req.params.get("name")`, NOT `req.path_params.get("name")`

The plan's draft often shows `req.path_params` but the actual `HttpRequest`
struct (in `src/modules/custom_http_server/src/http_parser.zig:69`) has
`params: std.StringHashMap([]const u8)`. The `path_params` form does NOT
exist and will produce a compile error.

## 2. Use `std.json.parseFromSliceLeaky`, NOT `std.json.parseFromSlice`

`parseFromSlice` returns a `Parsed(T)` wrapper that owns an internal
ArenaAllocator and requires explicit `deinit()`. The per-request
`ctx.allocator` IS an arena (see project memory
`custom-http-server-per-request-arena`) and reaps everything at request
end, so the Leaky variant is correct. The non-Leaky variant is wrong
here because the internal arena it creates would leak (the per-request
arena doesn't know to clean it up).

```zig
// Correct (this codebase):
const parsed = std.json.parseFromSliceLeaky(MyBody, allocator, req.body, .{}) catch {
    return res.jsonResponse(.{ .status_code = 400, .data = "..." });
};
// parsed.name, parsed.foo, etc. directly — no .value accessor

// Wrong:
const parsed = std.json.parseFromSlice(MyBody, allocator, req.body, .{}) catch { ... };
const name = parsed.value.name;  // ← requires .value, not parsed.name
```

The existing precedent: `task_create.zig:44`, `task_update.zig:49`,
`session_create.zig:69`, `session_update.zig:41` all use `Leaky`.

## 3. Response shape: typed struct + `std.json.Stringify.valueAlloc`

Hand-rolled `std.fmt.allocPrint` does NOT escape quotes/backslashes in
user-provided content (e.g. memory file body, prompt text, etc.).
Use the typed struct pattern with `valueAlloc` (which calls
`std.json.Stringify` and handles all escaping):

```zig
const MyResponse = struct {
    my_field: ?MyPayload = null,
    error_message: ?[]const u8 = null,
};

return res.jsonResponse(.{
    .status_code = 200,
    .data = try std.json.Stringify.valueAlloc(allocator, MyResponse{ .my_field = payload }, .{}),
});
```

The `?T = null` fields are necessary so `valueAlloc` can produce
`{"my_field":null,"error_message":null}` for the error case.

The previous handlers (e.g. `task_create.zig:121`, `workspace_items_create.zig`)
DO use hand-rolled `std.fmt.allocPrint` for simple response shapes that
don't contain user-provided content (status strings, task IDs). That
pattern is fine for `{"id":"task_123","success":true}` style responses
where every field is a known-safe system value. It's NOT fine for
response bodies that include free-form text (memory content, prompt
text, commit message, etc.).

## 4. Static-contract test pattern (NOT behavioral)

The project does NOT have a handler test infrastructure that stands up
a real `GinwaServer` + `nalarcore` singleton + Io runtime + SQLite
DB + `*const std.process.Environ.Map` for behavioral tests. The
established pattern is **static source-check tests** that read the
handler source file as text and grep for required substrings.

Pattern (see `src/ai_workflow/tui/http_handlers/routines_run_test.zig`
and `src/ai_workflow/tui/http_handlers/task_create_routines_test.zig`):

```zig
const HANDLER_PATH = "src/ai_workflow/tui/http_handlers/my_handler.zig";

test "my handler uses parseFromSliceLeaky" {
    const source = try readSource(testing.allocator, HANDLER_PATH);
    defer testing.allocator.free(source);
    if (std.mem.indexOf(u8, source, "parseFromSliceLeaky") == null) {
        std.debug.print("!! my_handler.zig does not use parseFromSliceLeaky !!\n", .{});
        return error.ParseFromSliceLeakyMissing;
    }
}
```

The test is named with the contract ("uses valueAlloc", "calls memoryExists",
"validates the name"). The error names are the contract violations
(`error.ValueAllocMissing`, `error.MemoryExistsCallMissing`, etc.) —
that way a test failure points at WHICH contract broke.

**Register every new test file** in
`src/ai_workflow/tui/test_runner.zig` with
`_ = @import("http_handlers/my_test.zig");`. Without that line the
test is compiled but never executed, and the count stays at the
pre-addition baseline.

## 5. Manual smoke test on port 8080 (NOT 8081)

The project's MANDATORY rule: another `nalar` process is always
running on port 8081. NEVER kill it, NEVER use it for new work.
Use port 8080 for any local smoke testing.

`zig build run` depends on `install` which depends on
`install:nalar-desktop` which depends on `codegen_webapp_assets`
which is broken on this branch (pre-existing — `std.fs.cwd()` is
gone in Zig 0.16, but `tools/codegen_webapp_assets.zig` still uses
it). The `run` step therefore fails.

Workaround for getting a runnable `zig-out/bin/nalar`:
`zig build install:linux:system` — this builds the nalar binary
for the native target and tries to copy it to `/usr/local/bin/nalar`
(permission denied as a non-root user, but the binary IS at
`zig-out/bin/nalar` before the cp step fails). Then run
`./zig-out/bin/nalar --port 8080` directly.

## 6. Status code conventions

- **200 OK** — GET, PUT, DELETE success
- **201 Created** — POST that creates a new resource
- **400 Bad Request** — invalid name, missing body, bad JSON, helper failure
- **404 Not Found** — GET/PUT on a missing resource
- **409 Conflict** — POST on a duplicate resource

Idempotent delete: `deleteMemoryFile` returns true for "deleted" AND
"was already missing", so the DELETE handler always returns 200 with
`{success:true,name:"..."}` on a valid name.

## When this bites

- Adding a new CRUD handler in any of the http_handlers/* files.
- Any new POST/PUT endpoint that needs to parse a JSON body.
- Any new endpoint that needs to return user-provided text in the
  response body (memory content, prompt text, etc.) — use valueAlloc.
- Refactoring `parseFromSlice` → `parseFromSliceLeaky` (or vice versa)
  in any existing handler — the project uses Leaky for per-request
  arena allocators.

## How to verify

After any new handler:

1. `timeout 180 zig build test --summary all 2>&1 | tail -n 5` — must
   show `test success` and the new test count (476 → 500 with the
   memories_crud_test.zig work).
2. `zig build install:linux:system` (builds the binary; the cp at
   the end fails harmlessly on permission).
3. `./zig-out/bin/nalar --port 8080 &` (in a script with `exec` to
   avoid `kill` issues with the self-kill protection).
4. `curl -X POST http://127.0.0.1:8080/api/...` (and the 4 other
   verbs) to verify the routes are wired correctly.
5. `kill <pid>` (NEVER `pkill -f "zig build run"` — that pattern
   would also catch the nalar on 8081 if you ever change flags).
