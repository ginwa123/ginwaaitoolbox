# Zig 0.16 — `for (info.fields)` on `@typeInfo(T).@"struct"` is a compile error; use `inline for`

In Zig 0.16, iterating `@typeInfo(T).@"struct".fields` with a normal
`for` loop is a hard compile error:

```zig
const T = MyStruct;
const info = @typeInfo(T).@"struct";
for (info.fields) |f| {           // ❌ compile error
    if (std.mem.eql(u8, f.name, "foo")) ...
}
```

```
src/.../foo_test.zig:NN:NN: error: values of type
'builtin.Type.StructField' must be comptime-known, but index value is
runtime-known
    for (info.fields) |f| {
         ~~~~^~~~~~~
/usr/local/lib/zig/std/builtin.zig:666:15: note: struct requires
comptime because of this field
```

## Why

`builtin.Type.StructField` contains the field `default_value: ?anyopt`
whose type has comptime-only metadata. Because `info.fields` is a
`[]const StructField` runtime slice, a runtime `for` over it would
need to read `default_value` at runtime — which isn't allowed.

This is a regression from earlier Zig (0.13/0.14/0.15) where the same
`for (info.fields)` worked because `default_value` was not yet
constrained to comptime-only.

## The fix — use `inline for`

`inline for` unrolls at comptime, which makes `default_value` legal to
read:

```zig
inline for (info.fields) |f| {
    if (std.mem.eql(u8, f.name, "foo")) ...
}
```

The `inline for` version is the **established pattern in this
codebase** — see `src/ai_workflow/tui/llm_history.zig:47`:
`inline for (@typeInfo(T).@"enum".fields) |field| { ... }`. (That
specific case uses enums, but the `inline` keyword is needed for the
same reason: enum `fields` contains comptime-only data too.)

## Alternative — direct indexing (works without `inline`)

For tests that just need to verify "this field exists at position N":

```zig
try testing.expect(info.fields.len == 6);
try testing.expect(std.mem.eql(u8, info.fields[0].name, "type"));
try testing.expect(std.mem.eql(u8, info.fields[5].name, "created_at"));
```

Direct indexing into `info.fields[i]` reads ONLY the `name` field,
which IS runtime-readable. This is what
`on_event_sent_notification_test.zig` does for the existing 2 tests
(the `SseEventNotificationPayload has the right fields` test).

## When this bites

- Any new test that wants to scan struct fields by name with a loop
  (rather than indexing positionally). The spec/code-review pattern
  "iterate fields, assert a name exists" needs `inline for`.
- Tests for enum variant discovery (similar shape: enum fields contain
  comptime-only data).
- Tests copied from older Zig code or from LLM training data that
  pre-dates the comptime constraint.

## How to verify

If you see the `for (info.fields) |f|` compile error above, swap
`for` for `inline for` (one-word change). The test's runtime behavior
is unchanged — `inline for` over a runtime slice header still iterates
every element; it just unrolls the body at comptime.

Real example in this repo: Task 5 of the stop-notification feature
(commit `f7dea3f` on `feature/stop-notification`) wrote the test
using `for (info.fields) |f|` per the spec, hit the compile error,
fixed it to `inline for` — same test logic, same field-name assertion,
just the keyword changed.