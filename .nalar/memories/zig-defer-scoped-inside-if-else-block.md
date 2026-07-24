# `defer` inside `if/else` branch fires at branch end, not function end

## Symptom
Use-after-free (SEGFAULT, `0xAA` debug-fill bytes, or file written to wrong location) when code AFTER the if/else block reads a resource that the misplaced `defer` already freed. E.g. `path.join(..., skills_dir, ...)` reads a freed `skills_dir` because the `defer allocator.free(skills_dir)` fired inside the `else` block immediately after the const declaration.

## Root cause
`defer` is scoped to the BLOCK it appears in, not the enclosing function. A `defer` placed inside the `else { ... }` branch fires at the end of THAT `else` block — NOT when the function returns. Classic confusion: developers write `if (cond) { defer free(); }` expecting cleanup "at the end".

## Fix
Hoist the `defer` OUTSIDE the if/else, right after the const it depends on:

```zig
const skills_dir: []u8 = try computeSkillsDir(...);
defer allocator.free(skills_dir);   // ← fires at FUNCTION end, covers all paths

if (is_global) {
    // use skills_dir ... no manual free here
} else {
    // use skills_dir ... no manual free here
}

// subsequent path.join calls (AFTER the if/else) still see skills_dir alive
```

## Pitfalls
- **`errdefer` vs `defer`**: `errdefer` only fires on error path. If the resource was successfully created and you need cleanup on BOTH success and error paths, use `defer`. Example bug: `const updated_content = try ...; errdefer allocator.free(updated_content);` — on success, `updated_content` is never freed (memory leak). Fix: `defer allocator.free(updated_content);`
- **Don't add manual cleanup inside if/else branches** ("if (is_global) allocator.free(path);") — the hoisted `defer` already covers it. Duplicated cleanup either double-frees or fires before downstream uses.
- **Don't `defer` inside a `for` loop body expecting it to cover the loop** — fire at iteration end, not loop end. Hoist outside the loop or use a labeled block.

## Verification
After hoisting, run `zig build test` (the test target's lazy analysis may miss it; also run `zig build install:linux:system`). Confirm `git diff --stat <file>` shows the `defer` line moved (not duplicated). Stress test with 100 iterations of create→use→cleanup→reuse to expose dangling reads.

## Related
- `zig-slice-headers-across-defer-lifetimes` — defer-ordering family of bugs
- source: `src/ai_workflow/tui/tools/{add_skill,edit_skill}.zig` (lines 54-56 of NALAR.md bug-fixes)
- similar: `zig-language-quirks` — `defer allocator.free(literal_string)` panics
