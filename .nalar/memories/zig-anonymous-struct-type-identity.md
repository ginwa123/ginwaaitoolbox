# Zig — anonymous structs in different positions are distinct types, even with identical fields

In Zig 0.16, two anonymous struct types (e.g. `struct { id: []const u8, name: []const u8 }`)
declared in different places are treated as **distinct, non-coercible
types** even when they have the same fields. This bites hard in
generic helpers with `anytype` parameters.

## Symptom

You have a `WorkspaceSeed` struct that uses an anonymous struct
inline for `items`:

```zig
const WorkspaceSeed = struct {
    items: []const struct {
        id: []const u8,
        item_type: []const u8 = "chat",
        path: []const u8,
        name: []const u8 = "",
    },
};
```

A test builds a `var items: [N]struct { id, item_type, path, name }`
array and passes `items[0..]` to `seedWorkspace` (which expects
`[]const WorkspaceSeed.Items`). You get:

```
error: expected type '[]const WorkspaceSeed__struct_...', found
       '*[N]test.SomeTest__struct_...'
pointer type child 'test.SomeTest__struct_...' cannot cast into pointer
type child 'WorkspaceSeed__struct_...'
```

Same fields, different types — Zig rejects the coercion because the
inline struct types are nominally different.

## Why

Anonymous structs in Zig get a synthesized type name based on the
declaration site (function, struct field, file scope, etc.). Two
structs declared in two different scopes are distinct types even if
their field-by-field shape is identical. This is a deliberate design
choice in Zig (vs. TypeScript's structural typing or Go's structural
comparability): anonymous types are nominal.

The `anytype` parameter doesn't help — `anytype` requires the argument
to be a single concrete type; the call site must produce a value of
the exact type the callee expects.

## The fix

Hoist the inner anonymous struct to a top-level named struct:

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

// Now `var items: [25]ItemSeed` and `items[0..]` coerces correctly.
```

This also makes the code easier to read — the `ItemSeed` name
documents what each row represents, and tests can pass the
named type explicitly.

## Related: passing a struct tuple as `anytype` to call `.db.exec`

There's a separate but related gotcha with `anytype` helpers that
need to call `db.exec(...)` (which takes `*SqliteBackend`). If
your helper is `fn seedWorkspace(ctx: anytype, alloc, seed)` and
the body is `try ctx.db.exec(alloc, ...)`, Zig can't infer that
`ctx` is a mutable struct return and you get:

```
error: expected type '*T', found '*const T'
```

The fix: take the pointer explicitly:

```zig
fn seedWorkspace(db: *sqlite.SqliteBackend, alloc, seed) !void {
    try db.exec(alloc, ...);
}
// Caller: seedWorkspace(&ctx.db, alloc, .{.items = ..., ...})
```

This matches the convention in `src/ai_workflow/tui/routines/model_test.zig`'s
`insertParentTask(db: *sqlite.SqliteBackend, ...)` helper.

## When this bites

- Any `WorkspaceSeed`-style config struct that uses inline anonymous
  structs for collection elements.
- Tests that build `[N]struct_X` and pass `arr[0..]` to a helper
  expecting `[]const struct_Y` (where `struct_X` and `struct_Y`
  have identical fields but are declared in different scopes).
- Any `anytype` helper that calls a method taking `*T` on a field
  of the `anytype` argument.

## How to verify

If you see "expected type '...struct_X', found '...struct_Y'"
with identical fields, hoist the struct to a top-level named type.
If you see "expected type '*T', found '*const T'" on an `anytype`
helper, take the pointer explicitly instead.
