# ChatView User-Pill Rail — Implementation Plan

**Date:** 2026-09-09
**Task:** `chatview user pill` (`task_1788961558793_3`)
**Scope:** plan only — no code in this task. Implementation lands as a follow-up.
**Target file:** `src/apps/desktop/src/components/views/ChatView.vue` (+ 1 new component + 1 new spec)

## 1. What the user asked

> Add a feature in ChatView.vue — user pill chat — so when user clicks that it jumps to that position user chat.

Screenshot annotation: orange arrow points at the **right edge** of the chat viewport with ~6 short horizontal orange dashes stacked vertically. That is a **minimap / index rail**: one pill per user message, click = jump to that message's position in the chat.

## 2. Current state (verified in code)

- `ChatView.vue` (~4156 lines) renders messages through `VirtualScroller` (`:items="messageGroups"`, `:item-key="groupKey"`, `ref="virtualScrollerRef"`).
- `messageGroups: computed<MessageGroup[]>` groups consecutive same-role messages; user groups render as blue bubbles (`group.role === 'user'`, `max-w-[90%]`, `flex-row-reverse`), assistant/tool render as borderless paragraphs.
- Scroll API already exposed on the scroller (`VirtualScrollerExposed` interface, lines ~374-392):
  `scrollToIndex`, `scrollToItem`, `scrollToTop/Bottom/Position`, `remeasure`, `preserveScrollPosition`, `containerRef`.
- Outer wrapper `messagesWrapperRef` is `position: relative` + `flex flex-col` — the correct anchor for an absolutely-positioned rail (same pattern as the existing "Load more messages" button + PreviewSidePanel).
- Group identity: `groupKey = group.messages[0]?.id ?? empty-<ts>`; per-message lookup helper `groupKeyForMessageId(messageId)` already exists (~line 1130).
- No existing minimap/rail component. No backend change needed — this is pure frontend navigation over already-loaded `messageGroups`.

## 3. Proposed UX

- **Rail placement:** absolute right edge inside `messagesWrapperRef`, vertically centered, `z-20`, `pointer-events: auto`, ~14px wide hit area with 24-32px tall pills (easy touch/click target, matches orange dashes in screenshot).
- **One pill per user group** (not per message — groups are the scroller's unit; a burst of 3 rapid user sends = 1 pill, avoids pill spam).
- **Pill appearance:** short horizontal bar (`w-6 h-1 rounded-full`), muted (`--color-border` / white/20) by default, accent/highlight on hover + for the "nearest above viewport" pill (active reading position).
- **Tooltip on hover:** first ~60 chars of the user text + relative time (`formatRelativeTime`), via native `title` (v1) — no custom popover.
- **Click behavior:** smooth-scroll the chat so the target user group lands near the top of the viewport (~16px offset), then flash-highlight the bubble (outline pulse ~1.2s) so the eye finds it.
- **Visibility rules:**
  - Hidden when < 2 user groups (nothing to navigate).
  - Hidden in `embedded` peek mode? — keep visible (read-only still benefits), but hide when `messageGroups.length === 0` or `isLoading`.
  - Never overlaps the composer/footer — rail lives only in the messages region.
- **Accessibility:** each pill is a `<button :aria-label="Jump to message N: <preview>">`, keyboard-focusable, `Enter/Space` triggers jump. Respects `prefers-reduced-motion` (jump = `auto` instead of `smooth`, no flash animation).

## 4. Design decisions / open questions for human

1. **Proportional minimap vs. uniform stack?** Recommend **uniform stack** (v1): pills evenly spaced top→bottom in click order, NOT proportional to message height/position. Proportional (like a real scrollbar minimap) requires height-model access (`sizerHeight`/`modelTotal`) and breaks under virtualization estimates. Uniform is predictable + trivially testable. Proportional can be v2.
2. **Per-group vs. per-message?** Recommend **per-group** (matches `VirtualScroller` items; `scrollToItem(groupIndex)` is exact). Per-message would need intra-group DOM queries.
3. **Compaction cards** (`<compact_messages>` user-role envelopes) — count as user pills or skip? Recommend **skip** (they're system artifacts, not user turns; filter via existing `isCompactionMessage`).
4. Which ChatViews get it? Recommend **all three** (`ChatView`, `StandardTaskChatView`, `AgentChatView`) via shared component — but v1 wires only `ChatView.vue`; the other two reuse the component in v2 if the pattern proves out.

## 5. Implementation steps (follow-up task)

1. **New component** `src/apps/desktop/src/components/chat/UserPillRail.vue`:
   - Props: `pills: { groupIndex: number; key: string; preview: string; title: string }[]`, `activeGroupIndex: number | null`.
   - Emits: `jump(groupIndex: number)`.
   - Pure presentational (no store, no API) — all logic stays in ChatView, so the component is unit-testable in isolation.
2. **ChatView wiring** (all inside `ChatView.vue` `<script setup>` + template):
   - `userPills = computed(...)` — map `messageGroups` → filter `role === 'user'` + `!isCompactionMessage(group.messages[0])` + `hasBubbleContent` → `{ groupIndex, key: groupKey(g), preview: first message content slice(0,60), title }`.
   - `activePillIndex` — nearest user `groupIndex <= firstVisibleGroupIndex`; derive from existing `handleVirtualScroll` state (or a lightweight `scroll` listener reading `container.scrollTop` + scroller's visible window; do NOT add a second scroll listener if the scroller already emits visible range — reuse it).
   - `jumpToUserGroup(groupIndex)` — `virtualScrollerRef.value?.scrollToItem(groupIndex, 'smooth')` (fallback: `scrollToIndex`); after `nextTick`, query `[data-group-key="<key>"]` and add a temporary `.pill-jump-flash` class, remove after ~1.2s. Wrap `scrollLogger.markProgrammatic()` before the write so the auto-stick logic doesn't misread it as a user scroll (same pattern as existing programmatic scrolls, line ~519).
   - Template: `<UserPillRail v-if="userPills.length >= 2" :pills="userPills" :active-group-index="activePillIndex" @jump="jumpToUserGroup" />` as sibling of `<VirtualScroller>` inside `messagesWrapperRef`.
   - Add `data-group-key` attr to the group root div (`:data-group-key="groupKey(group)"`) so the flash-highlight query is stable across re-renders.
3. **Styles:** scoped CSS in `UserPillRail.vue` only (no global stylesheet touch); rail `position: absolute; right: 6px; top: 50%; transform: translateY(-50%)`; pills `transition: background-color .15s, transform .15s`; hover `scale-x-125`; flash keyframes on the bubble (reuse `AgentErrorCard` pulse pattern, respect `prefers-reduced-motion`).
4. **No backend / migration / SSE / API changes.** No route changes. No store changes.

## 6. Test plan (follow-up task)

- **New spec** `src/apps/desktop/src/components/chat/__tests__/UserPillRail.spec.ts` (or `src/__tests__/ChatView.userPillRail.spec.ts` to match existing ChatView spec location):
  1. renders one pill per user group, zero pills when no user messages;
  2. skips compaction envelopes;
  3. click pill N emits `jump(N)` / calls `scrollToItem(N)` (mock scroller);
  4. active pill highlights nearest-above-viewport index;
  5. hidden when < 2 user groups.
- **ChatView integration spec:** mount ChatView with 3 user + 3 assistant groups, assert rail appears, click 1st pill → `scrollToItem` called with correct groupIndex (mock `virtualScrollerRef`).
- **Regression:** full `pnpm test:unit` + `vue-tsc --noEmit` clean; manual check: long session (>20 user turns), click top pill → lands at first user message; streaming while rail visible doesn't yank scroll (programmatic guard).

## 7. Risks / edge cases

- **Virtualized-away target:** `scrollToItem` handles non-rendered indices by design (windowing scroller); the `nextTick` flash query may miss if measurement hasn't settled — guard with optional chaining + retry once after `remeasure()`.
- **Rapid SSE appends** shift group indices mid-click — capture `groupKey` at click time and resolve to current index via `groupKeyForMessageId`-style lookup before scrolling (index-at-click may be stale by arrival).
- **Auto-stick fight:** jump must call `scrollLogger.markProgrammatic()` first, else `handleVirtualScroll` reads the jump as `userScrolledUp` and disengages bottom-stick permanently.
- **Narrow viewports / kanban 3-column mode:** rail overlays content — keep 6px inset + semi-transparent default, full opacity on hover; verify no horizontal scrollbar introduced (`overflow-x` unchanged).

## 8. Files (follow-up task)

- NEW `src/apps/desktop/src/components/chat/UserPillRail.vue`
- NEW `src/apps/desktop/src/components/chat/__tests__/UserPillRail.spec.ts` (or `src/__tests__/ChatView.userPillRail.spec.ts`)
- EDIT `src/apps/desktop/src/components/views/ChatView.vue` (computed + jump fn + template slot + data attr, ~40 lines)
- No backend, no migration, no API, no SSE contract change.
