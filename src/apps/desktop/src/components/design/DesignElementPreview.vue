<!--
  DesignElementPreview — sandboxed <iframe> that renders the element's
  stored HTML body.

  Used as the live preview inside the PropertiesPanel and on the canvas
  itself (when the user double-clicks an element for inline edit). The
  iframe is sandboxed to allow scripts only (no same-origin, no top-
  navigation) so the user-pasted HTML can't reach the host document.

  Public API:
    props:
      html      string   the element's stored HTML body
      editable  boolean  when true, the iframe body becomes
                         contentEditable; on blur, the new innerHTML
                         is emitted as htmlChanged. Default false.
    emits:
      htmlChanged [html: string]

  Test contract: data-testid="design-element-preview" on the iframe.

  Notes:
    - We deliberately do NOT use postMessage for the read-back; the
      blur event on the iframe fires inside the parent window and the
      inner body's innerHTML is readable via the iframe contentDocument
      when sandbox is "allow-same-origin" — but we use
      "allow-scripts" only, so we listen to a custom "previewChanged"
      event the inner script can fire (or, for the readonly case,
      simply no read-back).
    - When `editable=true`, the parent's contenteditable on the body
      element makes the iframe content editable; the parent listens
      for blur and reads `iframe.contentDocument.body.innerHTML`.
    - The srcdoc is bound directly — Vue's reactivity keeps it in
      sync with the `html` prop.
-->
<script setup lang="ts">
import { ref, watch } from 'vue'

const props = withDefaults(
  defineProps<{
    html: string
    editable?: boolean
  }>(),
  {
    editable: false,
  },
)

const emit = defineEmits<{
  htmlChanged: [html: string]
}>()

const iframeRef = ref<HTMLIFrameElement | null>(null)

// Wire up contenteditable + blur handler on the iframe's body once
// the iframe has loaded its srcdoc. We can't do this in `onMounted`
// because the srcdoc is async — by the time `iframeRef.value` is
// attached, the inner document may not exist yet. A `load` listener
// on the iframe fires after srcdoc parse completes.
const onIframeLoad = (): void => {
  if (!props.editable) return
  const iframe = iframeRef.value
  if (!iframe) return
  const doc = iframe.contentDocument
  if (!doc) return
  const body = doc.body
  if (!body) return
  body.contentEditable = 'true'
  body.style.outline = 'none'
  body.addEventListener('blur', () => {
    emit('htmlChanged', body.innerHTML)
  })
}

// Re-attach the listener when `editable` flips from false to true
// (the user just opened the edit panel). The load event fires only
// once per srcdoc change, so this is necessary for the
// readonly→editable transition.
watch(
  () => props.editable,
  (next, prev) => {
    if (next && !prev) {
      // nextTick: the srcdoc has already loaded; attach directly.
      onIframeLoad()
    }
  },
)
</script>

<template>
  <iframe
    ref="iframeRef"
    sandbox="allow-scripts"
    class="w-full h-full"
    style="border: none; background: white;"
    :srcdoc="html"
    data-testid="design-element-preview"
    @load="onIframeLoad"
  />
</template>