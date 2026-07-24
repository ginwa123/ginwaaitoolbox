# Vue 3 reactive `is X taller than Y` checks need `computed` or events, not `ResizeObserver`/ref chains

## Symptom
A `VirtualScroller` reports `isScrollable: false` even when content overflows. "Load more" button shows in scrollable chats. During LLM streaming, spurious `loadMore` triggers cause jitter (prepended older messages fight auto-scroll-to-bottom).

## Root cause
Three layered Vue 3 reactivity traps:
1. `ResizeObserver` only fires when the **observed element's** size changes — NOT when content inside it grows. `scrollHeight` reads are not reactive.
2. `watch(() => props.items.length, cb)` without `{ immediate: true }` never fires when items are already at length N at mount — no "change" event occurs.
3. `computed(() => childRef.value.isScrollable.value)` through a component-instance proxy is **not** depend-tracked by Vue 3.
4. `height: 100%` requires every ancestor to have a resolved height; through `flex-1` chains the percentage sometimes resolves to `0`, making the scroller read `0×0` and firing `loadMore` from `scrollTop=0 < 200`.

## Fix
```ts
// Inside VirtualScroller: derive from reactive state, not DOM reads
const isScrollable = computed(() =>
  accumulatedHeights.value[items.value.length] > containerHeight.value
);

watch(() => props.items.length, updateAccumulatedHeights, { immediate: true });

// Emit events to parent (don't expose computed via template ref chain)
const emit = defineEmits<{ 'scrollability-change': [boolean] }>();
watch(isScrollable, (v) => emit('scrollability-change', v), { immediate: true });

// Inside VirtualScroller template CSS: use flex, not height: 100%
.virtual-scroller { flex: 1 1 0; min-height: 0; min-height: 100px; }

// Self-defense: only fire loadMore when content is actually scrollable
function onScroll(e: Event) {
  const t = e.target as HTMLElement;
  if (t.scrollHeight > t.clientHeight && t.scrollTop < loadMoreThreshold) emit('load-more');
}

// Parent (ChatView) — guard during LLM processing and preserve cycles
function handleLoadMore() {
  if (isLLMProcessing.value) return;  // suppress during streaming
  return loadChatHistory(true);
}
function scrollToBottom(force: boolean, trigger: string) {
  if (virtualScrollerRef.value?.isPreservingScroll?.value) return;  // guard preserve
  ...
}
```

## Pitfalls
- Don't rely on `ResizeObserver` alone for "is content overflowing" — it doesn't watch content growth. Use `computed` over reactive refs OR wire explicit triggers (`MutationObserver`, `watch(items.length, ..., { immediate: true })`).
- Don't access `childRef.value.someRef.value` through component proxies — switch to events (`emit` + `@event`) for child-to-parent reactivity.
- Don't use `height: 100%` for flex children — use `flex: 1 1 0; min-height: 0`.

## Verification
In a long scrollable chat, "Load more" button is hidden (only scroll-to-top works). During LLM streaming, no `loadMore` triggers fire (check `scrollLogger`). `isScrollable` flips correctly on first render (assert via `data-testid`).

## Related
- NALAR.md lines 41, 76-79
- `scrollLogger.ts` — distinguish programmatic vs user scroll via `origin`
- `vue-3-v-if-chain-attaches-to-previous-sibling.md`
