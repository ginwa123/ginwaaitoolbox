# Vue 3 `v-if`/`v-else` chain attaches each clause to the MOST RECENT preceding `v-if`

## Symptom
Adding a `v-else-if` (or `v-else`) between two sibling elements that both need to render independently causes the second one to be hidden whenever the first is visible. In ChatView.vue: a new "Load more messages" button (`v-if="hasMoreMessages && ..."`) chained via `v-else-if` to the existing `VirtualScroller` (`v-if="isLoading || messageGroups.length > 0"`) made the scroller disappear whenever the button was visible.

## Root cause
Vue 3's `v-if`/`v-else`/`v-else-if` is a **chain** — each `v-else-if` and `v-else` attaches to the MOST RECENT preceding `v-if` in DOM order, NOT to a separately-defined condition block. Once you write `v-else-if`/`v-else`, all subsequent siblings that share the chain become mutually exclusive — even when they were originally independent.

## Fix
```vue
<!-- ❌ WRONG: button's v-if chains to scroller's v-if via v-else-if -->
<template v-if="!isLoading && messageGroups.length === 0">empty state</template>
<template v-else-if="hasMoreMessages && ..."><button>Load more</button></template>
<template v-else-if="isLoading || messageGroups.length > 0"><VirtualScroller /></template>

<!-- ✅ RIGHT: three independent v-ifs, no v-else between them -->
<template v-if="!isLoading && messageGroups.length === 0">empty state</template>
<template v-if="hasMoreMessages && !isLoadingMore && messageGroups.length > 0 && !scrollerIsScrollable">
  <button data-testid="load-more-messages">Load more</button>
</template>
<template v-if="isLoading || messageGroups.length > 0"><VirtualScroller /></template>
```

Each `v-if` is a standalone guard; all three can be true simultaneously and render together.

## Pitfalls
- **Don't use `v-else` after a new `v-if`** "for cleanliness" — it silently merges the two into a chain. If you need N independent blocks, write N `v-if`s with explicit conditions.
- **Don't combine `v-if` and `v-show` chains** — same chain semantics apply; `v-show` is not a way out.
- **Beware when copy-pasting**: a developer adds a new sibling between two existing elements and types `v-else-if` thinking it's independent — it's not.

## Verification
Render all three blocks in the same DOM: open a chat with messages, scroll within a scrollable container (button hides), then have fewer messages than container height (button shows while scroller is also visible). Both elements present simultaneously proves the chain is broken.

## Related
- NALAR.md line 46 (ChatView.vue load-more button fix)
- `vue-3-virtual-scroller-reactive-scrollability.md` — same file, related scroller issues