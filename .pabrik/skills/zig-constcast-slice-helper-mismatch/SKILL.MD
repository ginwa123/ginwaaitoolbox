---
name: zig-constcast-slice-helper-mismatch
description: "When checking unused @as(usize, ...) → just check the val"
---
---
name: zig-constcast-slice-helper-mismatch
description: Use @constCast(&local_array) to pass a []const T slice to a helper that takes []T. The slice is read-only in practice, but the type system requires non-const.
tags: [zig, fix]
---

## When to Use

A test or production helper function takes a mutable slice parameter (e.g. `fn makeResponse(messages: []MyStruct) Response`) but the call site only has a const slice (e.g. from an array literal `&[_]MyStruct{...}` which is `[]const MyStruct`). The compiler rejects the conversion with `error: expected type '[]T', found '[]const T' / cast discards const qualifier`.

## Context

The pattern in Zig 0.16. The struct's field type is `[]T` (mutable slice); the helper passes it through unchanged. The slice is logically read-only — the function never mutates it.

## Procedure

Use `@constCast` at the call site to discard the const qualifier:

```zig
const messages = [_]llm_history.SessionMessage{ .{ .id = "m1", ... } };
const response = makeResponse(@constCast(&messages));
//                    ^^^^^^^^^^ this is the one-liner fix
```

The `@constCast` is a deliberate "I know this slice is read-only" signal — the compiler is happy because the helper genuinely doesn't mutate.

## Pitfalls

- Do NOT use `@constCast` if the function actually mutates the slice elements (UB at runtime). For read-only passthrough, it's safe.
- An alternative is to make the helper take `[]const T` — but if the struct field is `[]T` (mutable) and the field assignment requires mutability, the helper signature has to match. `@constCast` is the surgical fix.
- For newer Zig (0.16+), `@constCast` is the standard escape hatch for this; older patterns might have used `const slice: []T = @as([]T, ...)`.

## Verification

If a test fails with `expected type '[]T', found '[]const T' / cast discards const qualifier` at a helper call site, add `@constCast(&...)` around the argument.

If the function genuinely doesn't mutate, no runtime check is needed. If it DOES mutate, the `constCast` is a bug — fix the function or change the call site.

## Concrete example in this repo

`src/ai_workflow/tui/llm_history_is_input_output_test.zig:22` — the
`makeResponse` helper takes `[]llm_history.SessionMessage` (mutable, to
match `SessionMessageResponse.messages: []SessionMessage`) but the
test sites only have `[_]llm_history.SessionMessage` array literals
(which coerce to `[]const`). The fix: `@constCast(&messages)` at each
of the 3 call sites. The helper genuinely only reads the slice
fields (it doesn't call any methods that take `*Self`), so the
const-cast is safe.
