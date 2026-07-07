/**
 * Source-level (static-contract) tests for DesignView.
 *
 * Strategy
 * ────────
 * The project doesn't have a Vue behavioral-test infrastructure for
 * components that pull in heavy external libs (panzoom + the SSE
 * bus + ChatView). Mounting the real DesignView.vue in jsdom would
 * require stubbing every transitive dep, and the test would mostly
 * assert Vue's own reactivity rather than our component's
 * contracts. We follow the established pattern from
 * src/__tests__/DesignView.spec.ts (chunk 6) and grep the source
 * for the required strings — fast, deterministic, no flakes.
 *
 * Covered contracts (Chunk 4 of the design-fs-rewrite plan,
 * docs/superpowers/plans/2026-07-06-design-fs-rewrite.md):
 *
 *   1. Imports `panzoom` (the panning/zooming library).
 *   2. Imports the new design-API functions: listDesignPages,
 *      getDesignPage, createDesignPage, updateDesignPage,
 *      deleteDesignPage, listDesignElements, getDesignElement,
 *      createDesignElement, updateDesignElement, moveDesignElement,
 *      resizeDesignElement, deleteDesignElement.
 *   3. Subscribes to the SSE `design` channel (via installSseBus)
 *      so the 5 design_* named events can trigger refetches.
 *   4. Wires the drag handle (pointerdown→pointermove→pointerup)
 *      and resize handle (same pattern) per the plan's chunk 4.
 *   5. Renders "+ Add Page" and "+ Add Element" buttons that call
 *      the appropriate create API functions.
 *   6. Preserves the chunk-6 chat toggle: idempotent ON/OFF, waits
 *      for the eager resolve, flip state atomically after the
 *      await + create.
 */

import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'
import { beforeAll, test } from 'vitest'

const VIEW_PATH = resolve(process.cwd(), 'src/components/DesignView.vue')

let source = ''

beforeAll(() => {
  // Read the source from disk at test-boot. We don't normalize
  // line endings — the repo uses LF, and Vitest runs on Linux.
  source = readFileSync(VIEW_PATH, 'utf8')
})

function has(needle: string): boolean {
  return source.includes(needle)
}

// ─── Chunk 4: design canvas ─────────────────────────────────────────────

test('DesignView imports the panzoom library for canvas pan/zoom', () => {
  if (!has("import panzoom from 'panzoom'")) {
    throw new Error(
      `DesignView.vue must import the 'panzoom' package for canvas ` +
        `pan/zoom support (chunk 4 requirement).`,
    )
  }
})

test('DesignView calls the 9 design API functions used by the canvas UI', () => {
  // The chunk-4 UI surfaces calls this set of 9 API functions. Each
  // ties to a specific user interaction; a regression that drops any
  // one breaks a feature. `getDesignPage` and `updateDesignPage` are
  // exported from api/index.ts (the apiDesign.spec.ts verifies them)
  // but DesignView doesn't need them in v5 because:
  //   - The pages list endpoint returns the full DesignPageSummary
  //     geometry (width/height/x/y), so `getDesignPage` (which
  //     returns DesignPageFull) is only needed when the LLM wants
  //     the full timestamps + workspace_item_id, not for the canvas
  //     render. Page geometry mutations are rare in the UI today
  //     (no page-resize handle is wired in chunk 4), so
  //     `updateDesignPage` is also unused from this component.
  // Both are still part of the 11-function public surface.
  const funcs = [
    'listDesignPages',
    'createDesignPage',
    'deleteDesignPage',
    'listDesignElements',
    'getDesignElement',
    'createDesignElement',
    'moveDesignElement',
    'resizeDesignElement',
    'deleteDesignElement',
  ]
  for (const fn of funcs) {
    if (!has(`${fn}(`)) {
      throw new Error(
        `DesignView.vue must call api.${fn}( somewhere (chunk 4 requirement).`,
      )
    }
  }
})

test('DesignView subscribes to the SSE design channel', () => {
  // The unified SSE factory exposes a `design` channel that fans out
  // the 5 design_* named events. DesignView wires `bus.on('design', …)`
  // in `subscribeSse`. If this grep fails the new event types
  // wouldn't trigger a refetch — the user's drag/resize mutations
  // would only be visible to themselves, not to collaborators.
  if (!has("sseBus.on('design'") && !has('sseBus.on("design"')) {
    throw new Error(
      `DesignView.vue must subscribe to the SSE 'design' channel via ` +
        `installSseBus / sseBus.on('design', …) so the 5 design_* named ` +
        `events trigger a refetch of the affected page / element.`,
    )
  }
})

test('DesignView installs panzoom on mount and disposes on unmount', () => {
  // The panzoom instance must be created in onMounted (after the
  // canvas DOM exists) and disposed in onBeforeUnmount (avoid
  // leaked event listeners).
  const hasMount = has('mountPanzoom()') || has('mountPanzoom)')
  const hasDispose = has('disposePanzoom()') || has('disposePanzoom')
  if (!hasMount) {
    throw new Error(
      `DesignView.vue must call mountPanzoom() in onMounted so the ` +
        `canvas pan/zoom controller is wired when the component is first ` +
        `rendered.`,
    )
  }
  if (!hasDispose) {
    throw new Error(
      `DesignView.vue must call disposePanzoom() in onBeforeUnmount so ` +
        `the panzoom event listeners are released when the component is ` +
        `torn down.`,
    )
  }
})

test('DesignView wires drag and resize pointer handlers per element', () => {
  // Drag + resize work via pointer events (mouse / touch / pen).
  // The handler functions must exist (onElementDragStart,
  // onElementDragMove, onElementDragEnd, onElementResizeStart,
  // onElementResizeMove, onElementResizeEnd) AND be wired in the
  // template with pointerdown/move/up bindings.
  const handlers = [
    'onElementDragStart',
    'onElementDragMove',
    'onElementDragEnd',
    'onElementResizeStart',
    'onElementResizeMove',
    'onElementResizeEnd',
  ]
  for (const h of handlers) {
    if (!has(h)) {
      throw new Error(
        `DesignView.vue must define a '${h}' handler for the ` +
          `drag/resize user interaction (chunk 4 requirement).`,
      )
    }
  }
  // Pointer-event bindings in the template.
  for (const binding of [
    '@pointerdown',
    '@pointermove',
    '@pointerup',
  ]) {
    if (!has(binding)) {
      throw new Error(
        `DesignView.vue must bind '${binding}' on the drag/resize ` +
          `handles so mouse / touch / pen interactions work.`,
      )
    }
  }
})

test('DesignView has data-testid hooks for all interactive elements', () => {
  // Future e2e selectors need testids. The minimum set: tab strip,
  // add-page button, add-element toggle, drag handle, resize handle,
  // element delete button, refresh button.
  const ids = [
    'design-tab-strip',
    'design-tab-add',
    'design-refresh',
    'design-add-element-toggle',
    'design-element-drag-handle',
    'design-element-resize-handle',
    'design-element-delete',
  ]
  for (const id of ids) {
    if (!has(`data-testid="${id}"`)) {
      throw new Error(
        `DesignView.vue must include data-testid="${id}" on the ` +
          `corresponding interactive element.`,
      )
    }
  }
})

test('DesignView applies optimistic UI updates on drag/resize', () => {
  // The drag-end handler must call api.moveDesignElement AND
  // updateLocalElement (the optimistic mutation). Without
  // updateLocalElement the element would snap back to its old
  // position between pointerup and the server response — visible
  // jank on every drag.
  const dragBody = extractHandler('onElementDragEnd')
  if (!dragBody.includes('updateLocalElement')) {
    throw new Error(
      `onElementDragEnd must call updateLocalElement for the optimistic ` +
        `position mutation.`,
    )
  }
  if (!dragBody.includes('moveDesignElement')) {
    throw new Error(
      `onElementDragEnd must call api.moveDesignElement to persist the ` +
        `drag on the server.`,
    )
  }

  const resizeBody = extractHandler('onElementResizeEnd')
  if (!resizeBody.includes('updateLocalElement')) {
    throw new Error(
      `onElementResizeEnd must call updateLocalElement for the optimistic ` +
        `size mutation.`,
    )
  }
  if (!resizeBody.includes('resizeDesignElement')) {
    throw new Error(
      `onElementResizeEnd must call api.resizeDesignElement to persist the ` +
        `resize on the server.`,
    )
  }
})

/**
 * Extract the body of a top-level `<name>(...) { ... }` function
 * declaration from the DesignView source. Used by tests that need
 * to grep inside a specific handler's body (without matching the
 * global `onElementDragStart` declaration).
 */
function extractHandler(name: string): string {
  // Regex: `<name>(...) { ... body ... }` — match across lines.
  const re = new RegExp(
    `(?:async\\s+)?function\\s+${name}\\s*\\([^)]*\\)\\s*(?::[^{]+)?\\s*\\{([\\s\\S]*?)\\n\\}`,
  )
  const match = source.match(re)
  if (!match || !match[1]) {
    throw new Error(
      `DesignView.vue must define '${name}' as a top-level ` +
        `(async) function declaration.`,
    )
  }
  return match[1]
}

// ─── Chunk 6 (preserved): chat toggle ───────────────────────────────────

test('DesignView has the chat-toggle button (design-toggle-chat testid)', () => {
  if (!has('data-testid="design-toggle-chat"')) {
    throw new Error(`DesignView.vue is missing data-testid="design-toggle-chat"`)
  }
})

test('DesignView toggle is idempotent: looks up existing chat task before creating', () => {
  const hasGet = has('api.getTasks') || has('getTasks(')
  const hasCreate = has('api.createTask') || has('createTask(')
  if (!hasGet || !hasCreate) {
    throw new Error(
      `DesignView.vue must call both getTasks and createTask to be ` +
        `idempotent. Found getTasks=${hasGet}, createTask=${hasCreate}.`,
    )
  }
})

test('DesignView toggle creates a task named "Chat" (discriminator)', () => {
  const chats = source.match(/'Chat'/g) ?? []
  if (chats.length < 2) {
    throw new Error(
      `DesignView.vue must reference the literal 'Chat' at least ` +
        `twice (look-up + create). Found ${chats.length}.`,
    )
  }
})

test('DesignView mounts ChatView only when the toggle is ON and a chatTaskId exists', () => {
  const guarded = has('v-if="showChat && chatTaskId"')
  if (!guarded) {
    throw new Error(
      `DesignView.vue must guard the ChatView with ` +
        `'v-if="showChat && chatTaskId"' (both conditions).`,
    )
  }
  if (!has('<ChatView')) {
    throw new Error(`DesignView.vue must render <ChatView ...> somewhere.`)
  }
})

test('DesignView toggle off does NOT delete the task row', () => {
  if (has('api.deleteTask') || has('deleteTask(')) {
    throw new Error(
      `DesignView.vue should not delete the chat task on toggle OFF. ` +
        `Found an api.deleteTask reference. The task row must stay so a ` +
        `future toggle ON is instant.`,
    )
  }
})

test('DesignView watches item.id to reset chat state on design switch', () => {
  // The watch may be written in either form (single- or multi-line).
  // The chunk-4 code uses a multi-line watch because the callback now
  // also disposes the panzoom controller + unsubscribes the SSE bus
  // + re-subscribes; keeping it multi-line aids readability. Match
  // either form by looking for `props.item.id` inside a watch call.
  const hasWatch = /watch\([\s\S]*?props\.item\.id/.test(source)
  if (!hasWatch) {
    throw new Error(
      `DesignView.vue must watch('item.id') and re-run the chat ` +
        `task resolution so the toggle reflects the new design's ` +
        `persisted state.`,
    )
  }
})

test('DesignView toggle awaits the eager resolve before creating a Chat task', () => {
  const fnMatch = source.match(
    /async function handleToggleChat\(\) \{([\s\S]*?)\n\}/,
  )
  if (!fnMatch || !fnMatch[1]) {
    throw new Error(
      `DesignView.vue is missing the async function handleToggleChat() ` +
        `block. The toggle must be async so it can await the eager ` +
        `resolveExistingChatTask lookup.`,
    )
  }
  const body: string = fnMatch[1]

  if (!body.includes('await resolveExistingChatTask')) {
    throw new Error(
      `handleToggleChat must 'await resolveExistingChatTask' when ` +
        `chatReady is false — otherwise a fast click before the ` +
        `eager lookup finishes will create a duplicate Chat task.`,
    )
  }

  const flipPos = body.indexOf('showChat.value = true')
  const awaitPos = body.indexOf('await resolveExistingChatTask')
  const createPos = body.indexOf('api.createTask')
  if (flipPos < 0) {
    throw new Error(
      `handleToggleChat must set 'showChat.value = true' at the end ` +
        `of the ON path (after the await and the create).`,
    )
  }
  if (awaitPos < 0 || awaitPos > flipPos) {
    throw new Error(
      `handleToggleChat must 'await resolveExistingChatTask' BEFORE ` +
        `flipping 'showChat.value = true' — otherwise the panel ` +
        `flashes to the 'Chat On' state with no ChatView mounted.`,
    )
  }
  if (createPos > 0 && createPos > flipPos) {
    throw new Error(
      `handleToggleChat must call 'api.createTask' BEFORE flipping ` +
        `'showChat.value = true' so the ChatView has a valid ` +
        `chatTaskId prop when it mounts.`,
    )
  }
})
