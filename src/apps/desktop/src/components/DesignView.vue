<!--
  DesignView — the design canvas main view.

  Renders a tab strip across the top (one tab per page) and the
  selected page's HTML rendered in a sandboxed iframe below. Pure
  preview — there is no source editor in v1 (per the design doc).
  All HTML mutation flows through the LLM tool call.

  Plan: docs/superpowers/plans/2026-07-05-design-mode.md (Chunk 6).
-->
<script setup lang="ts">
import { onMounted, ref, watch } from 'vue'
import * as api from '../api'
import type { DesignPageFull, DesignPageSummary } from '../api'

const props = defineProps<{
  workspaceId: string
  item: { id: string; name: string }
}>()

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

// Lifecycle: reload pages when the user switches to a different
// design item (the component is keyed by item id in AppLayout).
onMounted(loadPages)
watch(() => props.item.id, loadPages)
</script>

<template>
  <div class="flex flex-col h-full min-h-0">
    <!-- Tab strip -->
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
    </div>

    <!-- Iframe canvas (sandboxed) -->
    <div class="flex-1 min-h-0 bg-white">
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
  </div>
</template>