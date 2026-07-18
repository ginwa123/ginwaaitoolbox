# Zig — language-level quirks and gotchas

This file consolidates Zig language-level gotchas (non-version-specific where possible). For Zig 0.16 stdlib API changes, see `zig-0.16-stdlib-changes.md`. For SQLite-specific patterns, see `zig-sqlite-patterns.md`. For build/test patterns, see `zig-build-and-test.md`.

---

## Anonymous structs in different positions are distinct types

Two anonymous structs (e.g., `struct { id: []const u8, name: []const u8 }`) declared in different scopes are **distinct, non-coercible types** even with identical fields. `anytype` doesn't help — it requires exact type match.

**Symptom:** `error: expected type '[]const WorkspaceSeed__struct_...', found '*[N]test.SomeTest__struct_...'` — same fields, different types.

**Fix:** Hoist the inner anonymous struct to a top-level named struct:

```zig
const ItemSeed = struct {
    id: []const u8,
    item_type: []const u8 = "chat",
    path: []const u8,
    name: []const u8 = "",
};

const WorkspaceSeed = struct {
    items: []const ItemSeed,
    tasks: []const TaskSeed,
};
```

**Related:** `anytype` helpers that call methods taking `*T` on a field need explicit pointer parameter:
```zig
fn seedWorkspace(db: *sqlite.SqliteBackend, alloc, seed) !void {
    try db.exec(alloc, ...);  // takes *SqliteBackend, not anytype
}
```

**When this bites:** `WorkspaceSeed`-style config structs with inline anonymous structs for collection elements; tests building `[N]struct_X` and passing to a helper expecting `[]const struct_Y`.

---

## `catch |err|` narrows the inferred error set BEFORE the catch

When a function body contains `return error.X catch { ... }` patterns that convert transient errors (OutOfMemory, etc.) into domain errors, the inferred error set is the **narrowed set**, not the broadened set. The transient errors are absorbed by the catch arms and never reach the caller.

**Symptom:** `error: 'error.OutOfMemory' not a member of destination error set` even though the function body catches OOM internally.

**Fix options:**

```zig
// Pattern A — match the actual inferred set, no else prong
catch |err| switch (err) {
    error.RoutineCleanupFailed => "Routine cleanup failed",
    error.TaskDeleteFailed => "Task delete failed",
    // ← no else; switch is exhaustive
}

// Pattern B — widen to anyerror (every caller must handle broader set)
pub fn deleteTaskUseCase(...) anyerror!MyOutcome

// Pattern C — explicit error set (most maintainable)
pub const DeleteTaskError = error{
    RoutineCleanupFailed, TaskDeleteFailed,
};
pub fn deleteTaskUseCase(...) DeleteTaskError!MyOutcome
```

**When this bites:** any function body using `catch { return error.X; }`; any caller doing `fn() catch |err| switch (err) { ... }` matching variants the function never propagates. May be missed by `zig build test` due to lazy analysis — see `zig-build-and-test.md`.

---

## `continue` in a `for` loop skips the trailing block in the SAME iteration

`continue` jumps to the next iteration. Code between `continue` and the closing `}` of the iteration body is SKIPPED — including cleanup blocks that the developer expected to always run.

**Symptom:** A trailing `if (!consumed) unconsumed.append(item);` doesn't execute when `is_wildcard(item)` is true and triggers `continue`.

**Fix:**

```zig
// Option A — append BEFORE the continue
if (is_wildcard(item)) {
    unconsumed.append(item);
    continue;
}

// Option B — restructure as if/else
if (!is_wildcard(item)) { ... process ... }
if (!consumed) unconsumed.append(item);
```

**When this bites:** any `for` loop with early-exit `continue` AND trailing cleanup; code reviews reasoning about `continue` semantics assuming "fall through to cleanup".

---

## `defer allocator.free(literal_string)` panics with "Invalid free"

`defer allocator.free(...)` is a HARD ASSERT that the slice is heap-owned. Passing a string literal (`"foo"` — `*const [N:0]u8` to static memory, NOT a fat pointer to heap memory) panics with `Invalid free` in debug builds (canary check fails).

**Symptom:** `thread N panic: Invalid free` at `std/heap/debug_allocator.zig:885` on scope exit of a function that took the literal-fallback path.

**Fix — track ownership explicitly:**

```zig
const sd_field: []const u8 = sd: {
    if (state.static_dir) |sd| {
        const owned = try std.fmt.allocPrint(allocator, "\"{s}\"", .{sd});
        errdefer allocator.free(owned);
        break :sd owned;
    }
    break :sd "null";  // literal — DO NOT free
};
defer if (state.static_dir != null) allocator.free(sd_field);
```

**When this bites:** ternary `if (cond) heap_alloc else "literal"` + unconditional `defer allocator.free(...)` patterns. Common in JSON serialization helpers with `"null"` fallback. Invisible in release-fast (no canary).

---

## `std.debug.print` / `std.fmt.allocPrint` format strings must escape `{` and `}`

The `Writer.print` API uses `{name}` as format specifiers. Literal `{` or `}` in the output must be written as `{{` and `}}`. A `{` followed by a non-identifier character is interpreted as a named-argument format spec — if the field is missing, comptime error `error: too few arguments` from `std/Io/Writer.zig:717`.

**Symptom:** `error: too few arguments` pointing at `std.debug.print` line; the format string contains example Zig code with `&.{...}` or `.{ .name = "x" }`.

**Fix:** Replace literal `{` with `{{`, `}` with `}}`. Alternative: don't include literal braces — describe in prose.

**When this bites:** static-regression-test error messages that include example code (`&.{...}`, `try foo { ... }`).

---

## Function parameters cannot have default values

Zig has NO syntax for default parameter values. `fn buildMessages(..., mode: []const u8 = "")` fails with `error: expected ',' after parameter`.

**Workarounds:**

1. Make all callers pass the value explicitly.
2. Split into a public function (with param) + a wrapper (without):
   ```zig
   pub fn buildMessages(..., mode: []const u8) ![]agent.AgentMessage { ... }
   pub fn buildMessagesDefault(...) ![]agent.AgentMessage {
       return buildMessages(..., "");
   }
   ```
3. Sentinel values + check inside function body.

**When this bites:** any function with a long parameter list where most callers use the same default.

---

## `orelse` between `?[]const u8` and `[]u8` fails to unify

`orelse expr1 orelse expr2` requires both branches to coerce to a single common type. `?[]const u8` + `[]u8` may reject with `error: expected optional type, found '[]u8'`.

**Fix — use a `blk:` block:**

```zig
const effective_item_type: []const u8 = blk: {
    if (item_type_in_body) |v| break :blk v;
    break :blk existing.?.item_type;  // []u8 coerces to []const u8 via block type
};
```

**When this bites:** any `orelse` where one branch is `?T` and the other is plain `T` (or `[]u8` vs `?[]const u8`); HTTP handlers / DB rows where model returns non-optional slices.

---

## `std.fs.path.join` treats every argument as a path component

`std.fs.path.join(allocator, &.{ a, b })` does NOT concatenate `a ++ b`. Both are separate components, joined with `/`. So `path.join(dir, name, ".tmp")` produces `<dir>/<name>/.tmp` (a file named `.tmp` inside `<name>`) — `createFile` returns `error.FileNotFound`.

**Fix — for "suffix on filename" patterns, use `@memcpy`:**

```zig
const tmp_path = allocator.alloc(u8, full_path.len + suffix.len) catch return false;
defer allocator.free(tmp_path);
@memcpy(tmp_path[0..full_path.len], full_path);
@memcpy(tmp_path[full_path.len..][0..suffix.len], suffix);
```

For multi-component paths (genuinely wants `a/b/c`), `path.join` IS the right tool.

**When this bites:** atomic-write helpers (`<path>.tmp`, `*.lock`), any "full path + short marker" pattern.

---

## `std.fmt.bufPrint` returns a slice into the buffer, NOT a new allocation

`bufPrint(buffer, fmt, args)` returns a **slice of the buffer you passed in**, not a heap copy. If you reuse the same buffer across loop iterations and store the returned slices, every iteration's slices alias the same backing memory.

**Symptom:** `thread panic: Invalid free` on `defer for (items) |it| alloc.free(it.id);` when iterations share a buffer.

**Fix:** Use `std.fmt.allocPrint(allocator, ...)` (allocates fresh heap) when storing the result past iteration end. Keep `bufPrint` only for immediate-use strings.

**When this bites:** any test building N rows in a loop with dynamic ids and `defer`-ing per-row cleanup; logger formatters reusing a scratch buffer.

---

## `_ = var;` discard is rejected if var is used later

When a function contains `_ = local_const;` to "document" a value, Zig 0.16 rejects it with `error: pointless discard of local constant` IF the same variable is used again later.

**Fix:** Just remove the `_ = var;` line. The variable's use elsewhere already documents its importance.

**When this bites:** plan specs with `_ = var;` to "acknowledge" a variable exists; long if/else chains with "document" discards in branches that DO use the variable.

---

## Substring matching pitfalls

`std.mem.indexOf` is a literal-byte substring search — it does NOT understand word boundaries, prefixes, or `id:` vs `_id:`. The disambiguated label `_id:` is a substring-superset of `id:` at the byte level.

**Symptom:** Test asserts `indexOf(u8, md, "id: \`task_") == null` but the new label `task_id: \`task_a1\`` contains the substring inside `task_id`.

**Fix — anchor with the actual markdown rendering prefix:**

```zig
try testing.expect(std.mem.indexOf(u8, md, " (id: `") == null);
try testing.expect(std.mem.indexOf(u8, md, "(id: `") == null);
```

The two needles can't appear in either `item_id: ` or `task_id:`.

**When this bites:** tests asserting "old label X is gone" by substring search when the new label is `prefix_X` containing X as a suffix (e.g., `_id` contains `id`).

---

## `extern "c"` declarations — symbol name rules

**Rule 1:** `extern "c" fn my_name(...)` exposes the symbol under **the declared name verbatim**. NOT a wrapper-style indirection. The linker resolves `my_name` in libc.

**Anti-pattern:**

```zig
extern "c" fn workflowNanosleep(req: *const Timespec, rem: ?*Timespec) c_int;
// Linker error: undefined symbol: workflowNanosleep
```

**Fix:** Declare with the REAL libc name. If you want a Zig-side wrapper, write one explicitly:

```zig
extern "c" fn nanosleep(req: *const Timespec, rem: ?*Timespec) c_int;
fn myNanosleepWrapper(req: *const Timespec) void {
    _ = nanosleep(req, null);
}
```

**Rule 2:** Nullable C pointer return: `?*T` works, with `orelse` unwrapping.

**Rule 3:** `extern "c"` declarations at the top of a `.zig` file are **not implicitly `pub`** — they're file-private by default.

**Rule 4:** Common types for `extern "c"` fields:
- `[*:0]const u8` for `const char*` (null-terminated)
- `[*]const u8` for `const char*` carrying bytes that may contain NULs (length carried separately)
- `c_int` for C `int`
- `usize` for `size_t`
- `bool` for C `bool`

**Rule 5:** `extern "c"` functions MUST be at module scope (not inside function bodies in Zig 0.16).

**Rule 6:** `extern "c"` bodies are not type-checked at call site (only signature). So you can declare `gettimeofday` and it resolves at link time without you implementing anything.

**Rule 7:** Linker doesn't see unused function pointers. `_ = webview.run;` does NOT force the linker to resolve symbols — use an actual CALL.

**When this bites:** any code wrapping a C library in Zig with `extern "c"`; porting older Zig that used different conventions.

---

## Related / cross-references

- `zig-0.16-stdlib-changes.md` — Zig 0.16 stdlib API removals
- `zig-build-and-test.md` — lazy analysis, build/test patterns
- `zig-sqlite-patterns.md` — SQLite-specific gotchas
- `zig-cross-platform.md` — cross-platform porting