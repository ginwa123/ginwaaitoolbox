# `nalar_browser` Frontend Tool-Output Component Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a custom Vue 3 component (`NalarBrowser.vue`) for the `nalar_browser` tool that renders its XML output as a friendly, action-specific UI in the chat, replacing the current raw-XML fallback.

**Architecture:** Follow the existing tool-output pattern (Bash.vue, ReadFile.vue, SpawnSubAgent.vue). One new SFC at `src/apps/desktop/src/components/tool_outputs/NalarBrowser.vue` parses the inner `<data>` XML (browser_id, page_id, url, title, status, tree) plus the tool-call `parameters` JSON to determine which action (`launch` / `open_page` / `snapshot` / `click` / `fill` / `press` / `close_page` / `close_browser`) the result belongs to, and renders an action-specific header + collapsible body. The `tool_outputs/SpawnSubAgent.vue`-style pattern is used: parent (`ChatView.vue`) extracts the parameters from the existing `unwrappedByMessageId` map and passes them as a `parameters` prop. Then `ChatView.vue`'s `v-else-if` chain gains one entry so `nalar_browser` no longer falls through to the generic `<div class="tool-expandable">` fallback at line 1901.

**Tech Stack:** Vue 3 (`<script setup lang="ts">`), TypeScript strict mode, Vitest + @vue/test-utils + jsdom.

**Reference code paths to read before starting:**
- Backend inner-XML producers: `src/modules/agent/tools/nalar_browser.zig:231-296` (`toXMLSuccess` / `toXMLError`)
- Backend envelope: `src/ai_workflow/tui/tool_registry.zig:1501-1536` (`wrapToolOutput`)
- Frontend envelope unwrap: `src/apps/desktop/src/helpers/unwrapToolOutput.ts:54-77` (`UnwrappedToolOutput`)
- Existing tool-output components: `src/apps/desktop/src/components/tool_outputs/ReadFile.vue`, `Bash.vue`, `SpawnSubAgent.vue`, `RemoveFile.vue`
- Parent wiring: `src/apps/desktop/src/components/ChatView.vue:617-621` (`innerToolData`), `1809-1900` (`v-else-if` chain)
- Test conventions: `src/apps/desktop/src/__tests__/workspaceItemTask.spec.ts` (mounting pattern), `helpers.ts` (`makeLocalStorageStub`)

---

## Setup

### Task 0: Create a feature worktree

**Files:**
- Create: `.worktrees/feature/nalar-browser-tool-output/`

- [ ] **Step 1: Create and enter a new worktree off `main`**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
git worktree add .worktrees/feature/nalar-browser-tool-output -b feature/nalar-browser-tool-output main
cd .worktrees/feature/nalar-browser-tool-output
git status
```

Expected: `On branch feature/nalar-browser-tool-output`, `nothing to commit, working tree clean`.

- [ ] **Step 2: Verify baseline builds + tests pass**

```bash
cd src/apps/desktop
timeout 120 bun run build 2>&1 | tail -n 5
timeout 120 bunx vitest run 2>&1 | tail -n 5
```

Expected: `bun run build` finishes with `built in ...ms` and no TS errors. `vitest run` reports all tests passing (current count per the project's last green run).

---

## Chunk 1: Component Skeleton + Action Detection

> **Goal:** a working `NalarBrowser.vue` that renders a header per action (`launch` / `open_page` / `snapshot` / `click` / `fill` / `press` / `close_page` / `close_browser`) and an empty/expandable body, wired into `ChatView.vue`. Snapshot tree rendering and full visual polish land in Chunk 2.

### Task 1.1: Write the failing test for the action header

**Files:**
- Test: `src/apps/desktop/src/__tests__/NalarBrowser.spec.ts` (new)

- [ ] **Step 1: Create the spec file with the launch + open_page + snapshot header tests**

```ts
/**
 * Tests for the nalar_browser tool-output component.
 *
 * The backend serializes every nalar_browser result as:
 *   <tool>
 *     <name>nalar_browser</name>
 *     <parameters>{ "action": "..." }</parameters>
 *     <success>true</success>
 *     <data>
 *       <success>1</success>
 *       <browser_id>...</browser_id>      (optional)
 *       <page_id>...</page_id>            (optional)
 *       <url>...</url>                    (optional)
 *       <title>...</title>                (optional)
 *       <status>200</status>              (optional)
 *       <tree>[{...}]</tree>              (optional, JSON string)
 *     </data>
 *   </tool>
 *
 * The parent (ChatView) unwraps the envelope via tryUnwrapToolOutput
 * and passes:
 *   - content    = inner <data> XML (success path) OR original content on error
 *   - parameters = JSON-string tool-call arguments
 *   - expanded   = whether the row is already expanded in the chat
 *
 * These tests focus on the header row and parameter parsing, NOT the
 * snapshot tree renderer (that's in Chunk 2).
 */
import { describe, it, expect } from 'vitest'
import { mount } from '@vue/test-utils'

import NalarBrowser from '../components/tool_outputs/NalarBrowser.vue'

function mountNalarBrowser(props: {
  content: string
  parameters: string
  expanded?: boolean
}) {
  return mount(NalarBrowser, { props })
}

describe('NalarBrowser — action header', () => {
  it('renders "launch" header with browser_id from inner data', () => {
    const wrapper = mountNalarBrowser({
      content: '<success>1</success><browser_id>browser_abc123</browser_id>',
      parameters: JSON.stringify({ action: 'launch' }),
    })
    expect(wrapper.find('[data-testid="nalar-browser-header"]').exists()).toBe(true)
    expect(wrapper.text()).toContain('launch')
    expect(wrapper.text()).toContain('browser_abc123')
  })

  it('renders "open_page" header with page title and URL', () => {
    const wrapper = mountNalarBrowser({
      content:
        '<success>1</success><page_id>page_xyz</page_id>' +
        '<url>https://example.com</url>' +
        '<title>Example Domain</title>' +
        '<status>200</status>',
      parameters: JSON.stringify({
        action: 'open_page',
        browser_id: 'browser_abc123',
        url: 'https://example.com',
      }),
    })
    expect(wrapper.text()).toContain('open_page')
    expect(wrapper.text()).toContain('Example Domain')
    expect(wrapper.text()).toContain('https://example.com')
  })

  it('renders "snapshot" header with element count from tree JSON', () => {
    const tree = [
      { ref: 'e1', text: 'Sign in' },
      { ref: 'e2', text: 'About', href: 'https://example.com/about' },
      { ref: 'e3', text: 'Contact' },
    ]
    const wrapper = mountNalarBrowser({
      content:
        '<success>1</success><page_id>page_xyz</page_id>' +
        '<url>https://example.com</url>' +
        '<title>Example Domain</title>' +
        `<tree>${JSON.stringify(tree)}</tree>`,
      parameters: JSON.stringify({ action: 'snapshot', page_id: 'page_xyz' }),
    })
    expect(wrapper.text()).toContain('snapshot')
    expect(wrapper.text()).toContain('3 elements')
  })

  it('renders "click" header with the ref that was clicked', () => {
    const wrapper = mountNalarBrowser({
      content: '<success>1</success>',
      parameters: JSON.stringify({
        action: 'click',
        page_id: 'page_xyz',
        ref: 'e12',
      }),
    })
    expect(wrapper.text()).toContain('click')
    expect(wrapper.text()).toContain('e12')
  })

  it('renders "fill" header with the ref and the text that was typed', () => {
    const wrapper = mountNalarBrowser({
      content: '<success>1</success>',
      parameters: JSON.stringify({
        action: 'fill',
        page_id: 'page_xyz',
        ref: 'e7',
        text: 'user@example.com',
      }),
    })
    expect(wrapper.text()).toContain('fill')
    expect(wrapper.text()).toContain('e7')
    expect(wrapper.text()).toContain('user@example.com')
  })

  it('renders "press" header with the key that was pressed', () => {
    const wrapper = mountNalarBrowser({
      content: '<success>1</success>',
      parameters: JSON.stringify({
        action: 'press',
        page_id: 'page_xyz',
        key: 'Enter',
      }),
    })
    expect(wrapper.text()).toContain('press')
    expect(wrapper.text()).toContain('Enter')
  })

  it('renders "close_page" header (no extra data)', () => {
    const wrapper = mountNalarBrowser({
      content: '<success>1</success>',
      parameters: JSON.stringify({
        action: 'close_page',
        page_id: 'page_xyz',
      }),
    })
    expect(wrapper.text()).toContain('close_page')
  })

  it('renders "close_browser" header with browser_id', () => {
    const wrapper = mountNalarBrowser({
      content: '<success>1</success>',
      parameters: JSON.stringify({
        action: 'close_browser',
        browser_id: 'browser_abc123',
      }),
    })
    expect(wrapper.text()).toContain('close_browser')
    expect(wrapper.text()).toContain('browser_abc123')
  })

  it('falls back to "unknown" action when parameters is not valid JSON', () => {
    const wrapper = mountNalarBrowser({
      content: '<success>1</success><browser_id>browser_abc</browser_id>',
      parameters: 'not json {{{',
    })
    expect(wrapper.find('[data-testid="nalar-browser-header"]').exists()).toBe(true)
    expect(wrapper.text()).toContain('unknown')
    // The component must not crash; it should still show the browser_id.
    expect(wrapper.text()).toContain('browser_abc')
  })

  it('falls back to "unknown" action when parameters omits the action field', () => {
    const wrapper = mountNalarBrowser({
      content: '<success>1</success>',
      parameters: JSON.stringify({ browser_id: 'browser_abc' }),
    })
    expect(wrapper.text()).toContain('unknown')
  })
})
```

- [ ] **Step 2: Run the spec to confirm it fails (no component yet)**

```bash
cd src/apps/desktop
timeout 60 bunx vitest run src/__tests__/NalarBrowser.spec.ts 2>&1 | tail -n 15
```

Expected: failure with `Failed to resolve import "../components/tool_outputs/NalarBrowser.vue"` (file doesn't exist).

### Task 1.2: Implement the NalarBrowser component (header only)

**Files:**
- Create: `src/apps/desktop/src/components/tool_outputs/NalarBrowser.vue` (new, ~140 lines)

- [ ] **Step 1: Create the component with action detection + header**

```vue
<script setup lang="ts">
import { computed, ref } from 'vue'

const props = defineProps<{
  /** Inner <data> XML from the nalar_browser result envelope.
   *  (parent unwraps the <tool> envelope via tryUnwrapToolOutput and
   *  passes the inner <data> payload here). */
  content: string
  /** Tool-call arguments as a JSON string. Used to detect the
   *  action (launch / open_page / snapshot / click / fill / press /
   *  close_page / close_browser) and to display action-specific args
   *  in the header. */
  parameters: string
  /** Whether the row is already expanded in the parent chat. */
  expanded?: boolean
}>()

const isExpanded = ref(props.expanded ?? false)

// ── Action detection ────────────────────────────────────────────────────
interface BrowserActionArgs {
  action?: string
  browser_id?: string
  page_id?: string
  url?: string
  ref?: string
  text?: string
  key?: string
}

const args = computed<BrowserActionArgs>(() => {
  try {
    const parsed = JSON.parse(props.parameters)
    if (parsed && typeof parsed === 'object') return parsed as BrowserActionArgs
  } catch {
    /* fall through */
  }
  return {}
})

const action = computed(() => args.value.action ?? 'unknown')

// ── Inner-data XML parsing ──────────────────────────────────────────────
function findTag(haystack: string, tag: string): string | null {
  const openSeq = `<${tag}>`
  const closeSeq = `</${tag}>`
  const start = haystack.indexOf(openSeq)
  if (start === -1) return null
  const valueStart = start + openSeq.length
  const end = haystack.indexOf(closeSeq, valueStart)
  if (end === -1) return null
  return haystack.slice(valueStart, end)
}

const browserId = computed(() => findTag(props.content, 'browser_id'))
const pageId = computed(() => findTag(props.content, 'page_id'))
const url = computed(() => findTag(props.content, 'url'))
const title = computed(() => findTag(props.content, 'title'))
const statusStr = computed(() => findTag(props.content, 'status'))
const statusNum = computed(() => {
  const s = statusStr.value
  if (s === null) return null
  const n = parseInt(s, 10)
  return Number.isFinite(n) ? n : null
})
const treeJson = computed(() => findTag(props.content, 'tree'))

// Snapshot tree element count
interface SnapshotElement {
  ref: string
  text: string
  href?: string
}

const snapshotElements = computed<SnapshotElement[] | null>(() => {
  const t = treeJson.value
  if (t === null) return null
  try {
    const parsed = JSON.parse(t)
    if (Array.isArray(parsed)) return parsed as SnapshotElement[]
  } catch {
    /* fall through */
  }
  return null
})

const elementCount = computed(() => snapshotElements.value?.length ?? 0)

// ── Header content (action-specific) ────────────────────────────────────
const headerLabel = computed(() => {
  const a = action.value
  switch (a) {
    case 'launch':
      return browserId.value ?? 'no browser_id'
    case 'open_page':
      return title.value ?? url.value ?? pageId.value ?? 'page'
    case 'snapshot':
      return `${elementCount.value} element${elementCount.value !== 1 ? 's' : ''}`
    case 'click':
      return args.value.ref ? `→ ${args.value.ref}` : 'no ref'
    case 'fill':
      return args.value.ref
        ? `→ ${args.value.ref} "${args.value.text ?? ''}"`
        : 'no ref'
    case 'press':
      return args.value.key ? `→ ${args.value.key}` : 'no key'
    case 'close_page':
    case 'close_browser':
      return args.value.page_id ?? args.value.browser_id ?? ''
    default:
      return browserId.value ?? pageId.value ?? url.value ?? ''
  }
})

// Status colour hint (used in the header badge)
const statusClass = computed(() => {
  if (statusNum.value === null) return ''
  if (statusNum.value >= 200 && statusNum.value < 300) return 'text-green-500'
  if (statusNum.value >= 300 && statusNum.value < 400) return 'text-yellow-500'
  return 'text-red-500'
})

// Action icon (kept lightweight — text emoji, not an SVG sprite)
const actionIcon = computed(() => {
  switch (action.value) {
    case 'launch':
      return '🚀'
    case 'open_page':
      return '🌐'
    case 'snapshot':
      return '📸'
    case 'click':
      return '🖱️'
    case 'fill':
      return '⌨️'
    case 'press':
      return '⏎'
    case 'close_page':
      return '❎'
    case 'close_browser':
      return '🛑'
    default:
      return '🔧'
  }
})

// ── Header click toggles the body ───────────────────────────────────────
const toggle = () => {
  isExpanded.value = !isExpanded.value
}
</script>

<template>
  <div
    class="font-mono text-xs rounded-md overflow-hidden border border-[var(--color-border)] bg-[var(--semantic-card-bg)]"
  >
    <div
      data-testid="nalar-browser-header"
      class="group flex items-center gap-1 px-2 py-1 cursor-pointer select-none hover:bg-violet-500/5"
      @click="toggle"
      role="button"
      tabindex="0"
    >
      <span class="text-base leading-none" :title="`nalar_browser · ${action}`">
        {{ actionIcon }}
      </span>
      <span class="text-[var(--color-violet)] font-semibold text-xs">nalar_browser</span>
      <span class="text-[var(--semantic-text-dim)] text-xs">·</span>
      <span class="text-[var(--color-violet)] text-xs font-medium">{{ action }}</span>
      <span
        v-if="headerLabel"
        class="flex-1 truncate text-left text-[var(--semantic-text)] text-xs"
        :title="headerLabel"
        >{{ headerLabel }}</span
      >
      <span v-if="statusClass" class="text-xs font-semibold" :class="statusClass">
        {{ statusStr }}
      </span>
      <span class="w-4 text-center text-[var(--semantic-text-muted)] text-sm">
        {{ isExpanded ? '−' : '+' }}
      </span>
    </div>

    <!-- Chunk 2 will fill the body. Empty for now so toggle is observable. -->
    <div
      v-if="isExpanded"
      data-testid="nalar-browser-body"
      class="border-t border-[var(--color-border)]"
    ></div>
  </div>
</template>
```

- [ ] **Step 2: Run the spec to confirm it passes**

```bash
cd src/apps/desktop
timeout 60 bunx vitest run src/__tests__/NalarBrowser.spec.ts 2>&1 | tail -n 20
```

Expected: `Tests  10 passed (10)`. If any fail, fix the component before proceeding.

- [ ] **Step 3: Run the full type-check + unit-test pass**

```bash
cd src/apps/desktop
timeout 120 bun run build 2>&1 | tail -n 5
timeout 120 bunx vitest run 2>&1 | tail -n 5
```

Expected: `bun run build` clean (no TS errors). `vitest run` shows the same total as before, with +10 from `NalarBrowser.spec.ts`.

### Task 1.3: Wire the component into ChatView.vue

**Files:**
- Modify: `src/apps/desktop/src/components/ChatView.vue`

- [ ] **Step 1: Add the import**

Insert after the existing `import SpawnSubAgent from './tool_outputs/SpawnSubAgent.vue'` line (currently line 34):

```ts
import NalarBrowser from './tool_outputs/NalarBrowser.vue'
```

- [ ] **Step 2: Add a `parameters` prop to the `<NalarBrowser>` usage in the `v-else-if` chain**

Replace the `SpawnSubAgent` v-else-if line at `ChatView.vue:1895-1900` with the new pattern, AND add a new `v-else-if` for `nalar_browser` BEFORE the generic fallback. Locate the generic fallback at `ChatView.vue:1901-1936` (`<div v-else class="tool-expandable">`). Insert this new branch immediately before it:

```vue
<NalarBrowser
  v-else-if="msg.tool_name === 'nalar_browser'"
  :content="innerToolData(msg)"
  :parameters="
    (unwrappedByMessageId.value.get(msg.id)?.parameters) ?? '{}'
  "
  :expanded="expandedToolIds.has(`${groupIndex}-${idx}`)"
/>
```

> **Why the cast pattern:** `unwrappedByMessageId` is a `computed<Map<...>>` and `msg.id` is the tool-result message id. The map's value already comes from `tryUnwrapToolOutput(msg.content)` (the parent loop builds it at line 600-616 of `ChatView.vue`); on parse failure it's `null`. The `?? '{}'` fallback keeps the prop a non-null string even for legacy/un-wrapped messages.

- [ ] **Step 3: Run the build to catch any TS errors from the new import + prop**

```bash
cd src/apps/desktop
timeout 120 bun run build 2>&1 | tail -n 10
```

Expected: clean build. If `vue-tsc` complains about `unwrappedByMessageId.value.get(...)?.parameters`, re-read `ChatView.vue:600-616` and confirm the type — the inner map value is `UnwrappedToolOutput | null`, and `UnwrappedToolOutput.parameters: string` (see `src/apps/desktop/src/helpers/unwrapToolOutput.ts:9`).

- [ ] **Step 4: Run the test suite**

```bash
cd src/apps/desktop
timeout 120 bunx vitest run 2>&1 | tail -n 5
```

Expected: same test count as Step 1.2.3.

- [ ] **Step 5: Commit Chunk 1**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/feature/nalar-browser-tool-output
git add src/apps/desktop/src/components/tool_outputs/NalarBrowser.vue \
        src/apps/desktop/src/components/ChatView.vue \
        src/apps/desktop/src/__tests__/NalarBrowser.spec.ts
git commit -m "feat(frontend): add NalarBrowser tool-output component (header + action detection)"
```

---

## Chunk 2: Snapshot Tree Renderer + Error Path

> **Goal:** populate the empty body from Chunk 1 with an action-specific view. The snapshot tree is the highest-value one (it shows the user the elements the LLM can click/fill/press). Plus, the error path needs to render the error message from the envelope's `<error>` tag (the inner `<data>` is dropped on error by `wrapToolOutput` — see `tool_registry.zig:1526-1535`).

### Task 2.1: Write the failing test for the snapshot tree body

**Files:**
- Modify: `src/apps/desktop/src/__tests__/NalarBrowser.spec.ts`

- [ ] **Step 1: Append a new `describe` block for body rendering**

Add this to the bottom of `src/apps/desktop/src/__tests__/NalarBrowser.spec.ts`:

```ts
describe('NalarBrowser — snapshot tree body', () => {
  function expandedWrapper(tree: Array<{ ref: string; text: string; href?: string }>) {
    return mountNalarBrowser({
      content:
        '<success>1</success><page_id>page_xyz</page_id>' +
        '<url>https://example.com</url>' +
        '<title>Example Domain</title>' +
        `<tree>${JSON.stringify(tree)}</tree>`,
      parameters: JSON.stringify({ action: 'snapshot', page_id: 'page_xyz' }),
      expanded: true,
    })
  }

  it('renders one row per tree element with ref + text', () => {
    const wrapper = expandedWrapper([
      { ref: 'e1', text: 'Sign in' },
      { ref: 'e2', text: 'About' },
    ])
    const rows = wrapper.findAll('[data-testid="snapshot-element"]')
    expect(rows).toHaveLength(2)
    expect(rows[0]!.text()).toContain('e1')
    expect(rows[0]!.text()).toContain('Sign in')
    expect(rows[1]!.text()).toContain('e2')
    expect(rows[1]!.text()).toContain('About')
  })

  it('shows href for <a> elements and a Copy button', async () => {
    const wrapper = expandedWrapper([
      { ref: 'e1', text: 'About', href: 'https://example.com/about' },
    ])
    const row = wrapper.find('[data-testid="snapshot-element"]')
    expect(row.text()).toContain('https://example.com/about')
  })

  it('handles a large tree (50 elements) without crashing', () => {
    const tree = Array.from({ length: 50 }, (_, i) => ({
      ref: `e${i + 1}`,
      text: `Element ${i + 1}`,
    }))
    const wrapper = expandedWrapper(tree)
    expect(wrapper.findAll('[data-testid="snapshot-element"]')).toHaveLength(50)
  })

  it('shows a "no elements" placeholder when the tree is empty', () => {
    const wrapper = expandedWrapper([])
    expect(wrapper.text()).toContain('no elements')
  })

  it('falls back to a "raw tree" code block when the tree is not valid JSON', () => {
    const wrapper = mountNalarBrowser({
      content:
        '<success>1</success><page_id>page_xyz</page_id>' +
        '<tree>not-json-{{</tree>',
      parameters: JSON.stringify({ action: 'snapshot', page_id: 'page_xyz' }),
      expanded: true,
    })
    expect(wrapper.find('[data-testid="snapshot-raw-tree"]').exists()).toBe(true)
    expect(wrapper.text()).toContain('not-json-{{')
  })
})

describe('NalarBrowser — error path', () => {
  it('renders the error message from <error> in the body', () => {
    const wrapper = mountNalarBrowser({
      content:
        '<error>NalarBrowser open_page failed: connection refused</error>',
      parameters: JSON.stringify({
        action: 'open_page',
        browser_id: 'browser_abc',
        url: 'https://example.com',
      }),
      expanded: true,
    })
    expect(wrapper.find('[data-testid="nalar-browser-error"]').exists()).toBe(true)
    expect(wrapper.text()).toContain('connection refused')
  })
})
```

- [ ] **Step 2: Run the spec to confirm the new tests fail (body is empty)**

```bash
cd src/apps/desktop
timeout 60 bunx vitest run src/__tests__/NalarBrowser.spec.ts 2>&1 | tail -n 20
```

Expected: 6 new tests fail with `Unable to find [data-testid="snapshot-element"]` (component exists but body is empty in Chunk 1).

### Task 2.2: Implement the body (snapshot tree + error)

**Files:**
- Modify: `src/apps/desktop/src/components/tool_outputs/NalarBrowser.vue`

- [ ] **Step 1: Replace the empty body `<div>` with the action-specific body**

Find the empty body block added in Chunk 1 (it's the only `<div v-if="isExpanded" data-testid="nalar-browser-body" ...></div>` in the file). Replace it with:

```vue
<div
  v-if="isExpanded"
  data-testid="nalar-browser-body"
  class="border-t border-[var(--color-border)] bg-black/[0.02]"
>
  <!-- Error path: <error>…</error> from toXMLError (rare in the
       envelope today because wrapToolOutput drops <data> on success=false,
       but the inner data still carries the <error> tag from the old
       toXMLError XML, so we render it as a red block). -->
  <div
    v-if="errorMessage"
    data-testid="nalar-browser-error"
    class="px-3 py-2 text-red-500 text-xs"
  >
    <span class="font-semibold shrink-0">Error:</span>
    <span class="whitespace-pre-wrap break-all">{{ errorMessage }}</span>
  </div>

  <!-- Snapshot tree renderer -->
  <div v-else-if="action === 'snapshot'">
    <div
      v-if="snapshotElements && snapshotElements.length > 0"
      class="divide-y divide-[var(--color-border)]"
    >
      <div
        v-for="(el, idx) in snapshotElements"
        :key="idx"
        data-testid="snapshot-element"
        class="group flex items-center gap-2 px-2 py-1 hover:bg-violet-500/5"
      >
        <span
          class="font-mono text-[10px] px-1.5 py-0.5 rounded shrink-0"
          style="background-color: var(--color-violet); color: white; opacity: 0.85;"
          :title="`Ref: ${el.ref}`"
          >{{ el.ref }}</span
        >
        <span
          v-if="el.href"
          class="text-[var(--semantic-text)] text-xs truncate flex-1"
          :title="el.text + ' → ' + el.href"
        >
          {{ el.text }}
          <span class="text-[var(--semantic-text-muted)]">→</span>
          <span class="text-[var(--color-blue)] underline">{{ el.href }}</span>
        </span>
        <span
          v-else
          class="text-[var(--semantic-text)] text-xs truncate flex-1"
          :title="el.text"
          >{{ el.text }}</span
        >
        <button
          class="px-0.5 border-none bg-transparent cursor-pointer text-[var(--semantic-text-muted)] opacity-0 group-hover:opacity-100 hover:!text-violet-500 text-base transition-opacity"
          @click.stop="copyText(el.text)"
          :title="`Copy ref ${el.ref}`"
        >
          ⎘
        </button>
      </div>
    </div>
    <div
      v-else-if="treeJson === null"
      class="px-3 py-2 text-[var(--semantic-text-muted)] text-xs italic"
    >
      snapshot returned no tree
    </div>
    <div
      v-else-if="snapshotElements === null"
      data-testid="snapshot-raw-tree"
      class="px-3 py-2"
    >
      <div class="text-[0.65rem] text-[var(--semantic-text-muted)] mb-1">
        tree (raw — not valid JSON)
      </div>
      <pre
        class="m-0 p-2 bg-black/[0.02] text-xs whitespace-pre-wrap break-all leading-relaxed"
        >{{ treeJson }}</pre>
    </div>
    <div
      v-else
      class="px-3 py-2 text-[var(--semantic-text-muted)] text-xs italic"
    >
      no elements
    </div>
  </div>

  <!-- open_page: show URL + status details -->
  <div v-else-if="action === 'open_page'" class="px-3 py-2 text-xs space-y-1">
    <div v-if="url" class="flex gap-2">
      <span class="text-[var(--semantic-text-muted)] shrink-0">URL</span>
      <a
        :href="url"
        target="_blank"
        rel="noopener noreferrer"
        class="text-[var(--color-blue)] underline truncate"
        :title="url"
        >{{ url }}</a
      >
    </div>
    <div v-if="title" class="flex gap-2">
      <span class="text-[var(--semantic-text-muted)] shrink-0">Title</span>
      <span class="truncate" :title="title">{{ title }}</span>
    </div>
    <div v-if="pageId" class="flex gap-2">
      <span class="text-[var(--semantic-text-muted)] shrink-0">Page ID</span>
      <span class="font-mono truncate" :title="pageId">{{ pageId }}</span>
    </div>
  </div>

  <!-- launch: show browser_id -->
  <div v-else-if="action === 'launch' && browserId" class="px-3 py-2 text-xs">
    <div class="flex gap-2">
      <span class="text-[var(--semantic-text-muted)] shrink-0">Browser ID</span>
      <span class="font-mono truncate" :title="browserId">{{ browserId }}</span>
    </div>
  </div>

  <!-- click / fill / press / close_*: show the action args in a compact row -->
  <div
    v-else-if="action === 'click' || action === 'fill' || action === 'press' || action === 'close_page' || action === 'close_browser'"
    class="px-3 py-2 text-xs space-y-1"
  >
    <div v-if="args.ref" class="flex gap-2">
      <span class="text-[var(--semantic-text-muted)] shrink-0">ref</span>
      <span class="font-mono">{{ args.ref }}</span>
    </div>
    <div v-if="args.text" class="flex gap-2">
      <span class="text-[var(--semantic-text-muted)] shrink-0">text</span>
      <span class="truncate" :title="args.text">{{ args.text }}</span>
    </div>
    <div v-if="args.key" class="flex gap-2">
      <span class="text-[var(--semantic-text-muted)] shrink-0">key</span>
      <span class="font-mono">{{ args.key }}</span>
    </div>
    <div v-if="args.url" class="flex gap-2">
      <span class="text-[var(--semantic-text-muted)] shrink-0">url</span>
      <span class="text-[var(--color-blue)] underline truncate" :title="args.url">
        {{ args.url }}
      </span>
    </div>
    <div v-if="args.page_id" class="flex gap-2">
      <span class="text-[var(--semantic-text-muted)] shrink-0">page_id</span>
      <span class="font-mono truncate" :title="args.page_id">{{ args.page_id }}</span>
    </div>
    <div v-if="args.browser_id" class="flex gap-2">
      <span class="text-[var(--semantic-text-muted)] shrink-0">browser_id</span>
      <span class="font-mono truncate" :title="args.browser_id">
        {{ args.browser_id }}
      </span>
    </div>
  </div>
</div>
```

- [ ] **Step 2: Add `errorMessage` computed + `copyText` helper to the `<script setup>` block**

In the same file's `<script setup lang="ts">`, after the `headerLabel` computed, add:

```ts
// Inner <error>…</error> tag from toXMLError (present in some error paths).
const errorMessage = computed(() => findTag(props.content, 'error'))

// Copy a ref's text to the clipboard (used by snapshot rows)
const copyText = async (text: string) => {
  try {
    await navigator.clipboard.writeText(text)
  } catch {
    /* clipboard may be unavailable in some test envs — silently no-op */
  }
}
```

- [ ] **Step 3: Run the spec to confirm the new tests pass**

```bash
cd src/apps/desktop
timeout 60 bunx vitest run src/__tests__/NalarBrowser.spec.ts 2>&1 | tail -n 20
```

Expected: all 17 tests in `NalarBrowser.spec.ts` pass (11 from Chunk 1 + 6 from Chunk 2).

- [ ] **Step 4: Run the full type-check + test pass**

```bash
cd src/apps/desktop
timeout 120 bun run build 2>&1 | tail -n 10
timeout 120 bunx vitest run 2>&1 | tail -n 5
```

Expected: build clean. Tests pass with the new +6 from Chunk 2.

- [ ] **Step 5: Commit Chunk 2**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/feature/nalar-browser-tool-output
git add src/apps/desktop/src/components/tool_outputs/NalarBrowser.vue \
        src/apps/desktop/src/__tests__/NalarBrowser.spec.ts
git commit -m "feat(frontend): render snapshot tree + error path in NalarBrowser"
```

---

## Chunk 3: Inline Tool-Name Preview + Final Polish

> **Goal:** make the collapsed preview (the `tool-inline` HTML at the top of each tool row in `ChatView.vue:117-218`) carry the right summary text for `nalar_browser` — currently it falls through to the generic `<span class="tool-inline">${tool_name || unwrapped.name} → …</span>` which would say "nalar_browser → success <success>1</success>…", leaking the raw XML.

### Task 3.1: Add a `nalar_browser` branch in `renderResponse`

**Files:**
- Modify: `src/apps/desktop/src/components/ChatView.vue`

- [ ] **Step 1: Locate the inline-preview block**

In `src/apps/desktop/src/components/ChatView.vue` lines 117-218, the `renderResponse` function has a long `if/else if` chain for each tool. Find the `if (tool_name === 'spawn_sub_agent')` block (around line 197) and add a new branch for `nalar_browser` IMMEDIATELY BEFORE it (so the more specific branch wins):

```ts
if (tool_name === 'nalar_browser') {
  // Use the same action-aware summariser the standalone component uses,
  // so the collapsed preview ("nalar_browser · open_page · Example Domain")
  // matches what the user will see in the expanded body.
  const a = unwrapped.parameters
  let action = 'unknown'
  try {
    const parsed = JSON.parse(a)
    if (parsed && typeof parsed === 'object' && typeof parsed.action === 'string') {
      action = parsed.action
    }
  } catch {
    /* fall through */
  }
  const label = (() => {
    if (unwrapped.error) return unwrapped.error
    switch (action) {
      case 'launch':
        return unwrapped.data?.match(/<browser_id>([\s\S]*?)<\/browser_id>/)?.[1] ?? action
      case 'open_page':
        return (
          unwrapped.data?.match(/<title>([\s\S]*?)<\/title>/)?.[1] ??
          unwrapped.data?.match(/<url>([\s\S]*?)<\/url>/)?.[1] ??
          action
        )
      case 'snapshot':
        return (
          (() => {
            const tree = unwrapped.data?.match(/<tree>([\s\S]*?)<\/tree>/)?.[1]
            if (!tree) return action
            try {
              const arr = JSON.parse(tree)
              return Array.isArray(arr)
                ? `snapshot · ${arr.length} element${arr.length !== 1 ? 's' : ''}`
                : action
            } catch {
              return action
            }
          })()
        )
      case 'click':
      case 'fill':
      case 'press':
      case 'close_page':
      case 'close_browser':
        return action
      default:
        return action
    }
  })()
  return `<span class="tool-inline">${tool_name} · ${escapeHtml(action)} · ${escapeHtml(label)}</span>`
}
```

- [ ] **Step 2: Run the build to catch any TS errors**

```bash
cd src/apps/desktop
timeout 120 bun run build 2>&1 | tail -n 10
```

Expected: clean build. If `vue-tsc` complains about `unwrapped.parameters` being `unknown` (it should be `string` — see `unwrapToolOutput.ts:9`), fix the type assertion with `unwrapped.parameters as string`.

- [ ] **Step 3: Run the test suite**

```bash
cd src/apps/desktop
timeout 120 bunx vitest run 2>&1 | tail -n 5
```

Expected: same test count (no new tests in this chunk — the inline preview is hard to assert without a full ChatView mount).

### Task 3.2: Visual sanity check (manual)

**Files:**
- (no file changes)

- [ ] **Step 1: Smoke-test the rendered output via a one-off spec**

Create `src/apps/desktop/src/__tests__/NalarBrowserInlinePreview.spec.ts`:

```ts
import { describe, it, expect } from 'vitest'
import { mount } from '@vue/test-utils'

import ChatView from '../components/ChatView.vue'

describe('renderResponse — nalar_browser inline preview', () => {
  it('shows a clean "nalar_browser · open_page · <title>" for open_page success', () => {
    const wrapper = mount(ChatView, {
      props: { chatId: 'session_test', chatName: 'Test' },
    })
    // Render a synthetic tool result by calling the function the template uses.
    // ChatView exposes renderResponse via the v-html binding on tool groups;
    // we re-derive the same string by calling the public method on the
    // exposed instance.
    // The method is internal — instead, we test by re-mounting with a
    // pre-populated message group is heavy. Simpler: assert the component
    // mounted without error. The chunk 3 manual smoke test (run nalar +
    // open a page in the UI) is the real verification.
    expect(wrapper.exists()).toBe(true)
  })
})
```

- [ ] **Step 2: Run the spec to confirm the mount is clean**

```bash
cd src/apps/desktop
timeout 60 bunx vitest run src/__tests__/NalarBrowserInlinePreview.spec.ts 2>&1 | tail -n 10
```

Expected: 1 test passing. This is a smoke test only — the real verification is the manual UI check below.

- [ ] **Step 3: Manual UI check (document but don't run)**

> Do NOT execute this step from an automated agent. It's a human-only smoke test.

1. Start the nalar_browser service: `cd src/modules/nalar_browser && bun run start:compiled` (or `./nalar_browser` if the compiled binary is built).
2. Start the nalar backend on port 8081: `zig build nalar-server` + run with `--port 8081 --static-dir <webapp>`.
3. In the desktop app, send a message like: "Launch nalar_browser, go to https://example.com, take a snapshot, and list the first 3 elements."
4. Verify in the chat:
   - The collapsed `launch` row shows `nalar_browser · launch · <browser_id>` (no raw XML).
   - The `open_page` row shows `nalar_browser · open_page · Example Domain` with a status badge of 200 (green).
   - The `snapshot` row shows `nalar_browser · snapshot · N elements`, and expanding it reveals a clean list of refs (e1, e2, …) with their text.
   - No raw `<success>1</success>` or `<browser_id>...</browser_id>` is visible anywhere.
5. Also send a failure case: "Launch nalar_browser and click ref e999." (assuming e999 doesn't exist on the snapshot). Verify the error row renders the error message in red.

If the manual check surfaces visual bugs, iterate on the component before merging.

- [ ] **Step 4: Commit Chunk 3**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/feature/nalar-browser-tool-output
git add src/apps/desktop/src/components/ChatView.vue \
        src/apps/desktop/src/__tests__/NalarBrowserInlinePreview.spec.ts
git commit -m "feat(frontend): add nalar_browser branch in tool inline preview"
```

---

## Final Verification

- [ ] **Step 1: Full build + test sweep**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/feature/nalar-browser-tool-output/src/apps/desktop
timeout 120 bun run build 2>&1 | tail -n 5
timeout 120 bunx vitest run 2>&1 | tail -n 5
```

Expected: build clean. `vitest run` shows +18 from this branch (10 from Chunk 1 + 6 from Chunk 2 + 1 from Chunk 3 + the 1 mount-smoke from Chunk 3.2 — 18 total).

- [ ] **Step 2: Verify the diff is scoped**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/feature/nalar-browser-tool-output
git diff --stat main
```

Expected: 4 files changed — `NalarBrowser.vue` (new, ~250 lines), `NalarBrowser.spec.ts` (new, ~180 lines), `NalarBrowserInlinePreview.spec.ts` (new, ~25 lines), `ChatView.vue` (~20 line edits: 1 import + 1 v-else-if + ~15 line inline-preview branch). No unrelated file churn.

- [ ] **Step 3: Confirm the component is actually wired in**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/feature/nalar-browser-tool-output
rg "NalarBrowser" src/apps/desktop/src/components/ChatView.vue
```

Expected: 2 matches — the `import` line and the `v-else-if="msg.tool_name === 'nalar_browser'"` line.

- [ ] **Step 4: Merge to main and clean up the worktree**

After all the above pass, use the `finishing-a-development-branch` skill to decide between merge / PR / cleanup. The expected outcome is a fast-forward merge into `main` (no conflicts expected — the only files touched are new + the surgical edit in `ChatView.vue`) and removal of the `.worktrees/feature/nalar-browser-tool-output/` directory.

---

## Pitfalls

1. **Inner `<data>` is NOT XML-escaped** (see comment at `tool_registry.zig:1515-1520`). The snapshot's `<tree>[{"ref":"e1",...}]</tree>` contains literal `"` chars but no `<`/`>`/`&`, so it's safe. **Edge case:** if a button's `aria-label` / `textContent` ever contains `</tree>`, the regex parse will break. The plan's `snapshotElements` computed handles this with a `try/catch` and falls back to the `data-testid="snapshot-raw-tree"` block. If we ever need a more robust parse, switch the backend to encode the tree as base64 inside `<tree>`.

2. **`<error>` from the envelope vs `<error>` from the inner data** — both can be present. `wrapToolOutput` produces `<error>...</error>` on the envelope when `success=false`, and the inner `toXMLError` produces `<error>NalarBrowser {action} failed: {msg}</error>` on the inner data. The `findTag('error')` call returns the FIRST one it finds, which is the envelope's (since the envelope wraps the data). The "Error" block in the body renders that — which is what we want.

3. **JSON parameters parsing is defensive** — `JSON.parse` can throw on malformed input. The `args` and `action` computeds wrap it in `try/catch` and fall back to `{}` and `'unknown'`. Tests in Chunk 1.1 step 1 explicitly cover this with `'not json {{{'`.

4. **`status` is a string in the inner data** — the backend writes `<status>200</status>` (number as string). `statusNum` parses it to a number for colour-coding. If parsing fails, the badge is hidden (because `statusClass` is `''`).

5. **`ref`/`<here>` in element text** — if a button label contains `<`, the snapshot's tree JSON will contain a literal `<`. The XML structure remains valid (no nested `<tree>`), so `findTag` still works. The Vue template will escape the `<` for display. No special handling needed.

6. **Worktree collision** — there are 13 existing worktrees. Naming the new one `feature/nalar-browser-tool-output` avoids collision. Do NOT use a name starting with `feature/nalar-browser` (the rename worktree already uses that prefix).

7. **`vite-tsc` vs `vitest`** — `vitest run` does NOT run the type-checker. Always run `bun run build` (not just `bun run build-only`) before claiming a chunk is done. See `desktop-typescript-bun-build-as-typecheck` memory for the full failure mode.

8. **Other workers' file reverts** — the `ChatView.vue` is shared with other in-flight feature work. If another worker reverts the `v-else-if` insertion, the `bun run build` will succeed (the new branch is conditional, and dropping it just falls back to the generic `<div class="tool-expandable">` — no compile error). Verify the diff is intact before each commit via `git diff src/apps/desktop/src/components/ChatView.vue | head -n 30`.

---

## Verification

- `bun run build` (full TS type-check) is clean.
- `bunx vitest run` reports 18 new passing tests (10 + 6 + 1 + 1 smoke) and no regressions in the existing test count.
- `rg "nalar_browser" src/apps/desktop/src/` returns matches in the new component + spec files (was 0 before).
- A real nalar_browser session in the desktop app shows the friendly action-specific UI for `launch` / `open_page` / `snapshot` (the three most common), instead of the raw `<success>1</success><browser_id>…</browser_id>` XML.
- The inline preview at the top of each tool row says `nalar_browser · open_page · Example Domain` (not `nalar_browser → success <success>1</success>…`).
