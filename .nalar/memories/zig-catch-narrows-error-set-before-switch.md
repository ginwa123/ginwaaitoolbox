# Zig — `catch |err|` in a function body narrows the inferred error set BEFORE the catch

When a Zig function body contains `return error.X catch { ... }` patterns that
convert transient errors (OutOfMemory, etc.) into domain-specific errors,
the function's **inferred error set is the narrowed set**, NOT the
broadened set the `catch` arms "should" see.

This bites hard when the caller does
`someFn() catch |err| switch (err) { ... }` and tries to match
`error.OutOfMemory` even though the function body never propagates it.

## Symptom

```zig
pub fn deleteTaskUseCase(...) !MyOutcome {
    db.exec(..., ...) catch {
        return error.RoutineCleanupFailed;  // ← all errors converted
    };
    deleteWorkspaceItemTask(...) catch {
        return error.TaskDeleteFailed;
    };
    return .deleted;
}

// In handler:
const outcome = deleteTaskUseCase(...) catch |err| {
    return res.jsonResponse(.{ .data = switch (err) {
        error.RoutineCleanupFailed => "Routine cleanup failed",
        error.TaskDeleteFailed => "Task delete failed",
        error.OutOfMemory => "Out of memory",   // ← compile error
        else => "Internal error",
    } });
};
```

Compile error (production build only — `zig build test` may miss it via
lazy analysis):

```
src/.../task_delete.zig:NN:NN: error: expected type
    '@typeInfo(...).@"fn".return_type.?).error_union.error_set',
    found 'error{OutOfMemory}'
            error.OutOfMemory => "Out of memory",
            ^~~~~~~~~~~~~~~~~
src/.../task_delete.zig:NN:NN: note: 'error.OutOfMemory' not a member
    of destination error set
```

After removing `error.OutOfMemory`:

```
src/.../task_delete.zig:NN:NN: error: unreachable else prong;
    all cases already handled
            else => "Internal error",
            ~~~~~^~~~~~~~~~~~~~~~~~~
```

## Why

`catch` arms that return a different error **narrow the propagated set**.
The function body's actual error set becomes
`{ RoutineCleanupFailed, TaskDeleteFailed }` only — the transient errors
(`OutOfMemory` from `allocator.dupe`, `error.QueryFailed` from `db.exec`,
etc.) are absorbed by the catch arms and never reach the caller.

This is intentional Zig behavior: the inferred error set is what the
function ACTUALLY propagates, not what it MIGHT propagate if the catches
didn't convert.

## Fix

Match the actual error set in the caller. Two safe patterns:

### Pattern A — Drop the transient variants (matches the actual set)

```zig
const outcome = deleteTaskUseCase(...) catch |err| {
    return res.jsonResponse(.{ .data = switch (err) {
        error.RoutineCleanupFailed => "Routine cleanup failed",
        error.TaskDeleteFailed => "Task delete failed",
    } });
};
```

No `else` prong — the switch is exhaustive over the actual set. Adding
`else => "Internal error"` is a compile error (unreachable).

### Pattern B — Widen the function's return type to `anyerror`

```zig
pub fn deleteTaskUseCase(...) anyerror!MyOutcome {
    // ... no catch arms converting errors ...
}
```

The caller can then add a fallback `else => "Internal error"` prong.
Trade-off: every call site must handle the broader set, and the
function loses its domain-specific error contract.

### Pattern C — Document the error set explicitly (most maintainable)

```zig
pub const DeleteTaskError = error{
    RoutineCleanupFailed,
    TaskDeleteFailed,
};

pub fn deleteTaskUseCase(...) DeleteTaskError!MyOutcome {
    // ... body ...
}
```

The explicit error set makes the narrowing explicit and the caller can
exhaustively match without runtime surprises.

## Why `zig build test` may miss this (lazy analysis)

The test target compiles a SEPARATE module graph rooted at the test
runner. If no test directly references `deleteTaskUseCase`, the test
build never type-checks the function's inferred error set or the
caller's `switch` over it. The `install:linux:system` target compiles
the full `main.zig` → `nalarcore` graph, which DOES reach the handler
and the use-case, so the install build catches the bug — but only if
you actually run the install target. The test build's green light is
NOT a substitute.

Per the project memory `verification-before-completion`, always run
BOTH `zig build test --summary all` AND `zig build install:linux:system`
when the change touches a production handler.

## When this bites

- Any function body that uses `catch { return error.X; }` to convert
  transient errors into domain errors (the standard "errors as values"
  pattern).
- Any caller that does `fn() catch |err| switch (err) { ... }` and
  tries to add cases for variants the function never propagates.
- Refactoring `catch` arms — adding a new `catch { return error.X; }`
  in the function body changes the inferred set, which can break
  caller `switch`es.
- Cross-platform porting — if a function's body changes (e.g., adding
  `try allocator.dupe` without a `catch` arm), the inferred set grows
  and may need a new variant in the caller's switch.

## How to verify after the fix

1. **Compile-check the install target:**
   ```bash
   cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
   timeout 240 zig build install:linux:system 2>&1 | tail -n 5
   # Expected: 4/6 steps succeeded (the cp to /usr/local/bin/nalar
   # fails harmlessly with permission denied)
   ```
2. **Confirm the test count:** `zig build test --summary all` should
   report the same pass/skip count as the baseline + any new tests.
3. **Check for a no-op `else => "Internal error"` after the fix** —
   if the switch is exhaustive (Pattern A), the `else` is gone.

## Concrete precedent in this repo

`src/ai_workflow/tui/http_handlers/task_delete.zig` (this refactor,
2026-06-28). Initial implementation had
`switch (err) { error.RoutineCleanupFailed => ..., error.TaskDeleteFailed => ..., error.OutOfMemory => ..., else => "Internal error" }`.
First fix removed `error.OutOfMemory` (not in inferred set), second fix
removed the `else` prong (all cases handled). Final pattern matches
the actual inferred set exactly.
