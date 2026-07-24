<!--
  PropertiesPanel — the right-rail form for editing the selected
  element's properties. Mirrors the Figma/Sketch "design" pane.

  Layout (top → bottom):
    1. Header — element name + type label.
    2. Empty state — when no element is selected, show a hint.
    3. Geometry section — x/y/width/height/rotation inputs.
    4. Style section — fill color, stroke color + width, corner radius,
       opacity.
    5. Type-specific section — text_content + text_style for text,
       image_url for image.
    6. HTML section — Monaco editor (lazy-loaded) for the element's
       stored HTML body, with a save button.
    7. Delete button (with confirm) — bottom of the panel.

  Form inputs are bound to the `element` prop via v-model.number for
  numerics and v-model for strings; every change fires `update` with
  the patch. The parent (DesignView) is responsible for debouncing
  (text inputs would otherwise fire 1+/char; the parent's store
  action handles the API call).

  The Monaco editor is loaded lazily on first expand via dynamic
  `import('monaco-editor')`. The import is gated on user click so
  we don't pay the ~3 MB download cost until the user actually wants
  to edit HTML. If monaco-editor is not installed (defensive), we
  fall back to a <textarea> with a TODO comment.

  Public API:
    props:
      element   DesignElement | null   the selected element (or null)
      readonly  boolean                when true, all inputs are disabled
    emits:
      update      [patch: Partial<DesignElement>]
      htmlChanged [html: string]
      delete      [elementId: string]

  Test contract:
    data-testid="properties-panel" on the wrapper
    data-testid="properties-panel-empty" on the empty state
    data-testid="properties-input-{name}" on each input
    data-testid="properties-toggle-html-editor" on the expand button
    data-testid="properties-html-editor" on the Monaco container
    data-testid="properties-delete-button" on the delete button
-->
<script setup lang="ts">
import { computed, onBeforeUnmount, ref, watch } from 'vue'
import type { DesignElement } from '../../api'

const props = withDefaults(
  defineProps<{
    element: DesignElement | null
    readonly?: boolean
    // When true, the parent canvas is in Preview mode (toggle in the
    // canvas header bar). The form fields are hidden and replaced
    // with a "you're previewing" banner — the user is interacting
    // with the mockup, not editing its metadata.
    previewMode?: boolean
  }>(),
  {
    readonly: false,
    previewMode: false,
  },
)

const emit = defineEmits<{
  update: [patch: Partial<DesignElement>]
  htmlChanged: [html: string]
  delete: [elementId: string]
}>()

// ─── Form field handlers ───────────────────────────────────────────────
//
// Each handler builds a patch object and emits `update`. We use
// dedicated handlers (instead of inline @change on every input) so
// the emit always carries the exact field that changed — the
// parent's store action treats it as a sparse merge.

type NumericField = 'x' | 'y' | 'width' | 'height' | 'rotation' | 'stroke_width' | 'corner_radius' | 'opacity'
type StringField = 'name' | 'fill' | 'stroke' | 'text_content' | 'text_style' | 'image_url'

const handleNumericChange = (field: NumericField, value: number): void => {
  emit('update', { [field]: value } as Partial<DesignElement>)
}

const handleStringChange = (field: StringField, value: string): void => {
  emit('update', { [field]: value } as Partial<DesignElement>)
}

// ─── Confirm-before-delete state ───────────────────────────────────────

const showDeleteConfirm = ref(false)

const handleDeleteClick = (): void => {
  if (props.readonly) return
  if (!props.element) return
  showDeleteConfirm.value = true
}

const handleDeleteConfirm = (): void => {
  if (!props.element) return
  emit('delete', props.element.id)
  showDeleteConfirm.value = false
}

const handleDeleteCancel = (): void => {
  showDeleteConfirm.value = false
}

// ─── HTML editor (Monaco lazy-load) ────────────────────────────────────

const htmlExpanded = ref(false)
const htmlDraft = ref('')
const monacoEditor = ref<any | null>(null)
const monacoContainerRef = ref<HTMLDivElement | null>(null)
const monacoLoadError = ref<string | null>(null)

// When the user expands the editor and the element changes, seed the
// draft with the current HTML body. We don't auto-pull on every
// element switch — that would clobber the user's in-progress edit.
// Instead, we pull on (a) first expand and (b) explicit element
// change while collapsed.
watch(
  () => props.element?.id,
  () => {
    if (!htmlExpanded.value && props.element) {
      htmlDraft.value = props.element.text_content || ''
    }
  },
)

watch(htmlExpanded, async (expanded) => {
  if (!expanded) return
  if (!props.element) return
  // Seed the draft on first expand.
  htmlDraft.value = props.element.text_content || ''

  // Lazy-load Monaco on first expand. Dynamic import is the only way
  // to defer the ~3 MB bundle; bundlers will code-split at this
  // import call.
  if (monacoEditor.value) return
  try {
    const monaco = await import('monaco-editor')
    // Disable web workers — Monaco's default worker setup doesn't
    // work in our Vite/jsdom environment; the simpler approach is to
    // run monaco in the main thread (slightly slower autocomplete
    // but no worker setup). For the v1 design use case (single-user,
    // small HTML snippets) this is fine.
    // @ts-ignore — monaco-typescript doesn't expose `getLanguages` for
    // type narrowing here; we just disable workers via the global.
    if (typeof window !== 'undefined') {
      ;(window as any).MonacoEnvironment = {
        getWorker: () => ({
          postMessage: () => {},
          terminate: () => {},
          addEventListener: () => {},
          removeEventListener: () => {},
        }),
      }
    }
    if (!monacoContainerRef.value) return
    const editor = monaco.editor.create(monacoContainerRef.value, {
      value: htmlDraft.value,
      language: 'html',
      theme: 'vs-dark',
      automaticLayout: true,
      minimap: { enabled: false },
      fontSize: 12,
      lineNumbers: 'on',
      wordWrap: 'on',
    })
    editor.onDidChangeModelContent(() => {
      htmlDraft.value = editor.getValue()
    })
    monacoEditor.value = editor
    monacoLoadError.value = null
  } catch (err) {
    // Monaco not installed or failed to load — fall back to textarea
    // (the v-if on the textarea fallback covers this).
    monacoLoadError.value = err instanceof Error ? err.message : String(err)
    monacoEditor.value = null
  }
})

const handleHtmlSave = (): void => {
  emit('htmlChanged', htmlDraft.value)
}

const handleHtmlCancel = (): void => {
  htmlDraft.value = props.element?.text_content || ''
  if (monacoEditor.value) {
    monacoEditor.value.setValue(htmlDraft.value)
  }
}

// Tear down the Monaco editor on component unmount to release its
// listeners and DOM references.
onBeforeUnmount(() => {
  if (monacoEditor.value) {
    monacoEditor.value.dispose()
    monacoEditor.value = null
  }
})

// ─── Computed helpers ──────────────────────────────────────────────────

const isTextElement = computed(() => props.element?.type === 'text')
const isImageElement = computed(() => props.element?.type === 'image')
const showGeometrySection = computed(() => props.element !== null)
const showStyleSection = computed(() => props.element !== null)
const showTypeSpecificSection = computed(
  () => isTextElement.value || isImageElement.value,
)
</script>

<template>
  <div
    class="properties-panel flex flex-col h-full min-h-0 overflow-y-auto"
    style="scrollbar-width: thin;"
    data-testid="properties-panel"
  >
    <!-- ─── Preview-mode banner ────────────────────────────────────── -->
    <!--
      Shown when the parent canvas is in Preview mode (toggle in
      the canvas header bar). Replaces the entire form with a
      compact hint — the user is interacting with the rendered HTML,
      not editing element metadata. Pressing Esc (handled in
      DesignView.vue) exits Preview and restores the form.
    -->
    <div
      v-if="previewMode"
      class="flex-1 flex items-center justify-center p-6 text-sm"
      style="color: var(--semantic-text-dim);"
      data-testid="properties-panel-preview"
    >
      <div class="text-center">
        <div class="text-3xl mb-2" aria-hidden="true">▶</div>
        <div>Previewing — interact with the mockup</div>
        <div class="text-xs mt-1" style="opacity: 0.7;">
          Press Esc to return to editing
        </div>
      </div>
    </div>

    <!-- ─── Empty state ────────────────────────────────────────────── -->
    <div
      v-if="!element && !previewMode"
      class="flex-1 flex items-center justify-center p-6 text-sm"
      style="color: var(--semantic-text-dim);"
      data-testid="properties-panel-empty"
    >
      <div class="text-center">
        <div class="text-3xl mb-2" aria-hidden="true">◇</div>
        <div>Select an element to edit its properties</div>
      </div>
    </div>

    <template v-if="element && !previewMode">
      <!-- ─── Header ───────────────────────────────────────────────── -->
      <div
        class="px-4 py-3 shrink-0"
        style="border-bottom: 1px solid var(--color-border);"
      >
        <div class="text-xs" style="color: var(--semantic-text-dim);">
          {{ element.type }}
        </div>
        <input
          type="text"
          :value="element.name"
          :disabled="readonly"
          data-testid="properties-input-name"
          class="w-full bg-transparent text-base font-semibold outline-none mt-1"
          style="color: var(--semantic-text);"
          placeholder="Element name"
          @change="(e) => handleStringChange('name', (e.target as HTMLInputElement).value)"
        />
      </div>

      <!-- ─── Geometry section ─────────────────────────────────────── -->
      <section
        v-if="showGeometrySection"
        class="px-4 py-3"
        style="border-bottom: 1px solid var(--color-border);"
        data-testid="properties-section-geometry"
      >
        <div class="text-xs font-semibold mb-2" style="color: var(--semantic-text-dim);">
          Geometry
        </div>
        <div class="grid grid-cols-2 gap-2">
          <label class="text-xs" style="color: var(--semantic-text-dim);">
            X
            <input
              type="number"
              :value="element.x"
              :disabled="readonly"
              data-testid="properties-input-x"
              class="w-full mt-0.5 px-2 py-1 rounded text-sm outline-none"
              style="background-color: var(--semantic-sidebar-bg); border: 1px solid var(--color-border); color: var(--semantic-text);"
              @change="(e) => handleNumericChange('x', Number((e.target as HTMLInputElement).value))"
            />
          </label>
          <label class="text-xs" style="color: var(--semantic-text-dim);">
            Y
            <input
              type="number"
              :value="element.y"
              :disabled="readonly"
              data-testid="properties-input-y"
              class="w-full mt-0.5 px-2 py-1 rounded text-sm outline-none"
              style="background-color: var(--semantic-sidebar-bg); border: 1px solid var(--color-border); color: var(--semantic-text);"
              @change="(e) => handleNumericChange('y', Number((e.target as HTMLInputElement).value))"
            />
          </label>
          <label class="text-xs" style="color: var(--semantic-text-dim);">
            W
            <input
              type="number"
              :value="element.width"
              :disabled="readonly"
              data-testid="properties-input-width"
              class="w-full mt-0.5 px-2 py-1 rounded text-sm outline-none"
              style="background-color: var(--semantic-sidebar-bg); border: 1px solid var(--color-border); color: var(--semantic-text);"
              @change="(e) => handleNumericChange('width', Number((e.target as HTMLInputElement).value))"
            />
          </label>
          <label class="text-xs" style="color: var(--semantic-text-dim);">
            H
            <input
              type="number"
              :value="element.height"
              :disabled="readonly"
              data-testid="properties-input-height"
              class="w-full mt-0.5 px-2 py-1 rounded text-sm outline-none"
              style="background-color: var(--semantic-sidebar-bg); border: 1px solid var(--color-border); color: var(--semantic-text);"
              @change="(e) => handleNumericChange('height', Number((e.target as HTMLInputElement).value))"
            />
          </label>
          <label class="col-span-2 text-xs" style="color: var(--semantic-text-dim);">
            Rotation (deg)
            <input
              type="number"
              :value="element.rotation"
              :disabled="readonly"
              data-testid="properties-input-rotation"
              class="w-full mt-0.5 px-2 py-1 rounded text-sm outline-none"
              style="background-color: var(--semantic-sidebar-bg); border: 1px solid var(--color-border); color: var(--semantic-text);"
              @change="(e) => handleNumericChange('rotation', Number((e.target as HTMLInputElement).value))"
            />
          </label>
        </div>
      </section>

      <!-- ─── Style section ────────────────────────────────────────── -->
      <section
        v-if="showStyleSection"
        class="px-4 py-3"
        style="border-bottom: 1px solid var(--color-border);"
        data-testid="properties-section-style"
      >
        <div class="text-xs font-semibold mb-2" style="color: var(--semantic-text-dim);">
          Style
        </div>
        <div class="space-y-2">
          <label class="block text-xs" style="color: var(--semantic-text-dim);">
            Fill color
            <input
              type="text"
              :value="element.fill"
              :disabled="readonly"
              placeholder="(none)"
              data-testid="properties-input-fill"
              class="w-full mt-0.5 px-2 py-1 rounded text-sm outline-none font-mono"
              style="background-color: var(--semantic-sidebar-bg); border: 1px solid var(--color-border); color: var(--semantic-text);"
              @change="(e) => handleStringChange('fill', (e.target as HTMLInputElement).value)"
            />
          </label>
          <div class="grid grid-cols-2 gap-2">
            <label class="text-xs" style="color: var(--semantic-text-dim);">
              Stroke
              <input
                type="text"
                :value="element.stroke"
                :disabled="readonly"
                placeholder="(none)"
                data-testid="properties-input-stroke"
                class="w-full mt-0.5 px-2 py-1 rounded text-sm outline-none font-mono"
                style="background-color: var(--semantic-sidebar-bg); border: 1px solid var(--color-border); color: var(--semantic-text);"
                @change="(e) => handleStringChange('stroke', (e.target as HTMLInputElement).value)"
              />
            </label>
            <label class="text-xs" style="color: var(--semantic-text-dim);">
              Width
              <input
                type="number"
                :value="element.stroke_width"
                :disabled="readonly"
                data-testid="properties-input-stroke-width"
                class="w-full mt-0.5 px-2 py-1 rounded text-sm outline-none"
                style="background-color: var(--semantic-sidebar-bg); border: 1px solid var(--color-border); color: var(--semantic-text);"
                @change="(e) => handleNumericChange('stroke_width', Number((e.target as HTMLInputElement).value))"
              />
            </label>
          </div>
          <div class="grid grid-cols-2 gap-2">
            <label class="text-xs" style="color: var(--semantic-text-dim);">
              Corner radius
              <input
                type="number"
                :value="element.corner_radius"
                :disabled="readonly"
                data-testid="properties-input-corner-radius"
                class="w-full mt-0.5 px-2 py-1 rounded text-sm outline-none"
                style="background-color: var(--semantic-sidebar-bg); border: 1px solid var(--color-border); color: var(--semantic-text);"
                @change="(e) => handleNumericChange('corner_radius', Number((e.target as HTMLInputElement).value))"
              />
            </label>
            <label class="text-xs" style="color: var(--semantic-text-dim);">
              Opacity (0-1)
              <input
                type="number"
                step="0.05"
                min="0"
                max="1"
                :value="element.opacity"
                :disabled="readonly"
                data-testid="properties-input-opacity"
                class="w-full mt-0.5 px-2 py-1 rounded text-sm outline-none"
                style="background-color: var(--semantic-sidebar-bg); border: 1px solid var(--color-border); color: var(--semantic-text);"
                @change="(e) => handleNumericChange('opacity', Number((e.target as HTMLInputElement).value))"
              />
            </label>
          </div>
        </div>
      </section>

      <!-- ─── Type-specific section ────────────────────────────────── -->
      <section
        v-if="showTypeSpecificSection"
        class="px-4 py-3"
        style="border-bottom: 1px solid var(--color-border);"
        data-testid="properties-section-type"
      >
        <div class="text-xs font-semibold mb-2" style="color: var(--semantic-text-dim);">
          {{ element.type === 'text' ? 'Text' : 'Image' }}
        </div>
        <template v-if="isTextElement">
          <label class="block text-xs mb-2" style="color: var(--semantic-text-dim);">
            Text content
            <textarea
              :value="element.text_content"
              :disabled="readonly"
              rows="3"
              data-testid="properties-input-text-content"
              class="w-full mt-0.5 px-2 py-1 rounded text-sm outline-none"
              style="background-color: var(--semantic-sidebar-bg); border: 1px solid var(--color-border); color: var(--semantic-text);"
              @change="(e) => handleStringChange('text_content', (e.target as HTMLTextAreaElement).value)"
            />
          </label>
          <label class="block text-xs" style="color: var(--semantic-text-dim);">
            Text style (font-family)
            <input
              type="text"
              :value="element.text_style"
              :disabled="readonly"
              placeholder="sans-serif"
              data-testid="properties-input-text-style"
              class="w-full mt-0.5 px-2 py-1 rounded text-sm outline-none font-mono"
              style="background-color: var(--semantic-sidebar-bg); border: 1px solid var(--color-border); color: var(--semantic-text);"
              @change="(e) => handleStringChange('text_style', (e.target as HTMLInputElement).value)"
            />
          </label>
        </template>
        <template v-else-if="isImageElement">
          <label class="block text-xs" style="color: var(--semantic-text-dim);">
            Image URL
            <input
              type="text"
              :value="element.image_url"
              :disabled="readonly"
              placeholder="https://..."
              data-testid="properties-input-image-url"
              class="w-full mt-0.5 px-2 py-1 rounded text-sm outline-none font-mono"
              style="background-color: var(--semantic-sidebar-bg); border: 1px solid var(--color-border); color: var(--semantic-text);"
              @change="(e) => handleStringChange('image_url', (e.target as HTMLInputElement).value)"
            />
          </label>
        </template>
      </section>

      <!-- ─── HTML editor section (lazy Monaco) ────────────────────── -->
      <section
        class="px-4 py-3"
        style="border-bottom: 1px solid var(--color-border);"
        data-testid="properties-section-html"
      >
        <button
          type="button"
          :disabled="readonly"
          data-testid="properties-toggle-html-editor"
          class="w-full text-left text-xs font-semibold flex items-center gap-2 mb-2 transition-colors"
          style="color: var(--semantic-text-dim);"
          @click="htmlExpanded = !htmlExpanded"
        >
          <span aria-hidden="true">{{ htmlExpanded ? '▼' : '▶' }}</span>
          <span>HTML Body (Monaco editor)</span>
        </button>
        <div v-if="htmlExpanded" class="space-y-2">
          <div
            v-if="!monacoLoadError && monacoEditor"
            ref="monacoContainerRef"
            data-testid="properties-html-editor"
            style="height: 200px; border: 1px solid var(--color-border); border-radius: 4px; overflow: hidden;"
          />
          <!-- Fallback textarea when Monaco failed to load -->
          <div v-else>
            <textarea
              v-model="htmlDraft"
              :disabled="readonly"
              rows="8"
              data-testid="properties-html-fallback-textarea"
              class="w-full px-2 py-1 rounded text-xs font-mono outline-none"
              style="background-color: var(--semantic-sidebar-bg); border: 1px solid var(--color-border); color: var(--semantic-text);"
              :placeholder="monacoLoadError ? `Monaco failed to load: ${monacoLoadError}` : 'Edit HTML body'"
            />
            <div
              v-if="monacoLoadError"
              class="text-[10px] mt-1"
              style="color: var(--semantic-text-dim);"
            >
              TODO: install monaco-editor for syntax highlighting
            </div>
          </div>
          <div class="flex gap-2 justify-end">
            <button
              type="button"
              :disabled="readonly"
              data-testid="properties-html-cancel"
              class="px-2 py-1 rounded text-xs"
              style="background-color: var(--semantic-card-bg); border: 1px solid var(--color-border); color: var(--semantic-text-muted);"
              @click="handleHtmlCancel"
            >Cancel</button>
            <button
              type="button"
              :disabled="readonly"
              data-testid="properties-html-save"
              class="px-2 py-1 rounded text-xs"
              style="background: linear-gradient(135deg, var(--color-violet), var(--color-blue)); color: var(--color-bg);"
              @click="handleHtmlSave"
            >Save</button>
          </div>
        </div>
      </section>

      <!-- ─── Delete section (with confirm) ────────────────────────── -->
      <section
        class="px-4 py-3 mt-auto"
        data-testid="properties-section-delete"
      >
        <div v-if="!showDeleteConfirm">
          <button
            type="button"
            :disabled="readonly"
            data-testid="properties-delete-button"
            class="w-full px-3 py-1.5 rounded text-sm font-medium transition-all"
            style="background-color: rgba(220, 38, 38, 0.18); color: rgb(248, 113, 113); border: 1px solid rgba(220, 38, 38, 0.4);"
            @click="handleDeleteClick"
          >
            Delete element
          </button>
        </div>
        <div
          v-else
          class="space-y-2"
          data-testid="properties-delete-confirm"
        >
          <div class="text-xs" style="color: var(--semantic-text);">
            Delete "{{ element.name }}"? This cannot be undone.
          </div>
          <div class="flex gap-2">
            <button
              type="button"
              data-testid="properties-delete-cancel"
              class="flex-1 px-2 py-1 rounded text-xs"
              style="background-color: var(--semantic-card-bg); border: 1px solid var(--color-border); color: var(--semantic-text-muted);"
              @click="handleDeleteCancel"
            >Cancel</button>
            <button
              type="button"
              data-testid="properties-delete-confirm"
              class="flex-1 px-2 py-1 rounded text-xs font-medium"
              style="background-color: rgba(220, 38, 38, 0.6); color: white;"
              @click="handleDeleteConfirm"
            >Delete</button>
          </div>
        </div>
      </section>
    </template>
  </div>
</template>

<style scoped>
.properties-panel :deep(div.overflow-y-auto)::-webkit-scrollbar {
  width: 6px;
}
.properties-panel :deep(div.overflow-y-auto)::-webkit-scrollbar-track {
  background: transparent;
}
.properties-panel :deep(div.overflow-y-auto)::-webkit-scrollbar-thumb {
  background: var(--color-border);
  border-radius: 3px;
}
</style>