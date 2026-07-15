# Zig 0.16 — `_ = var;` discard is rejected if the var is used later in the function

When a Zig 0.16 function body contains `_ = local_const;` to "document" that a value is referenced, the compiler rejects it with `error: pointless discard of local constant` IF the same variable is used again in the function. This is a hard error, not a warning.

## Symptom

```zig
const item_type_val = root.get("item_type") orelse { ... };
// ... much later, in a 4-way if/else branch ...
} else {
    _ = item_type_val; // ← plan-spec'd "documentation" discard
    updateWorkspaceItem(..., item_type_val.string) catch { ... };
    // ... and again, way later in the response struct:
}
return res.jsonResponse(.{ .data = .{
    .item_type = item_type_val.string,  // ← used again
    ...
} });
```

```
src/foo.zig:NN:N: error: pointless discard of local constant
src/foo.zig:NN:N: note: used here
```

## Why

The Zig 0.16 compiler does escape-flow analysis: a `_ = var;` that is followed by a use of `var` is a "pointless discard" because the discard doesn't do anything (the variable is still bound; subsequent reads work fine). The compiler considers the discard dead code.

Older Zig accepted this as benign documentation. Zig 0.16 rejects it.

## Fix

Remove the `_ = var;` line. The variable's use elsewhere already documents its importance. If the plan's prose says "documented for compatibility" — just delete the line, the code reads fine without it.

## When this bites

- Plan specs that include `_ = var;` to "acknowledge" a variable exists (a holdover from patterns where the variable might otherwise be flagged unused by a stricter linter).
- Long if/else if/else chains where the plan author added "document" discards in branches that DO use the variable.
- Refactoring a function to a more complex branching structure — the old function didn't need the discard, but the plan was written assuming the new structure does.

## How to verify

If `zig build test` (or `install`) fails with "pointless discard of local constant" pointing at a `_ = var;` line:

1. Check the rest of the function — does `var` appear anywhere after the discard?
2. If yes, just remove the `_ = var;` line.
3. If no (the var is truly never used), the discard is still pointless — remove the variable assignment instead.

## Concrete example in this repo

`src/ai_workflow/tui/http_handlers/workspace_items_update.zig:214` — the
plan specified `_ = item_type_val;` to "document" that the var was
referenced in the legacy item_type-only update branch. But
`item_type_val.string` is also used in the response struct literal at
line 232. Removing the discard fixed the compile error.

## Related

- `zig-format-string-brace-escaping.md` — another Zig 0.16 plan-spec
  pitfall (unescaped `{` `}` in debug.print format strings).
- `zig-0.16-t-to-t-param-becomes-const.md` — a different "implicit
  const" gotcha in Zig 0.16.
