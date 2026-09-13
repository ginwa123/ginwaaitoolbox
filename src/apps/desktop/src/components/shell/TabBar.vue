<script setup lang="ts">
/**
 * The browser-style tab strip.
 *
 * Contract with AppLayout: this component owns the *list* (it calls the
 * tabs store directly — click, close, reorder, new tab) and emits
 * `navigate` whenever `activeTabId` may have moved on. AppLayout is the
 * only place that touches the router, so the URL stays the single source
 * of truth for what renders.
 *
 * Every affordance is deliberately always in the DOM (the close button
 * is dimmed rather than hidden until hover) so behaviour is assertable
 * without simulating hover, and so a keyboard/touch user can reach it.
 */
import { computed, nextTick, onBeforeUnmount, ref, watch, watchEffect } from 'vue'

import { fallbackTitle, taskChatRendersInItemTab, type Tab, type TabKind } from '../../helpers/tabTarget'
import { parseItemIdWithChat } from '../../helpers/buildItemIdWithChat'
import { useTabsStore } from '../../stores/tabs'
import { useWorkspacesStore } from '../../stores/workspaces'

const tabsStore = useTabsStore()
const workspacesStore = useWorkspacesStore()

const emit = defineEmits<{
  /** The active tab may have changed — re-apply the URL. */
  (event: 'navigate'): void
}>()

const scrollerRef = ref<HTMLElement | null>(null)
const dragIndex = ref<number | null>(null)
const menu = ref<{ id: string; x: number; y: number } | null>(null)

const visibleTabs = computed<Tab[]>(() => (tabsStore.enabled ? tabsStore.tabs : []))

const GLYPHS: Record<TabKind, string> = {
  home: '☰',
  chat: '💬',
  workspace: '▦',
  'kanban-settings': '⚙',
  settings: '⚙',
  other: '◻',
}

/** Item types get their own glyph so the coarse `workspace` kind still reads. */
const ITEM_GLYPHS: Record<string, string> = {
  kanban: '▦',
  design: '🎨',
  agent: '🤖',
  routine: '⏱',
  folder: '📁',
  memory: '🧠',
  chat: '💬',
}

/** The workspace item a tab points at, with any `/chat/<taskId>` suffix split off. */
function itemOf(tab: Tab): { chatTaskId: string | null; item: (typeof workspacesStore.allWorkspaceItems)[number] | null } {
  const parsed = parseItemIdWithChat(tab.query.itemId ?? '')
  const item = workspacesStore.allWorkspaceItems.find((candidate) => candidate.id === parsed.itemId) ?? null
  return { chatTaskId: parsed.chatTaskId, item }
}

/**
 * Titles are resolved LIVE, not frozen when the tab opens. The route funnel
 * has no name to give — a deep link, a reload or a plain click all arrive as
 * a bare target — and the workspace tree only lands after the API answers.
 * Reading the stores here means the strip corrects itself the moment the data
 * exists, and the watcher below writes the resolved label back so the
 * persisted title is a real name too.
 */
function titleOf(tab: Tab): string {
  if (tab.kind === 'workspace') {
    const { chatTaskId, item } = itemOf(tab)
    if (item) {
      // kanban/design keep ONE tab whose content is the item + its dialog, so
      // the tab is named after the item; other item types show the task chat,
      // so the task's name is the honest label.
      if (chatTaskId && !taskChatRendersInItemTab(item.item_type)) {
        const task = item.tasks?.find((candidate) => candidate.id === chatTaskId)
        if (task?.name) return task.name
      }
      if (item.name) return item.name
    }
  }
  return tab.title || fallbackTitle(tab.kind)
}

function glyph(tab: Tab): string {
  if (tab.kind === 'workspace') {
    const { item } = itemOf(tab)
    return ITEM_GLYPHS[item?.item_type ?? ''] ?? GLYPHS.workspace
  }
  return GLYPHS[tab.kind] ?? GLYPHS.other
}

function isActive(tab: Tab): boolean {
  return tab.id === tabsStore.activeTabId
}

function tabStyle(tab: Tab): Record<string, string> {
  return {
    borderColor: 'var(--color-border)',
    backgroundColor: isActive(tab) ? 'var(--semantic-content-bg)' : 'transparent',
    color: isActive(tab) ? 'var(--semantic-text)' : 'var(--semantic-text-muted)',
  }
}

function select(id: string): void {
  if (tabsStore.activate(id)) emit('navigate')
}

function closeTab(id: string): void {
  // Closing must never stop a running agent: the session lives on the
  // server and the tab is only a pointer to it.
  if (tabsStore.close(id)) emit('navigate')
}

function closeOthers(id: string): void {
  closeMenu()
  tabsStore.closeOthers(id)
  emit('navigate')
}

function closeToRight(id: string): void {
  closeMenu()
  tabsStore.closeToRight(id)
  emit('navigate')
}

function newTab(): void {
  tabsStore.openHomeTab()
  emit('navigate')
}

function onMouseDown(event: MouseEvent): void {
  // Middle-click must not start autoscroll.
  if (event.button === 1) event.preventDefault()
}

function onAuxClick(event: MouseEvent, id: string): void {
  if (event.button !== 1) return
  event.preventDefault()
  closeTab(id)
}

function openMenu(event: MouseEvent, id: string): void {
  menu.value = { id, x: event.clientX, y: event.clientY }
}

function closeMenu(): void {
  menu.value = null
}

function onWindowKeydown(event: KeyboardEvent): void {
  if (event.key === 'Escape') closeMenu()
}

function onWindowPointerDown(event: MouseEvent): void {
  if (!menu.value) return
  const target = event.target as HTMLElement | null
  // Dispatching on `window` gives a target without DOM element methods.
  if (target && typeof target.closest === 'function' && target.closest('[data-testid="tab-menu"]')) return
  closeMenu()
}

function onDragStart(index: number, event: DragEvent): void {
  dragIndex.value = index
  if (event.dataTransfer) {
    event.dataTransfer.effectAllowed = 'move'
    event.dataTransfer.setData('text/plain', String(index))
  }
}

function onDrop(index: number): void {
  const from = dragIndex.value
  dragIndex.value = null
  if (from === null || from === index) return
  tabsStore.reorder(from, index)
  emit('navigate')
}

function onWheel(event: WheelEvent): void {
  const element = scrollerRef.value
  if (!element) return
  if (Math.abs(event.deltaY) <= Math.abs(event.deltaX)) return
  const before = element.scrollLeft
  element.scrollLeft = before + event.deltaY
  if (element.scrollLeft !== before) event.preventDefault()
}

watch(menu, (opened) => {
  if (opened) {
    window.addEventListener('keydown', onWindowKeydown)
    window.addEventListener('mousedown', onWindowPointerDown)
    return
  }
  window.removeEventListener('keydown', onWindowKeydown)
  window.removeEventListener('mousedown', onWindowPointerDown)
})

watch(
  () => tabsStore.activeTabId,
  async () => {
    await nextTick()
    const element = scrollerRef.value?.querySelector<HTMLElement>('[data-tab-active="true"]')
    if (element && typeof element.scrollIntoView === 'function') {
      element.scrollIntoView({ block: 'nearest', inline: 'nearest' })
    }
  },
)

// Persist labels the stores could resolve, so a reload (before the workspace
// tree has loaded) still shows the item's name instead of a generic fallback.
// `setTabTitle` only writes when the value actually differs, so this settles
// on the second pass.
watchEffect(() => {
  if (!tabsStore.enabled) return
  for (const tab of tabsStore.tabs) {
    const resolved = titleOf(tab)
    if (resolved && resolved !== tab.title) tabsStore.setTabTitle(tab.id, resolved)
  }
})

onBeforeUnmount(() => {
  window.removeEventListener('keydown', onWindowKeydown)
  window.removeEventListener('mousedown', onWindowPointerDown)
})
</script>

<template>
  <div
    v-if="tabsStore.enabled"
    data-testid="tab-bar"
    role="tablist"
    aria-label="Open tabs"
    class="shrink-0 flex items-stretch h-9 overflow-hidden"
    :style="{ borderBottom: '1px solid var(--color-border)', backgroundColor: 'var(--semantic-content-bg)' }"
  >
    <div
      ref="scrollerRef"
      class="flex-1 flex items-stretch overflow-x-auto tab-bar-scroll"
      style="scrollbar-width: none"
    >
      <div
        v-for="(tab, index) in visibleTabs"
        :key="tab.id"
        role="tab"
        :aria-selected="isActive(tab) ? 'true' : 'false'"
        :data-testid="`tab-item-${tab.id}`"
        :data-tab-active="isActive(tab) ? 'true' : 'false'"
        :data-tab-key="tab.key"
        :title="titleOf(tab)"
        draggable="true"
        class="group relative flex items-center gap-1.5 pl-3 pr-1 min-w-[96px] max-w-[220px] border-r cursor-default select-none"
        :style="tabStyle(tab)"
        @click="select(tab.id)"
        @mousedown="onMouseDown"
        @auxclick="onAuxClick($event, tab.id)"
        @contextmenu.prevent="openMenu($event, tab.id)"
        @dragstart="onDragStart(index, $event)"
        @dragover.prevent
        @drop.prevent="onDrop(index)"
      >
        <span aria-hidden="true" class="text-[11px] opacity-70">{{ glyph(tab) }}</span>
        <span class="flex-1 truncate text-xs">{{ titleOf(tab) }}</span>
        <button
          type="button"
          :data-testid="`tab-close-${tab.id}`"
          :aria-label="`Close ${titleOf(tab)}`"
          class="shrink-0 w-5 h-5 rounded flex items-center justify-center text-xs opacity-50 hover:opacity-100"
          style="color: inherit"
          @click.stop="closeTab(tab.id)"
        >
          ×
        </button>
        <span
          v-if="isActive(tab)"
          class="absolute left-2 right-2 bottom-0 h-0.5"
          :style="{ backgroundColor: 'var(--color-violet)' }"
          aria-hidden="true"
          data-testid="tab-active-underline"
        />
      </div>
    </div>

    <button
      type="button"
      data-testid="tab-new"
      aria-label="New tab"
      title="New tab"
      class="shrink-0 w-9 text-sm border-l"
      :style="{ borderColor: 'var(--color-border)', color: 'var(--semantic-text-muted)' }"
      @click="newTab"
    >
      +
    </button>

    <div
      v-if="menu"
      data-testid="tab-menu"
      role="menu"
      class="fixed z-50 py-1 text-xs rounded-lg shadow-lg"
      :style="{
        left: `${menu.x}px`,
        top: `${menu.y}px`,
        backgroundColor: 'var(--semantic-content-bg)',
        border: '1px solid var(--color-border)',
        color: 'var(--semantic-text)',
      }"
    >
      <button
        type="button"
        role="menuitem"
        data-testid="tab-menu-close"
        class="block w-full text-left px-3 py-1.5 hover:opacity-80"
        @click="closeTab(menu.id); closeMenu()"
      >
        Close tab
      </button>
      <button
        type="button"
        role="menuitem"
        data-testid="tab-menu-close-others"
        class="block w-full text-left px-3 py-1.5 hover:opacity-80"
        @click="closeOthers(menu.id)"
      >
        Close other tabs
      </button>
      <button
        type="button"
        role="menuitem"
        data-testid="tab-menu-close-right"
        class="block w-full text-left px-3 py-1.5 hover:opacity-80"
        @click="closeToRight(menu.id)"
      >
        Close tabs to the right
      </button>
    </div>
  </div>
</template>

<style scoped>
.tab-bar-scroll::-webkit-scrollbar {
  /* A visible scrollbar in a 36px strip eats the whole row; the strip is
     scrollable by wheel and by dragging the active tab into view. */
  height: 0;
}
</style>
