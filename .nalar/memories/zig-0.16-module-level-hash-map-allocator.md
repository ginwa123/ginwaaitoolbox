# Zig 0.16 — Module-Level Globals Need `StringHashMapUnmanaged`, Not `StringHashMap`

The `std.StringHashMap(V)` (managed) wrapper requires an `allocator`
parameter at init (`pub fn init(allocator: Allocator) Self`). A
module-level `var map: std.StringHashMap(V) = .empty;` does NOT
compile because `.empty` is only defined on the `Unmanaged` variant.

## Symptom

```zig
var map: std.StringHashMap(SomeEntry) = .empty;
```

```
src/foo.zig:NN:NN: error: struct
'hash_map.HashMap([]const u8,...,80)' has no member named 'empty'
var map: std.StringHashMap(SomeEntry) = .empty;
                                          ~^~~~~
```

## The fix

Use `std.StringHashMapUnmanaged(V) = .empty` for the module-level
declaration, and pass the allocator to every `put` / `getOrPut` call
explicitly:

```zig
var map: std.StringHashMapUnmanaged(V) = .empty;

pub fn insert(allocator: std.mem.Allocator, key: []const u8, value: V) !void {
    try map.put(allocator, key, value);
}

pub fn get(key: []const u8) ?V {
    return map.get(key);  // get/contains don't allocate
}
```

For a module-level global that has no allocator in scope, you have
two options:

1. **Use `std.heap.page_allocator` directly** — leaks the key memory
   until process exit, which is fine for a process-lifetime tracker
   (e.g. `viewing_state.zig`).
2. **Add an `initAllocator(allocator)` function** that callers
   invoke at startup before any `touch` / `insert` calls. This is
   needed if the global might be exercised before the process's main
   allocator is wired up.

## Why the managed variant requires an allocator

Look at `std/hash_map.zig:170-179`:

```zig
pub fn init(allocator: Allocator) Self {
    if (@sizeOf(Context) != 0) {
        @compileError("Context must be specified! ...");
    }
    return .{
        .unmanaged = .empty,
        .allocator = allocator,
        .ctx = undefined,
    };
}
```

The managed wrapper stores an `Allocator` field at runtime, and
delegates every `put` / `getOrPut` call to the unmanaged variant,
passing `self.allocator` automatically. There is no `init()` that
takes no allocator.

## When this bites

- Any module-level global state backed by a string-keyed map.
- Tests that declare `var x: std.StringHashMap(...) = .empty;` in a
  test file or `const`/`var` block at the top of a `.zig` file
  (the `notifications.zig` module and `ActiveLoops.zig` avoid this
  by being parameterized structs, not module-level globals).
- Copy-pasting the 0.15 `var map = std.StringHashMap(T).init(allocator)`
  pattern to 0.16 code.

## How to verify after the fix

1. `git grep -n "StringHashMap(.*).empty"` — should return no matches
   in module-level `var` declarations.
2. `git grep -n "StringHashMapUnmanaged(.*).empty"` — should match
   the new module-level declarations.
3. The build succeeds; `clearRetainingCapacity` / `get` / `getPtr` /
   `remove` work without an allocator argument (they're allocation-free).
