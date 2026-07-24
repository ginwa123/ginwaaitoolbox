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
    - The `srcdoc` is wrapped with a `<style>html,body{margin:0;
      height:100%}</style>` preamble (see `iframeHtml` below) so
      percentage-based layouts inside the user's HTML resolve
      correctly — the iframe body defaults to `height: auto`, which
      would otherwise collapse every `height: 100%` container to 0.
    - The `html` prop is bound through the `iframeHtml` computed so
      Vue's reactivity keeps the srcdoc in sync with `props.html`.
-->
<script setup lang="ts">
import { computed, ref, watch } from 'vue'

const props = withDefaults(
  defineProps<{
    html: string
    editable?: boolean
    // Pointer-events mode for the iframe. The canvas passes
    // 'none' so clicks fall through to the parent element (drag /
    // resize / select); the editable Monaco preview would pass
    // 'auto' so the user can interact with the iframe content.
    pointerEvents?: 'auto' | 'none'
  }>(),
  {
    editable: false,
    pointerEvents: 'auto',
  },
)

const emit = defineEmits<{
  htmlChanged: [html: string]
}>()

// Iframe srcdoc body has no implicit height. Without an explicit
// `height: 100%` on <html>/<body>, any `height: 100%` on the
// user's outer <div> collapses to 0 (because body is `height: auto`),
// and any `position: relative` on that div becomes a 0-height
// containing block for absolutely-positioned children — those
// children collapse too, and the iframe's `background: white`
// (set inline below) shows through, making the element appear blank.
//
// Prepending a stylesheet that forces html/body to fill the iframe
// makes percentage-based layouts (and position:relative containing
// blocks) behave as users expect.
const iframeHtml = computed(
  () => `<style>html,body{margin:0;height:100%;}</style>${props.html}`,
)

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
    :style="{ border: 'none', background: 'white', pointerEvents: props.pointerEvents }"
    :srcdoc="iframeHtml"
    data-testid="design-element-preview"
    @load="onIframeLoad"
  />
</template>