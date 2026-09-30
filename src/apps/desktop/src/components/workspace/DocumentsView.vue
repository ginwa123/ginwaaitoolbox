<script setup lang="ts">
// The document surface in the main content area (Migration 095).
//
// Reached from the sidebar's Documents section, which writes `?doc=<id>`
// into the URL. Two modes, one textarea:
//
//   - Read: the rendered markdown.
//   - Edit: a plain textarea over the raw source, with a live preview
//     toggle.
//
// Rendering goes through `helpers/markdown.ts` rather than `marked`
// directly: that helper escapes raw HTML BEFORE parsing, which is the
// repo's XSS model for every non-transcript markdown surface. A document
// body is authored by an agent that may have quoted a file it read, so
// this is not strictly self-XSS-only.
import { computed, ref, watch } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import { useDocumentsStore } from '../../stores/documents'
import { useWorkspacesStore } from '../../stores/workspaces'
import { renderMarkdownHtml } from '../../helpers/markdown'

const props = defineProps<{
  documentId: string
}>()

const documentsStore = useDocumentsStore()
const workspacesStore = useWorkspacesStore()
const router = useRouter()
const route = useRoute()

const editing = ref(false)
const draftTitle = ref('')
const draftContent = ref('')
/** Last persisted body, so `isDirty` compares against what is STORED,
 *  not against the last keystroke. */
const savedContent = ref('')
const savedTitle = ref('')
const showPreview = ref(true)

const workspaceId = computed(() => workspacesStore.activeWorkspaceId)

const document_ = computed(() => documentsStore.findById(props.documentId))

const isDirty = computed(
  () => draftTitle.value !== savedTitle.value || draftContent.value !== savedContent.value,
)

const renderedHtml = computed(() => renderMarkdownHtml(draftContent.value))

// Load on mount AND on id change: a Back/Forward between two documents
// keeps the same component mounted, so an `onMounted`-only fetch would
// leave the previous document's body on screen under the new title.
watch(
  () => props.documentId,
  async (id) => {
    if (!id || !workspaceId.value) return
    const doc = await documentsStore.loadDocument(workspaceId.value, id)
    if (!doc) return
    draftTitle.value = doc.title
    draftContent.value = doc.content
    savedTitle.value = doc.title
    savedContent.value = doc.content
    editing.value = false
  },
  { immediate: true },
)

const startEditing = () => {
  editing.value = true
}

const cancelEditing = () => {
  draftTitle.value = savedTitle.value
  draftContent.value = savedContent.value
  editing.value = false
}

const save = async () => {
  if (!workspaceId.value || !isDirty.value) {
    editing.value = false
    return
  }
  // Send ONLY the fields the user actually changed. Sending both is safe
  // when the draft is fresh, but this view can sit open for a long time
  // and the agent's `edit_document` may have rewritten the body in the
  // meantime — a whole-body PATCH would then silently revert that edit.
  // Partial patches are also what the backend's omitted-vs-empty
  // semantics are built for.
  const patch: { title?: string; content?: string } = {}
  if (draftTitle.value !== savedTitle.value) patch.title = draftTitle.value
  if (draftContent.value !== savedContent.value) patch.content = draftContent.value

  const updated = await documentsStore.updateDocument(workspaceId.value, props.documentId, patch)
  if (updated) {
    savedTitle.value = updated.title
    savedContent.value = updated.content
    editing.value = false
  }
}

const remove = async () => {
  if (!workspaceId.value) return
  const ok = await documentsStore.deleteDocument(workspaceId.value, props.documentId)
  if (!ok) return
  // Leaving a deleted document selected would render a permanently empty
  // view; drop the query param so the app returns to whatever was behind.
  const query = { ...route.query }
  delete query.doc
  router.replace({ path: route.path, query }).catch(() => {})
}
</script>

<template>
  <div class="flex-1 min-h-0 flex flex-col" data-testid="documents-view">
    <!-- Load failure is its own block, not a blank pane. A silently empty
         view is indistinguishable from a deleted document. -->
    <div
      v-if="documentsStore.error && !document_"
      class="p-6 text-body"
      style="color: var(--semantic-error)"
      data-testid="documents-view-error"
    >
      {{ documentsStore.error }}
    </div>

    <div
      v-else-if="!document_"
      class="p-6 text-body"
      style="color: var(--semantic-text-dim)"
      data-testid="documents-view-missing"
    >
      Loading document…
    </div>

    <template v-else>
      <header
        class="shrink-0 flex items-center gap-2 px-4 h-9 border-b"
        style="border-color: var(--color-border)"
      >
        <input
          v-if="editing"
          v-model="draftTitle"
          class="flex-1 bg-transparent outline-none text-lead"
          style="color: var(--semantic-text)"
          data-testid="documents-title-input"
          aria-label="Document title"
        />
        <span
          v-else
          class="text-lead truncate"
          style="color: var(--semantic-text)"
          data-testid="documents-title"
        >
          {{ document_.title }}
        </span>

        <div class="ml-auto flex items-center gap-2 shrink-0">
          <button
            v-if="editing"
            class="text-meta px-2 h-[var(--sb-hit)] transition-opacity hover:opacity-100"
            style="color: var(--semantic-text-dim)"
            data-testid="documents-preview-toggle"
            @click="showPreview = !showPreview"
          >
            {{ showPreview ? 'Hide preview' : 'Show preview' }}
          </button>
          <template v-if="editing">
            <button
              class="text-meta px-2 h-[var(--sb-hit)] transition-opacity hover:opacity-100"
              style="color: var(--semantic-text-dim)"
              data-testid="documents-cancel"
              @click="cancelEditing"
            >
              Cancel
            </button>
            <button
              class="text-meta px-2 h-[var(--sb-hit)] font-medium transition-opacity hover:opacity-100 disabled:opacity-40"
              style="color: var(--semantic-link)"
              data-testid="documents-save"
              :disabled="!isDirty || documentsStore.saving"
              @click="save"
            >
              {{ documentsStore.saving ? 'Saving…' : 'Save' }}
            </button>
          </template>
          <template v-else>
            <button
              class="text-meta px-2 h-[var(--sb-hit)] transition-opacity hover:opacity-100"
              style="color: var(--semantic-text-dim)"
              data-testid="documents-edit"
              @click="startEditing"
            >
              Edit
            </button>
            <button
              class="text-meta px-2 h-[var(--sb-hit)] transition-opacity hover:opacity-100"
              style="color: var(--semantic-error)"
              data-testid="documents-delete"
              @click="remove"
            >
              Delete
            </button>
          </template>
        </div>
      </header>

      <!-- Both panes are always mounted while editing. `v-if` on the
           textarea would drop the caret and the scroll position on every
           preview toggle. -->
      <div class="flex-1 min-h-0 flex" data-testid="documents-body">
        <textarea
          v-if="editing"
          v-model="draftContent"
          class="flex-1 min-w-0 p-4 bg-transparent outline-none resize-none text-body font-mono"
          style="color: var(--semantic-text)"
          data-testid="documents-content-input"
          aria-label="Document content"
          spellcheck="false"
        />
        <div
          v-else
          class="flex-1 min-w-0 p-4 overflow-y-auto markdown-content"
          style="color: var(--semantic-text)"
          data-testid="documents-rendered"
          v-html="renderedHtml"
        />
        <div
          v-if="editing && showPreview"
          class="flex-1 min-w-0 p-4 overflow-y-auto border-l markdown-content"
          style="border-color: var(--color-border); color: var(--semantic-text)"
          data-testid="documents-preview"
          v-html="renderedHtml"
        />
      </div>
    </template>
  </div>
</template>
