# Better ChatView Tool-Width Consistency Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make every ChatView tool row keep one stable full-column width whether collapsed or expanded.

**Architecture:** Fix the flex shrink-to-fit chain in `ChatView.vue` (tool group container + `.tool-sequence` / `.tool-item` / `.chat-tool-card`), add `min-w-0` to the `ToolCardHeader` truncate slot, and clamp inner `<pre>` blocks so long JSON can scroll inside instead of stretching the card.

**Tech Stack:** Vue 3 + Tailwind (desktop frontend `src/apps/desktop/src`), vitest component tests, `pnpm run build`.

## Global Constraints

- Do NOT annotate code with `// NEW (plan: ...)` tags. Explain *why* in one plain sentence or no comment.
- Do NOT spin up a live `pabrik` binary + `curl` for verification. Use vitest + `pnpm run build`. For wire payloads use `tests/functional/harness.py` on ports 8080..8199 (never 8081).
- Frontend changes must keep `pnpm --dir src/apps/desktop run build` green and existing `ChatView.*.spec.ts` passing.
- One responsibility per file; follow existing `tool_outputs/_shared/` patterns (no unilateral restructure).
- YAGNI: fix width stability only. No new visual design, no slider, no card redesign.

## Why Widths Differ Today (diagnosis)

Screenshots show `use_tool` / `spawn_sub_agent` rows jumping width on expand:

1. Tool group wrapper (`ChatView.vue:3072-3075`) is `<div class="min-w-0" :class="... 'max-w-full'">` inside `<div class="flex flex-row">` (`:3054`). A flex child with no `flex-1` / `w-full` sizes to its **intrinsic content width** (shrink-to-fit), capped by `max-w-full`.
2. Collapsed header (`ToolCardHeader.vue:114-129`) is one short flex line (`toolName + primary truncate + rightMeta + ✓`). Intrinsic width = narrow.
3. Expanded body (`ProgressiveTool.vue:119-238`, `SpawnSubAgent.vue`, `ToolParameters.vue:33-37`) adds wide `<pre>` blocks (`prettyParameters`, JSON args, agent responses) with `overflow-x-auto` but parents have `overflow: visible` (`.chat-tool-card` in `ChatView.vue:4139-4146`) and no `min-width: 0 / width: 100%`. The pre's min-content width becomes the card's intrinsic width = wide.
4. Narrow collapsed vs wide expanded = visible jump. Different tools have different primary/pre lengths = row-to-row inconsistency.
5. Secondary: `ToolCardHeader` primary slot is `flex-1 truncate` without `min-w-0`, so a long tool name/path can also force the header wider instead of ellipsis (flexbox needs `min-w-0` for truncation).

## Files To Touch

- `src/apps/desktop/src/components/views/ChatView.vue` — template container classes (`:3072-3075`) + `<style>` for `.tool-sequence`, `.tool-item`, `.chat-tool-card`, inner `pre`.
- `src/apps/desktop/src/components/tool_outputs/_shared/ToolCardHeader.vue` — primary span add `min-w-0`.
- `src/apps/desktop/src/components/tool_outputs/_shared/ToolParameters.vue` — clamp `pre` (`max-w-full min-w-0 overflow-x-auto`).
- `src/apps/desktop/src/components/tool_outputs/ProgressiveTool.vue` — clamp expanded `pre` blocks (same as above, no logic change).
- Tests: new `src/apps/desktop/src/components/views/__tests__/ChatView.tool-width.spec.ts` (or extend existing) + run `ChatView.*.spec.ts`.

## Tasks

### Task 1 — Failing width test first

- [ ] Create `src/apps/desktop/src/components/views/__tests__/ChatView.tool-width.spec.ts` mounting `ChatView` (or `ProgressiveTool` + `ToolCardHeader` in the `tool-sequence > tool-item > chat-tool-card` wrapper) with one collapsed and one expanded `use_tool` row using the exact JSON from screenshot 1 (`{"type":"object","properties":{"path":...}}`).
- [ ] Assert: collapsed card `offsetWidth` / `getBoundingClientRect().width` equals expanded card width within 1px, and both equal the `.tool-sequence` content width (i.e. full column, not content-sized).
- [ ] Assert: long `primary` (e.g. 200-char path) truncates with ellipsis (`scrollWidth > clientWidth`, `text-overflow: ellipsis`) instead of widening the header.
- [ ] Run it to confirm it FAILS on current code.
- [ ] Commit: `test(chatview): failing tool-width consistency test`

### Task 2 — Full-width flex chain in ChatView

- [ ] In `ChatView.vue:3072-3075`, change tool/assistant container to `class="min-w-0 flex-1 w-full"` (keep existing `:class` for `max-w-[90%]` vs `max-w-full`). This makes the flex child fill the `max-w-4xl` column instead of shrink-to-fit. Same for bg-only group if it shares the pattern.
- [ ] In `<style>`: add `min-width: 0; width: 100%;` to `:deep(.tool-sequence)` and `:deep(.tool-item)`.
- [ ] In `<style>`: extend `:deep(.chat-tool-card)` with `width: 100%; min-width: 0; box-sizing: border-box;` (keep transparent bg + left rule + hover). Add `:deep(.chat-tool-card pre) { max-width: 100%; min-width: 0; overflow-x: auto; }`.
- [ ] Re-run Task 1 test to confirm container widths now match (pre clamp comes in Task 3; widths should already stabilize, pre may still overflow visibly).
- [ ] Run `pnpm --dir src/apps/desktop run build` (or vitest for ChatView) to confirm no regression.
- [ ] Commit: `fix(chatview): full-width tool container chain`

### Task 3 — Clamp headers and pre blocks

- [ ] `ToolCardHeader.vue:125-129`: add `min-w-0` to the `flex-1 truncate` primary span so long names ellipsis inside the fixed-width card.
- [ ] `ToolParameters.vue:37` + `ProgressiveTool.vue:187,223` `pre` blocks: ensure classes include `max-w-full min-w-0 overflow-x-auto` (keep `whitespace-pre-wrap break-words`). No logic change.
- [ ] Audit `SpawnSubAgent.vue` expanded rows for the same: any raw `response` / `pre` without `min-w-0` + `overflow-x-auto` gets the same clamp (surgical, no redesign).
- [ ] Re-run Task 1 test — must now PASS (collapsed == expanded == column width, long primary truncates, long JSON scrolls inside).
- [ ] Commit: `fix(chatview): clamp tool header and pre overflow`

### Task 4 — Verify no regressions

- [ ] Run full ChatView suite: `pnpm --dir src/apps/desktop test -- ChatView` (or `vitest run src/components/views/__tests__/ChatView.*.spec.ts`). All green.
- [ ] Run `pnpm --dir src/apps/desktop run build` green.
- [ ] Manual check (dev server, no live backend needed): open a chat with `use_tool` + `spawn_sub_agent` rows, toggle expand/collapse — no horizontal jump, no row-to-row width difference, long JSON scrolls inside the card.
- [ ] Delete any stray `vue-tsc` emitted `.js` files before committing (`vue-tsc-build-emits-js-files` skill).
- [ ] Commit: `test(chatview): width consistency verified` (or amend if test-only).

## Out Of Scope

- Card visual redesign, colors, spacing rhythm, slider, or new expand/collapse UX.
- Backend / SSE / `use_tool` equipping logic.
- VirtualScroller height estimates.

## Verification

- [ ] Plan saved to `docs/superpowers/plans/2026-09-12-better-chatview-tool-width.md`
- [ ] Plan header includes Goal, Architecture, Tech Stack, Global Constraints
- [ ] Each task has bite-sized steps (test → implement → verify → commit)
- [ ] User has reviewed the plan before execution begins
