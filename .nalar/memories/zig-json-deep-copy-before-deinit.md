# `std.json.parseFromSlice` return value borrowed; `deinit()` invalidates slices

## Symptom
SIGABRT crash or `0xAA` debug-fill bytes in JSON output (looks like garbage/encoding bug). Occurs when code does `parseFromSlice(MyStruct, ...)` → reads string fields → calls `.deinit()` → later stringifies. The `[]const u8` slices read earlier are now dangling pointers to freed memory.

## Root cause
`std.json.parseFromSlice` returns `Parsed(T)` which holds an internal ArenaAllocator owning ALL strings in the parsed tree. `parsed.deinit()` frees that arena. Any `[]const u8` slice you extracted from `.value` (or any nested field) is invalidated immediately. Copying slice HEADERS (pointer + length) into another structure does NOT copy the backing bytes.

## Fix
Two clean options:

**Option A — use the Leaky variant for one-shot parses:**
```zig
const parsed = try std.json.parseFromSliceLeaky(
    MyStruct, allocator, body, .{});
// parsed.name, parsed.foo are now owned by `allocator` — no .deinit() needed
```

**Option B — two-pass parse + stringify with deep copy:**
```zig
fn deepCopyJsonValue(alloc: Allocator, val: std.json.Value) !std.json.Value {
    switch (val) {
        .string => |s| return .{ .string = try alloc.dupe(u8, s) },
        .integer => |i| return .{ .integer = i },
        .float => |f| return .{ .float = f },
        .bool => |b| return .{ .bool = b },
        .null => return .null,
        .array => |a| {
            var new_arr: std.ArrayList(std.json.Value) = .empty;
            try new_arr.ensureTotalCapacity(alloc, a.items.len);
            for (a.items) |item| try new_arr.append(alloc, try deepCopyJsonValue(alloc, item));
            return .{ .array = new_arr };
        },
        .object => |o| { /* dup each key + recurse on value */ ... },
    }
}

const parsed = try std.json.parseFromSlice(MyStruct, alloc, body, .{ .duplicate_field_behavior = .use_last });
const owned = try deepCopyJsonValue(alloc, parsed.value);  // copies strings
parsed.deinit();
// now `owned` outlives the arena; safe to stringify
```

## Pitfalls
- **Don't try `allocator.dupe(parsed.value.string)` then `parsed.deinit()`** — `string` is already a `[]u8` slice header; duping the slice header doesn't extend the arena's lifetime. Must deep-copy the whole subtree.
- **Watch for `.use_last` vs `.overwrite` vs `.error` duplicate field behavior** — leaks one of the duplicates silently if you pick `.use_last` and don't process both.
- **For per-profile config this pattern is critical** — `Config.zig:writeDefaultConfig` and `nalar_config_put.zig` both parse then stringify. The deep-copy lives in `nalar_config_put.zig` to bridge the parse and stringify steps.

## Verification
After parsing + deep-copying + `deinit()`, stringify the deep-copied value and confirm the output contains the expected strings (not `0xAA` or empty). Test with `zig build install:linux:system` (not just `zig build test` — lazy analysis hides the parse+stringify path).

## Related
- `zig-slice-headers-across-defer-lifetimes` — same slice-ownership family
- source: `src/ai_workflow/tui/nalar_config_put.zig` (the SIGABRT fix from NALAR.md line 52)
- contrast: `parseFromSliceLeaky` is the WHOLE-STRUCTURE alternative when you don't need to stringify back
