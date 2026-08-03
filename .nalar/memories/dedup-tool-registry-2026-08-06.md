# Deduplicate `UNIFIED_TOOL_REGISTRY` — single source of truth in `tools_equipped.zig` (2026-08-06)

## What landed (squash-merged as `65946798`)

User report (task_1785779810982): *"duplicate pub fn UNIFIED_TOOL_REGISTRY() []const ToolInfo { … i want you use from tools_equiped .zig file"*.

Two competing registry copies had drifted:
- `tools_equipped.zig` (newer, includes `get_design_context` + `preview_design_page`)
- `tool_registry.zig` (legacy, missing the 2 newest tools)

The legacy copy meant every new tool had to be added in TWO places, and the legacy copy was silently missing the 2 newest tools — meaning the LLM couldn't actually call `get_design_context` from the dispatch path that `handle_tool.zig` actually uses.

## What landed (single source of truth)

- **Deleted** `src/ai_workflow/tui/agentic_loop/tool_registry.zig` (the duplicate). The file was 238 lines of import aliases + a copy of `UNIFIED_TOOL_REGISTRY()`; now both copies collapse to the one in `tools_equipped.zig`.
- **`tools_equipped.zig`** (canonical, kept): unchanged in shape. Fixed the `nalarcore.create_kanban_task_tool` → `nalarcore.create_kanban_task` import bug so the function actually compiles when called.
- **`handle_tool.zig`** (the only production caller): `tool_registry.UNIFIED_TOOL_REGISTRY()` → `tools_equipped.UNIFIED_TOOL_REGISTRY()`. `ToolExecFunc` type re-exported; `isKnownTool` / `getToolNames` rewritten to walk the registry directly (dropped the `tool_registry` indirection).
- **`workflow.zig`**: `tool_registry = @import("tool_registry.zig")` → `@import("tools_equipped.zig")` (now matches the `tool_registry` variable name still used in a code comment).
- **`handle_semantic_search.zig`**: removed unused `tool_registry` import.
- **`preview_design_page.zig`**: fixed 5 instances of `i64 / 2` → `@divTrunc(_, 2)` (line 223-226 + line 368).
- **`show_preview.zig`**: added `pub` to `successEnvelope` so cross-file callers (the `preview_design_page.zig` envelope wrap) can reach it.
- **8 static-contract test files updated** to point `TOOL_REGISTRY_PATH` at `tools_equipped.zig` instead of the deleted `tool_registry.zig`, AND updated the `.exec =` patterns from `agentic_loop_mod.tools.execX` to `tools.execX` (because `tools_equipped.zig` imports `tools = @import("tools.zig")` directly): `kanban_list_test.zig`, `kanban_move_task_test.zig`, `set_git_worktree_test.zig`, `create_kanban_task_test.zig`, `set_design_page_test.zig`, `add_design_element_test.zig`, `update_design_element_test.zig`, `group_design_elements_test.zig`. The "tool_registry.zig imports X module" tests were deleted entirely (the file no longer has module imports — they're now in `tools_equipped.zig`).

## Lazy-analysis-hidden bugs (surfaced after the dedup)

Removing the duplicate `tool_registry.zig` forced the canonical path's body to be analyzed end-to-end for the first time, exposing 3 latent compile bugs:

1. `tools_equipped.zig:51` — `nalarcore.create_kanban_task_tool` doesn't exist (typo, should be `nalarcore.create_kanban_task`).
2. `preview_design_page.zig:223-226, 368` — `i64 / 2` needs `@divTrunc` / `@divFloor` / `@divExact` in Zig 0.16.
3. `show_preview.zig:146` — `successEnvelope` missing `pub`.

See `~/.config/nalar/memories/zig-lazy-analysis-hides-divide-and-pub-bugs.md` for the cross-project lesson.

## Verification

- `zig build` (Linux) — all 3 binaries compile.
- `zig build-obj -fno-emit-bin -target x86_64-windows-gnu` — clean.
- `zig build-obj -fno-emit-bin -target aarch64-macos` — clean.
- `zig build test --summary all` — **2278/2284 pass** (same as main; the 2 pre-existing leaks in `design_model_set_element_parent_test` are unrelated).

## Why this matters

- Every new tool had to be added in TWO places (`tools_equipped.zig` AND `tool_registry.zig`).
- The legacy copy was silently missing the 2 newest tools (`get_design_context`, `preview_design_page`).
- The LLM couldn't reach these tools through the dispatch path `handle_tool.zig` actually uses (only through the legacy `getToolByName` / `isKnownTool` that no one called externally).
- Now there's one registry to maintain, and lazy analysis can no longer hide compile bugs in any tool's body.

## Branch / commit

- Branch: `worktree/dedup-tool-registry`
- Commit: `65946798` (squash-merged to main)
- Files: 1 deleted, 14 modified, 16 files total
- AGENTS.md changelog entry added under "Recent changes" (2026-08-06)
