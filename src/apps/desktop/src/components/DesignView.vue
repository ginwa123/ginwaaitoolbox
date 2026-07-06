<!--
  DesignView — the design canvas main view.

  Renders a tab strip across the top (one tab per page), the selected
  page's HTML in a sandboxed iframe, and an optional chat panel that
  the user can toggle on/off.

  Two-input modes:
    OFF (default): just the canvas. The user can flip the toggle
                   at any time to open the chat.
    ON:           the iframe shrinks (or stays full-height) and a
                   ChatView panel appears below it. The chat is
                   driven by a single `workspace_item_tasks` row
                   dedicated to this design item — the toggle
                   creates the row idempotently (one per
                   workspace_item), reusing any existing "Chat"
                   task on subsequent toggles. Closing the chat
                   (the ChatView emits `close`, or the toggle is
                   flipped OFF) only hides the panel — the
                   underlying task row is left in place so a
                   subsequent toggle ON doesn't need to create
                   another row.

  Plan: docs/superpowers/plans/2026-07-05-design-mode.md (Chunk 6
  + chat-toggle extension).
-->
<script setup lang="ts">
import { onMounted, ref, watch } from 'vue'
import * as api from '../api'
import type { DesignPageFull, DesignPageSummary, Task } from '../api'
import ChatView from './ChatView.vue'

const props = defineProps<{
  workspaceId: string
  item: { id: string; name: string }
}>()

// ─── Canvas state (existing) ───────────────────────────────────────────────

const pages = ref<DesignPageSummary[]>([])
const activePageId = ref<string | null>(null)
const activePageHtml = ref<string>('')
const newPageName = ref('')
const showAddPage = ref(false)
const loading = ref(false)

async function loadPages() {
  if (!props.workspaceId || !props.item.id) return
  try {
    pages.value = await api.listDesignPages(props.workspaceId, props.item.id)
    if (!activePageId.value && pages.value.length > 0) {
      await selectPage(pages.value[0]!.id)
    } else if (pages.value.length === 0) {
      activePageId.value = null
      activePageHtml.value = ''
    }
  } catch (err) {
    console.error('[DesignView] loadPages failed:', err)
  }
}

async function selectPage(pageId: string) {
  activePageId.value = pageId
  try {
    const page: DesignPageFull = await api.getDesignPage(
      props.workspaceId,
      props.item.id,
      pageId,
    )
    activePageHtml.value = page.html
  } catch (err) {
    console.error('[DesignView] selectPage failed:', err)
  }
}

async function addPage() {
  const name = newPageName.value.trim()
  if (!name) return
  // No "create empty page" HTTP endpoint in v1 — pages are created
  // by the LLM via set_design_page. We trigger a chat-style message
  // asking the LLM to create the page, but for now we just create a
  // placeholder by going through set_design_page via the chat.
  // TODO: add POST /design/pages endpoint (see Chunk 6 design note).
  console.warn(
    '[DesignView] addPage(name="' +
      name +
      '") not implemented — LLM must call set_design_page.',
  )
  newPageName.value = ''
  showAddPage.value = false
  void loadPages()
}

async function deletePage(pageId: string) {
  try {
    await api.deleteDesignPage(props.workspaceId, props.item.id, pageId)
    pages.value = pages.value.filter((p) => p.id !== pageId)
    if (activePageId.value === pageId) {
      const next = pages.value[0]
      if (next) {
        await selectPage(next.id)
      } else {
        activePageId.value = null
        activePageHtml.value = ''
      }
    }
  } catch (err) {
    console.error('[DesignView] deletePage failed:', err)
  }
}

// ─── Chat toggle state ────────────────────────────────────────────────────

// One workspace_item_tasks row per design item, name='Chat' (the
// string literal is the discriminator — see DESIGN_CHAT_TASK_NAME
// below). Created lazily on the first toggle ON; subsequent toggles
// reuse it. Resolved eagerly on item.id change so a page refresh
// keeps the toggle in the right state if the user previously had
// the chat open.
const DESIGN_CHAT_TASK_NAME = 'Chat'
const showChat = ref(false)
const chatTaskId = ref<string | null>(null)
const chatLoading = ref(false)
const chatReady = ref(false)

/**
 * Look up the design's chat task (if it exists). Always sets
 * `chatReady = true` so the toggle button can render even when
 * `chatTaskId` is null. Called eagerly on mount so the toggle
 * reflects the persisted state after a page reload.
 */
async function resolveExistingChatTask() {
  if (!props.workspaceId || !props.item.id) {
    chatReady.value = true
    return
  }
  try {
    // Pull only the first page (default 20 is plenty — designs
    // have at most one Chat task; this also keeps it cheap on a
    // workspace with hundreds of tasks).
    const { tasks } = await api.getTasks(props.workspaceId, props.item.id, 20)
    const existing = tasks.find((t) => t.name === DESIGN_CHAT_TASK_NAME)
    if (existing) chatTaskId.value = existing.id
  } catch (err) {
    console.error('[DesignView] resolveExistingChatTask failed:', err)
  } finally {
    chatReady.value = true
  }
}

/**
 * Toggle handler — idempotent ON/OFF. Creates the chat task on
 * the first ON (or reuses the existing one resolved by
 * `resolveExistingChatTask`). OFF just hides the panel; the task
 * row stays in the DB so a future ON is instant.
 */
async function handleToggleChat() {
  if (showChat.value) {
    // OFF path — hide the panel, keep the task row.
    showChat.value = false
    return
  }
  // ON path — need a chat task. Reuse if we already resolved one,
  // otherwise create.
  showChat.value = true // optimistic — flip back to false on failure
  chatLoading.value = true
  try {
    if (!chatTaskId.value) {
      const task: Task = await api.createTask(
        props.workspaceId,
        props.item.id,
        { name: DESIGN_CHAT_TASK_NAME, taskType: 'standard' },
      )
      chatTaskId.value = task.id
    }
  } catch (err) {
    console.error('[DesignView] toggleChat create failed:', err)
    showChat.value = false
  } finally {
    chatLoading.value = false
  }
}

function handleChatClose() {
  // The user clicked ✕ on the ChatView header. Mirror OFF —
  // hide the panel; keep the task row so the toggle stays
  // idempotent across re-opens.
  showChat.value = false
}

// ─── Lifecycle ───────────────────────────────────────────────────────────

onMounted(() => {
  void loadPages()
  void resolveExistingChatTask()
})
watch(() => props.item.id, () => {
  // Switching to a different design item: drop the previous
  // toggle/chat state and re-resolve against the new item.
  showChat.value = false
  chatTaskId.value = null
  chatReady.value = false
  void loadPages()
  void resolveExistingChatTask()
})
</script>

<template>
  <div class="flex flex-col h-full min-h-0">
    <!-- Tab strip + chat toggle -->
    <div
      class="flex items-center gap-1 px-3 py-2 overflow-x-auto border-b shrink-0"
      style="border-color: var(--color-border)"
      data-testid="design-tab-strip"
    >
      <button
        v-for="page in pages"
        :key="page.id"
        @click="selectPage(page.id)"
        :data-testid="`design-tab-${page.id}`"
        class="px-3 py-1.5 rounded-md text-xs flex items-center gap-2 transition-colors shrink-0"
        :style="
          activePageId === page.id
            ? 'background: var(--semantic-active-bg); color: var(--semantic-text);'
            : 'color: var(--semantic-text-dim);'
        "
      >
        {{ page.name }}
        <span
          @click.stop="deletePage(page.id)"
          class="text-xs opacity-50 hover:opacity-100"
          aria-label="Close tab"
        >×</span>
      </button>

      <button
        @click="showAddPage = !showAddPage"
        data-testid="design-tab-add"
        class="px-3 py-1.5 rounded-md text-xs shrink-0"
        style="color: var(--semantic-text-dim);"
      >
        + Add Page
      </button>

      <input
        v-if="showAddPage"
        v-model="newPageName"
        @keyup.enter="addPage"
        @blur="showAddPage = false"
        class="px-2 py-1 rounded-md text-xs shrink-0"
        placeholder="Page name"
        style="
          background: var(--semantic-sidebar-bg);
          color: var(--semantic-text);
          border: 1px solid var(--color-border);
        "
      />

      <div
        v-if="loading"
        class="ml-auto text-xs"
        style="color: var(--semantic-text-dim);"
      >loading…</div>

      <!-- Chat toggle (right-aligned; the highlighted box in the
           screenshot). Disabled until chatReady (i.e., the
           existing-task lookup has resolved). Shows the current
           state via the icon + label. -->
      <button
        v-if="chatReady"
        @click="handleToggleChat"
        :disabled="chatLoading"
        :aria-pressed="showChat"
        data-testid="design-toggle-chat"
        :title="
          showChat
            ? 'Hide chat panel (task row is kept)'
            : chatTaskId
              ? 'Show chat panel'
              : 'Create + show chat panel'
        "
        class="ml-auto px-3 py-1.5 rounded-md text-xs flex items-center gap-1.5 shrink-0 transition-colors disabled:opacity-50"
        :style="
          showChat
            ? 'background: var(--semantic-active-bg); color: var(--semantic-text); border: 1px solid var(--color-border);'
            : 'color: var(--semantic-text-dim); border: 1px solid var(--color-border); background: transparent;'
        "
      >
        <span aria-hidden="true">{{ showChat ? '💬✓' : '💬' }}</span>
        {{ showChat ? 'Chat On' : 'Chat' }}
      </button>
    </div>

    <!-- Body: canvas + (optional) chat panel — horizontal split
         (canvas left, chat right), matching the Kanban layout
         (sidebar | kanban | chatview). When the chat toggle is
         OFF the canvas takes the full width. -->
    <div class="flex-1 min-h-0 flex">
      <!-- Iframe canvas (sandboxed) — always present, shrinks
           to half-width when the chat panel is open. -->
      <div
        class="bg-white"
        :class="
          showChat
            ? 'flex-1 min-h-0 border-r overflow-hidden'
            : 'flex-1 min-h-0 w-full'
        "
        :style="showChat ? 'border-color: var(--color-border)' : ''"
      >
        <iframe
          v-if="activePageHtml"
          :srcdoc="activePageHtml"
          sandbox="allow-scripts"
          class="w-full h-full border-0"
          title="Design canvas"
          data-testid="design-iframe"
        />
        <div
          v-else
          class="w-full h-full flex items-center justify-center"
          style="color: var(--semantic-text-dim); background: var(--semantic-sidebar-bg);"
        >
          <p v-if="pages.length === 0" class="text-sm">
            No pages yet. Ask the LLM to create one
            (<code>set_design_page</code>, e.g. "Create a login page").
          </p>
          <p v-else class="text-sm">Select a page tab to view it.</p>
        </div>
      </div>

      <!-- Chat panel — only mounted when the toggle is ON. The
           ChatView owns its own SSE connection + message rendering;
           we just give it the task_id resolved by the idempotent
           create-or-lookup logic above. The `key` ensures the
           ChatView remounts when the user switches design items
           AND when the same item's task was recreated (defensive:
           if the underlying row was deleted by another client, the
           new chatTaskId triggers a clean remount). The left
           border visually separates it from the canvas (a la the
           Kanban layout's chat pane). -->
      <div
        v-if="showChat && chatTaskId"
        class="flex-1 min-h-0 border-l"
        style="background: var(--semantic-card-bg); border-color: var(--color-border);"
      >
        <ChatView
          :key="'design-chat-' + chatTaskId"
          :chat-id="chatTaskId"
          :chat-name="DESIGN_CHAT_TASK_NAME"
          type="task"
          show-header
          cwd=""
          style="height: 100%"
          @close="handleChatClose"
        />
      </div>
    </div>
  </div>
</template>
