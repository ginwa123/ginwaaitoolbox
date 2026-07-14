# Zig 0.16 — `orelse` between `?[]const u8` and `[]u8` fails to unify

`orelse expr1 orelse expr2` requires both branches to coerce to a
single common type. When the LHS is `?[]const u8` and the RHS is
`[]u8` (a non-optional slice), the compiler may reject the
expression with `error: expected optional type, found '[]u8'`.

## Symptom

```zig
const item_type_in_body: ?[]const u8 = ...;     // from JSON body
const existing: ?WorkspaceItemInfo = ...;

// Get the existing row's type (non-optional []u8 field):
const effective_item_type: []const u8 =
    item_type_in_body orelse existing.?.item_type.?;
//                                                       ^~
// error: expected optional type, found '[]u8'
```

The `?.` on `existing` unwraps the outer optional (returning
`WorkspaceItemInfo`); `.item_type` is then `[]u8` (non-optional, per
the struct definition). Writing `existing.?.item_type.?` is therefore
wrong — there's no optional left to unwrap.

## Fix

Use a `blk:` block with explicit early-return to express the
preference without type-unification friction:

```zig
const effective_item_type: []const u8 = blk: {
    if (item_type_in_body) |v| break :blk v;
    break :blk existing.?.item_type;
};
```

The `break :blk v` (where `v: []const u8`) and `break :blk
existing.?.item_type` (where `existing.?.item_type: []u8`) both
bind to the `[]const u8` block return type. `[]u8` coerces to
`[]const u8` (immutable borrows from mutable bindings is a standard
Zig pattern), so the unification succeeds.

## Why this bites

The natural-looking `orelse` form looks like the right idiom for
"prefer this, fall back to that". But `orelse` requires both sides to
be the same **concrete** type after stripping one optional layer.
Even when one side could legally coerce (`[]u8` → `[]const u8`), the
inference engine doesn't always pick that path — particularly in
Zig 0.16, where `orelse` typing is strict.

The `blk:` form sidesteps the issue by giving the compiler an
explicit return type to unify against, instead of inferring from the
two branch expressions.

## When this bites

- Any `orelse` expression where one branch is `?T` and the other is
  plain `T` (or `[]u8` vs `?[]const u8`).
- HTTP handlers / DB rows where a model returns non-optional slices
  (`item_type: []u8`) and you want to fall back to that value when a
  body field is absent.
- Memory-bound slices where the two sides have different mutability
  qualifiers (`[]u8` vs `[]const u8`).

## How to verify after the fix

1. `zig build test --summary all` should compile + run with 0 errors.
2. `zig build` should produce `zig-out/bin/nalar` with a recent
   mtime (the compile step actually ran).
3. The function's runtime contract is unchanged: the body value (if
   present) wins; the existing row's value is the fallback.

## Concrete precedent in this repo

`src/ai_workflow/tui/http_handlers/workspace_items_update.zig:136-149`
introduced `effective_item_type` for the chunk-4 fix that makes
`item_type` optional in the PUT body. The original draft used
`item_type_in_body orelse existing.?.item_type.?` and failed the
compile; switching to the `blk:` form unblocked it.
