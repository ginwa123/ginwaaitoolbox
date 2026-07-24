# Vue 3 components that unmount/remount across layout changes lose scroll position

## Symptom
When the layout shifts between modes (e.g. kanban full-bleed → 3-column with chat panel), the kanban's horizontal scroll position resets to 0. User has to scroll back to the column they were looking at on every layout toggle. Same bug for any horizontally-scrolling container that remounts.

## Root cause
Components that conditionally mount based on `v-if`/`v-show` on a parent layout are torn down and recreated. Fresh mount = `scrollLeft = 0`. There's no browser-native persistence for this; the layout state has no memory of the previous instance's scroll.

## Fix
Use a composable that persists `scrollLeft` per-key to localStorage and restores it after the new instance mounts:

```ts
// useKanbanScrollRestore.ts
export function useKanbanScrollRestore(key: string) {
  const storageKey = `kanban-scroll-${key}`;
  const elRef = ref<HTMLElement | null>(null);
  let saveTimer: ReturnType<typeof setTimeout> | null = null;

  function onScroll() {
    if (!elRef.value) return;
    // scrollend fires reliably on user-initiated end-of-scroll
    localStorage.setItem(storageKey, String(elRef.value.scrollLeft));
    // Debounced save for continuous drag-scrolls
    if (saveTimer) clearTimeout(saveTimer);
    saveTimer = setTimeout(() => {
      localStorage.setItem(storageKey, String(elRef.value!.scrollLeft));
    }, 150);
  }

  onMounted(async () => {
    // Wait 2 animation frames so layout has settled and scrollWidth
    // is final (children may still mount/measure after first paint).
    await new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r)));
    if (!elRef.value) return;
    const saved = parseInt(localStorage.getItem(storageKey) ?? '0', 10);
    if (saved > 0) {
      // Clamp to valid range — scrollWidth may have shrunk
      const max = elRef.value.scrollWidth - elRef.value.clientWidth;
      elRef.value.scrollLeft = Math.min(saved, Math.max(0, max));
    }
  });

  onBeforeUnmount(() => {
    if (saveTimer) clearTimeout(saveTimer);
  });

  return { elRef, onScroll };
}
```

Usage in the kanban board component:
```vue
<template>
  <div ref="scrollRestore.elRef" @scroll="scrollRestore.onScroll" @scrollend="scrollRestore.onScroll">
    <!-- columns -->
  </div>
</template>
<script setup>
const scrollRestore = useKanbanScrollRestore(props.workspaceItemId);
</script>
```

## Pitfalls
- **Don't restore on first paint** — wait for `await rAF × 2`. Children mount asynchronously; `scrollWidth` is wrong on frame 1. Restoring too early clamps to a stale max.
- **Always clamp to `scrollWidth - clientWidth`** — if columns were removed between mounts, the saved value may exceed the new max and scrollLeft will silently snap.
- **Use both `scrollend` AND debounced `scroll`** — `scrollend` misses continuous drag-scrolls (fires only at end); raw `scroll` fires too often (every frame). The two together cover both cases.
- **Namespace the localStorage key** (e.g. `kanban-scroll-<workspaceItemId>`) — without scoping, all kanbans share one slot and the last-mounted wins.

## Verification
Toggle the layout (kanban full-bleed → 3-column → back). Horizontal scroll position is preserved across both toggles. Manually scroll left, reload the page, scroll position restored. Delete a column, scroll position clamped to new max (doesn't overflow).

## Related
- NALAR.md line 82 (useKanbanScrollRestore composable)
- `vue-3-virtual-scroller-reactive-scrollability.md` — same app, vertical scroll edge cases