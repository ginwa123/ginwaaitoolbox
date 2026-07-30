# Task Ledger — kanban-tag-autocomplete

**Plan:** `docs/superpowers/plans/2026-07-30-kanban-task-tags-autocomplete.md`
**Worktree:** `/home/ginwa/ginwaaitoolbox/.worktrees/kanban-tag-autocomplete`
**Branch:** `worktree/kanban-tag-autocomplete`

## Conventions (all sub-agents must follow)

- **TDD**: every implementer sub-agent runs the failing test first (red), then minimal impl (green).
- **No static-contract tests** — behavioural tests only. No `expect(source).toContain(...)` / `indexOf(u8, source, ...)` patterns.
- **Cross-platform** — every step must work on Linux + macOS + Windows. Use `nalarcore.helpers.*` wrappers, never `std.posix.*` direct.
- **No comments above `logger.infoFmt(...)` calls**.
- **Worktree isolation** — all commits land on `worktree/kanban-tag-autocomplete`, NEVER on `main`.

## Tasks

| # | Status | Outcome | Files |
|---|---|---|---|
| 1.1 | done | `KanbanTagSuggestion` + `KanbanTagSuggestionsPage` structs added; `listKanbanDistinctTags` stub returning `error.NotImplemented`; 10 failing behavioural tests in `llm_history_kanban_tags_test.zig`. | `src/ai_workflow/tui/llm_history.zig` (+structs/stub); `src/ai_workflow/tui/llm_history_kanban_tags_test.zig` (NEW); `src/ai_workflow/tui/test_runner.zig` (+1 line). |
| 1.2 | done | `listKanbanDistinctTags` implements `LIMIT N+1 OFFSET K` trick; all 10 tests pass. | same file as 1.1. |
| 1.3 | done | `kanban_tags_list.zig` handler stub returning 501; route registered in `main.zig`. | `src/ai_workflow/tui/http_handlers/kanban_tags_list.zig` (NEW stub); `src/main.zig` (+1 line). |
| 1.4 | done | `useCase` extracted; parses `?limit` + `?offset`; returns `{ tags, has_more }`; `KanbanTagSuggestionResponse` + `makeKanbanTagsListResponse` in `http_response.zig`; 4 useCase tests pass. | `kanban_tags_list.zig` (impl); `http_response.zig` (+struct + make fn); `kanban_tags_list_test.zig` (NEW). |
| 1.5 | done | Live curl smoke against port 8080 confirms pagination + has_more + clamping. | (no code) |
| 2.1 | done | `getKanbanTagSuggestions` API stub; 4 failing tests. | `src/apps/desktop/src/api/index.ts` (+stub + types); `src/apps/desktop/src/__tests__/apiKanbanTagSuggestions.spec.ts` (NEW). |
| 2.2 | done | API wrapper implements pagination + graceful degradation. | same as 2.1. |
| 2.3 | done | `useKanbanTagSuggestions` composable stub; 8 failing tests. | `src/apps/desktop/src/composables/useKanbanTagSuggestions.ts` (NEW stub); `src/apps/desktop/src/__tests__/useKanbanTagSuggestions.spec.ts` (NEW). |
| 2.4 | done | Composable implements lazy-load + pagination + in-flight guard + reset. | same as 2.3. |
| 2.5 | done | `KanbanTagsInput` gets `suggestions` + `hasMore` + `loadingMore` + `onLoadMore` props; dropdown + scroll sentinel + IntersectionObserver scaffold; 14 failing tests. | `src/apps/desktop/src/components/kanban/KanbanTagsInput.vue` (EDIT); `src/apps/desktop/src/__tests__/KanbanTagsInput.autocomplete.spec.ts` (NEW). |
| 2.6 | done | Dropdown + keyboard nav + IntersectionObserver wired + "Loading more…" indicator; all 14 tests pass. | same as 2.5. |
| 2.7 | done | Dialog mounts the composable, passes `filteredTagSuggestions` + flags to input; `workspaceId` prop threaded from parent; 5 wiring tests pass. | `src/apps/desktop/src/components/kanban/KanbanTaskDetailDialog.vue` (EDIT); parent `KanbanView.vue` (+1 prop binding); `src/apps/desktop/src/__tests__/KanbanTaskDetailDialog.autocomplete.spec.ts` (NEW). |
| 2.8 | done | Final verification: `zig build test` + `install:linux:system` + `rm -rf zig-out/bin && zig build` + cross-compile + `bun run build` + `bunx vitest run` + live smoke. | (no code) |

## Per-task verify gate (every chunk end)

- `cd /home/ginwa/ginwaaitoolbox/.worktrees/kanban-tag-autocomplete`
- `timeout 180 zig build test --summary all 2>&1 | tail -n 10` (Zig tests)
- `timeout 180 zig build install:linux:system` (binary builds)
- `cd src/apps/desktop && timeout 180 node node_modules/vue-tsc/bin/vue-tsc.js --build` (type-check)
- `timeout 180 bunx vitest run 2>&1 | tail -n 20` (frontend tests)
- `timeout 180 bun run build 2>&1 | tail -n 20` (vite build)

## Final cross-compile gate (plan Task 2.8 only)

- `zig build-obj -fno-emit-bin -target x86_64-windows-gnu -lc --dep nalarcore -Mroot=/tmp/test_mod.zig -Mnalarcore=src/root.zig`
- `zig build-obj -fno-emit-bin -target aarch64-macos -lc --dep nalarcore -Mroot=/tmp/test_mod.zig -Mnalarcore=src/root.zig`

## Live smoke (port 8080 ONLY, never 8081)

```bash
rm -rf /tmp/nalar-tags-final
env -i HOME=/tmp/nalar-tags-final PATH=$PATH \
  nohup ./zig-out/bin/nalar --port 8080 > /tmp/nalar-tags-final.log 2>&1 < /dev/null &
disown
sleep 6
# ... curl tests ...
pkill -f "nalar --port 8080"
```