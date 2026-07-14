# Zig — `std.debug.print` and `std.fmt.allocPrint` format strings must escape `{` and `}`

The Zig `Writer.print` / `std.fmt.allocPrint` API uses `{name}` (or `{s}`, `{d}`, etc.) as
format specifiers. A literal `{` or `}` in the output must be written as `{{` and `}}`.
A `{` followed by a non-identifier character (e.g. ` {` at the start of a word, or `{` next
to whitespace) is interpreted as a named-argument format specifier; if the corresponding
`.foo` field is not in the args tuple, the compiler fires the comptime error
`@compileError("too few arguments")` from `std/Io/Writer.zig:717`.

## Symptom

`zig build test` fails with:

```
/usr/local/lib/zig/std/Io/Writer.zig:717:13: error: too few arguments
            @compileError("too few arguments");
            ^~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
referenced by:
    print__anon_NNNNN: /usr/local/lib/zig/std/debug.zig:311:39
    test.<name>: src/.../<file>.zig:NN:24
```

The line:column in your file points at the `std.debug.print(` call. The compile error
mentions a number of `?` and says "too few arguments" because Zig found a `{` it
interpreted as a format specifier that has no matching field in the args tuple.

## The mistake

You wrote a `std.debug.print` whose format string contains example Zig code with
single braces, e.g.:

```zig
std.debug.print(
    "!! {s} is broken !!\n" ++
    "   try db.exec(allocator, \"INSERT INTO routines (...)\",\n" ++
    "       &.{ id, name });\n" ++   // <-- the `&.{` is a NAMED format spec
    "   See plan.md.\n",
    .{FILE_PATH},
);
return error.SomeError;
```

Zig parses `&.{` as a format specifier for the named field `&` (which doesn't exist in
the args tuple). Comptime errors with "too few arguments". Build fails.

## Fix

Replace every literal `{` in the format string with `{{`, and every literal `}` with `}}`:

```zig
"       &.{{ id, name }});\n" ++
```

The `{{` and `}}` produce a single `{` / `}` in the output. Existing
`task_update_test.zig` in this project uses this pattern (see the `if (json_body.name)
|n| {{ ... }}` example at line 71-74 of `http_handlers/task_update_test.zig`).

**Alternative:** just don't include literal braces in the format string. Describe the
fix in prose ("Add the INSERT after the task INSERT for task_type='routine'") instead of
showing a code sample. This is the safest option for static-regression-test error
messages — they're only ever printed to the developer's terminal, so a textual
description is sufficient.

## How to verify

If you have a failing `zig build test` whose root cause is "too few arguments" inside
`std.Io.Writer.zig:717`, scan the format string of the offending `std.debug.print` /
`std.fmt.allocPrint` call for any unescaped `{` (other than legitimate format
specifiers like `{s}`, `{d}`, `{any}`). Escape them with `{{` / `}}` or remove the
example code from the message.

## When this bites

- Static-regression-test error messages that include example code (`&.{...}`,
  `try foo(allocator) { ... }`, struct literals like `.{ .name = "x" }`).
- Doc comments in `.zig` files that are also used as format strings (rare).
- Any place you write `std.fmt.allocPrint(allocator, "...{...}...", .{...})` with
  literal braces in the output.
