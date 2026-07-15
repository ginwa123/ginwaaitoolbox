# Zig 0.16 — `@import("../foo.zig")` Is Rejected from `root_source_file` Targets

When a `.zig` file is the `root_source_file` of an `addExecutable()` (or any
build step that treats it as the module's "own root"), `@import("..")` that
escapes the file's directory is a hard compile error:

```
error: import of file outside module path
const fire = @import("../fire.zig");
                     ^~~~~~~~~~~~~
```

The same `@import("../fire.zig")` is **fine** when the file is pulled in as
part of a larger module's test compile (e.g. `@import("subdir/file.zig")` in
a test block rooted elsewhere), because then the file is a child of that
larger module's root.

## Symptom

You have a binary at `src/.../bin/nalar-foo.zig` that wants to call something
in `src/.../fire.zig` (the parent dir). You write
`const fire = @import("../fire.zig");`. `zig ast-check` passes (it doesn't
resolve imports). `zig build test` passes (the file is never compiled — only
referenced from a test block that doesn't reach it). `zig build install:foo`
fails with "import of file outside module path" the moment Task 2.4 wires
the file as a build target.

## Why

Zig 0.16 enforces that a root file's imports stay within the package rooted
at the file's directory. The "package root" is the file's directory; `..`
escapes it. This is a safety check: a root file's module identity is
defined by its location, and the language wants every `@import` to be a
within-package relative path so refactors don't accidentally reach into
sibling packages.

## Fix

Don't reach up. Re-export the symbol you need through a public module
surface, then import the module from your root file.

**Pattern (used in nalar):** the `nalarcore` module is the project's
public API surface (declared via `b.addModule("nalarcore", ...)` in
`build.zig` with `root_source_file = b.path("src/root.zig")`). Every
executable that wants to call into project code does
`const nalarcore = @import("nalarcore");` — never a relative import.

To make `fire.zig` reachable from a root-level executable:

1. Add a re-export at the package level. For nalar: add
   `pub const routines = @import("routines/mod.zig");` to
   `src/ai_workflow/tui/mod.zig` (so it's reachable as
   `nalarcore.ai_mod.routines`).
2. In the new binary: `const fire = nalarcore.ai_mod.routines.fire;`
   (no relative import).

This is the same pattern `src/main.zig` uses — it never has a relative
`@import`; everything goes through `nalarcore.*`.

## When this bites

- Any new sub-process binary in a sibling dir of the code it wants to
  call (e.g. `bin/nalar-foo.zig` calling `../fire.zig`).
- The plan's skeleton often has `@import("../fire.zig")` because the
  plan was written without the root-source-file constraint in mind.
- The error is invisible to `zig build test` and `zig ast-check` —
  they don't compile the file as a root. You only see it when the
  build target is wired in.

## How to verify

After writing any new root-level `.zig` file, run
`zig build-obj -fno-emit-bin --dep nalarcore -Mroot=<file> -Mnalarcore=src/root.zig`
in the project root. The "import of file outside module path" error
will fire immediately, before the build target is wired. A successful
`build-obj` that stops at a system-library error (`@cImport` for sqlite3
needing `linkSystemLibrary`) means your Zig code type-checks end-to-end.
