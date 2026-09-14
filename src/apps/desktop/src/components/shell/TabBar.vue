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
import { computed, inject, nextTick, onBeforeUnmount, ref, watch, watchEffect, type Ref } from 'vue'

import {
  fallbackTitle,
  taskChatRendersInItemTab,
  type Tab,
  type TabKind,
} from '../../helpers/tabTarget'
import { parseItemIdWithChat } from '../../helpers/buildItemIdWithChat'
import { useTabsStore } from '../../stores/tabs'
import { useNavigationStore } from '../../stores/navigation'
import { useWorkspacesStore } from '../../stores/workspaces'

const tabsStore = useTabsStore()
const navigationStore = useNavigationStore()
const workspacesStore = useWorkspacesStore()

// LLM worker state, provided by App.vue as `Ref<Record<sessionId, boolean>>`.
// Keyed by session_id — which equals task.id for task chats (Migration 052)
// and the chat session_id for plain chats. Defaults to empty (idle) when no
// provider is mounted (unit tests that mount TabBar standalone).
const processingState = inject<Ref<Record<string, boolean>>>('processingState', ref({}))

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
function itemOf(tab: Tab): {
  chatTaskId: string | null
  item: (typeof workspacesStore.allWorkspaceItems)[number] | null
} {
  const parsed = parseItemIdWithChat(tab.query.itemId ?? '')
  const item =
    workspacesStore.allWorkspaceItems.find((candidate) => candidate.id === parsed.itemId) ?? null
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
  if (tab.kind === 'chat') {
    // The chat flow always knows the ACTIVE chat's name (the sidebar / the
    // session-rename handler write it to the navigation store), so prefer that
    // while this tab is the active chat: a rename shows up immediately, even
    // before the chats list or the SSE feed has caught up.
    if (navigationStore.activeChatId === `chat-${tab.query.session ?? ''}`) {
      const live = navigationStore.activeChatName
      if (live && live !== fallbackTitle('chat')) return live
    }
    return tab.title || fallbackTitle(tab.kind)
  }
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

/**
 * Session ids whose worker state makes this tab "busy".
 *
 * * `chat` tabs (both `view=chat&session=X` and `view=task&task=X`) point at
 *   exactly one session — the worker key is that id.
 * * `workspace` tabs with a `/chat/<taskId>` suffix point at that task's
 *   session (`task.id == session_id` per Migration 052).
 * * A bare item tab (board / canvas, no chat suffix) is busy when ANY of the
 *   item's tasks is running — the tab is the only pointer to those sessions
 *   while the board is in the background. Design pages resolve through the
 *   page's `workspace_item_task_id` first, then fall back to the same
 *   any-task check.
 * * Every other kind (home / settings / overlays) never maps to a session.
 */
function busySessionIdsOf(tab: Tab): string[] {
  if (tab.kind === 'chat') {
    const session = tab.query.session || tab.query.task
    return session ? [session] : []
  }
  if (tab.kind === 'workspace') {
    const parsed = parseItemIdWithChat(tab.query.itemId ?? '')
    if (parsed.chatTaskId) return [parsed.chatTaskId]
    const item =
      workspacesStore.allWorkspaceItems.find((candidate) => candidate.id === parsed.itemId) ?? null
    // A design-page tab (`?view=workspace&itemId=X&pageId=P`) runs its worker
    // on the page's backing task — prefer that single session when known.
    const pageId = tab.query.pageId
    if (pageId && parsed.itemId) {
      const pages = workspacesStore.designPagesByItemId[parsed.itemId] ?? []
      const page = pages.find((candidate) => candidate.id === pageId) ?? null
      const backing = (page as unknown as { workspace_item_task_id?: unknown } | null)
        ?.workspace_item_task_id
      if (typeof backing === 'string' && backing) return [backing]
    }
    const tasks = item?.tasks ?? []
    return tasks
      .map((task) => task.id)
      .filter((id): id is string => typeof id === 'string' && id !== '')
  }
  return []
}

/** True while any session behind this tab has a running worker. */
function isTabBusy(tab: Tab): boolean {
  const state = processingState.value
  for (const id of busySessionIdsOf(tab)) {
    if (state[id]) return true
  }
  return false
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
  if (target && typeof target.closest === 'function' && target.closest('[data-testid="tab-menu"]'))
    return
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
    :style="{
      borderBottom: '1px solid var(--color-border)',
      backgroundColor: 'var(--semantic-content-bg)',
    }"
  >
    <div
      ref="scrollerRef"
      class="flex-1 flex items-stretch overflow-x-auto tab-bar-scroll"
      style="scrollbar-width: none"
      @wheel="onWheel"
    >
      <div
        v-for="(tab, index) in visibleTabs"
        :key="tab.id"
        role="tab"
        :aria-selected="isActive(tab) ? 'true' : 'false'"
        :data-testid="`tab-item-${tab.id}`"
        :data-tab-active="isActive(tab) ? 'true' : 'false'"
        :data-tab-busy="isTabBusy(tab) ? 'true' : 'false'"
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
        <span
          v-if="isTabBusy(tab)"
          :data-testid="`tab-loading-${tab.id}`"
          class="shrink-0 w-1.5 h-1.5 rounded-full animate-pulse"
          :style="{ backgroundColor: 'var(--color-yellow)' }"
          title="Worker running"
          aria-label="Worker running"
          aria-hidden="false"
        />
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
          v-if="isActive(tab) && !isTabBusy(tab)"
          class="absolute left-2 right-2 bottom-0 h-0.5"
          :style="{ backgroundColor: 'var(--color-violet)' }"
          aria-hidden="true"
          data-testid="tab-active-underline"
        />
        <span
          v-if="isTabBusy(tab)"
          class="absolute left-2 right-2 bottom-0 h-0.5 overflow-hidden rounded-full"
          :style="{ background: 'rgb(0 0 0 / 0.06)' }"
          aria-hidden="true"
          :data-testid="`tab-busy-bar-${tab.id}`"
        >
          <span class="tab-busy-bar-track" aria-hidden="true" />
        </span>
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

.tab-busy-bar-track {
  position: absolute;
  inset: 0;
  background: var(--color-yellow);
  box-shadow: 0 0 4px rgb(196 178 138 / 0.5);
  animation: tab-busy-bar-slide 1.4s cubic-bezier(0.4, 0, 0.2, 1) infinite;
  transform: translateX(-100%);
  width: 100%;
}

@keyframes tab-busy-bar-slide {
  0% {
    transform: translateX(-100%);
  }
  100% {
    transform: translateX(100%);
  }
}

@media (prefers-reduced-motion: reduce) {
  .tab-busy-bar-track {
    animation: none;
    transform: none;
    opacity: 0.55;
  }
}
</style>
