<script setup lang="ts">
import { computed, defineComponent, h, ref, type PropType } from 'vue'
import {
  computeSplitView,
  computeUnifiedView,
  splitLines,
  type SplitRow,
  type UnifiedRow,
} from './myersDiff'

/**
 * Renders a side-by-side or unified diff for two strings.
 *
 * Split-view is the default (matches GitHub). Unified-view uses git-style
 * `@@ -start,count +start,count @@` hunk headers.
 *
 * Horizontal scroll behaviour: long lines scroll horizontally; the line-number
 * gutter stays sticky on the LEFT so the user always sees which line they're
 * looking at. Row backgrounds (red for delete, green for insert) extend across
 * the full row width via the row's `min-w-max` flex container; the gutter
 * cells use `position: sticky; background: var(--semantic-card-bg)` to keep
 * the line number visible against the row's red/green overlay.
 *
 * The component is purely presentational — input is two strings. The user's
 * mode preference is persisted to `localStorage` under `diffview.mode`.
 */
interface Props {
  /** "Before" content (string; will be split into lines). */
  before: string
  /** "After" content (string; will be split into lines). */
  after: string
  /** Optional path — used as a title on the diff header for context. */
  filePath?: string
  /** Initial mode. Default 'split'. */
  initialMode?: 'split' | 'unified'
}

const props = withDefaults(defineProps<Props>(), {
  filePath: undefined,
  initialMode: 'split',
})

/**
 * Emitted when the user clicks a line-number cell in the diff.
 * Payload is the 1-based line number in the file (the `after`-side line
 * for split view, the actual row's new-line number for unified view).
 * Parents should wire this to the code-editor open handler so the user
 * can land on the exact line they were inspecting.
 */
const emit = defineEmits<{
  'jump-to-line': [line: number]
}>()

const STORAGE_KEY = 'diffview.mode'

const readStoredMode = (): 'split' | 'unified' => {
  try {
    if (typeof localStorage === 'undefined') return props.initialMode
    const v = localStorage.getItem(STORAGE_KEY)
    if (v === 'split' || v === 'unified') return v
  } catch {
    // localStorage may throw (private mode)
  }
  return props.initialMode
}

const mode = ref<'split' | 'unified'>(readStoredMode())

const setMode = (next: 'split' | 'unified') => {
  mode.value = next
  try {
    localStorage.setItem(STORAGE_KEY, next)
  } catch {
    // ignore
  }
}

const beforeLines = computed(() => splitLines(props.before))
const afterLines = computed(() => splitLines(props.after))

const splitRows = computed(() => computeSplitView(beforeLines.value, afterLines.value))
const unifiedRows = computed(() => computeUnifiedView(beforeLines.value, afterLines.value))

const changeCount = computed(() => {
  if (mode.value === 'split') {
    return splitRows.value.filter((r) => r.isChanged).length
  }
  return unifiedRows.value.filter(
    (r) => r.kind === 'delete' || r.kind === 'insert',
  ).length
})

const hasChanges = computed(() => changeCount.value > 0)

const readMode = readStoredMode // suppress unused warning if some bundler tree-shakes

// ────────────────────────────────────────────────────────────────────────────
// Sub-components — inline to avoid 3 separate files for tiny helpers.
// ────────────────────────────────────────────────────────────────────────────

/**
 * Renders one side (before/after) of the split-view.
 * Each row is a flex container with a sticky gutter (line number + diff
 * marker) and a horizontally-scrolling content cell.
 */
const DiffSplitSide = defineComponent({
  name: 'DiffSplitSide',
  props: {
    rows: { type: Array as PropType<SplitRow[]>, required: true },
    side: { type: String as PropType<'before' | 'after'>, required: true },
  },
  setup(props) {
    return () => {
      if (props.rows.length === 0) {
        return h(
          'div',
          {
            class:
              'overflow-x-auto text-xs leading-relaxed font-mono bg-[var(--semantic-card-bg)]',
          },
          [
            h(
              'div',
              {
                class:
                  'px-2 py-1 text-[var(--semantic-text-muted)] italic text-center',
              },
              '(no content)',
            ),
          ],
        )
      }
      return h(
        'div',
        {
          class:
            'overflow-x-hidden text-xs leading-relaxed font-mono bg-[var(--semantic-card-bg)]',
        },
        props.rows.map((row, idx) => renderSplitRow(row, idx, props.side)),
      )
    }
  },
})

function renderSplitRow(row: SplitRow, idx: number, side: 'before' | 'after') {
  const isBefore = side === 'before'
  const text = isBefore ? row.beforeText : row.afterText
  const lineNum = isBefore ? row.beforeLine : row.afterLine

  // GitHub-style split-view row: full-row tinted bg that ALWAYS covers
  // the full pane width regardless of content length.
  //
  // Strategy:
  //   - The row is `display: block; width: 100%` — fills the pane width.
  //   - The row has `overflow: hidden` — clips content that extends past
  //     the pane (no horizontal scroll on the pane; long lines are
  //     clipped, matching GitHub's diff behavior).
  //   - The line content uses `white-space: pre` to preserve spaces and
  //     allow long lines to render at their natural width.
  let bgColor = ''
  if (row.isChanged) {
    if (isBefore) {
      bgColor = 'rgba(248, 81, 73, 0.15)'
    } else if (row.afterText !== null) {
      bgColor = 'rgba(46, 160, 67, 0.15)'
    }
  }

  // Text color: red for deleted (before) lines, green for inserted
  // (after) lines. Context (unchanged) lines keep the default text color.
  let textColorClass = ''
  if (row.isChanged) {
    if (isBefore) {
      textColorClass = '!text-[rgb(248,81,73)]'
    } else if (row.afterText !== null) {
      textColorClass = '!text-[rgb(63,185,80)]'
    }
  }

  // Clickable gutter: clicking the line number emits jump-to-line so the
  // parent can open the code editor at that exact line.
  const isClickable = lineNum !== null
  const gutterClickHandler = isClickable
    ? {
        onClick: (e: MouseEvent) => {
          e.stopPropagation()
          emit('jump-to-line', lineNum!)
        },
        onMouseover: (e: MouseEvent) => {
          ;(e.currentTarget as HTMLElement).style.cursor = 'pointer'
          ;(e.currentTarget as HTMLElement).style.color =
            'var(--color-violet)'
        },
        onMouseout: (e: MouseEvent) => {
          ;(e.currentTarget as HTMLElement).style.color = ''
        },
      }
    : {}

  // The row is `display: block` (default for div). We use `overflow:hidden`
  // to clip long content past the pane edge — matches GitHub's diff
  // (long lines are clipped, not scrolled). The bg is on the row itself,
  // so it always fills the pane width.
  return h(
    'div',
    {
      class: [
        'block w-full whitespace-pre overflow-hidden',
        bgColor ? '' : 'hover:bg-white/[0.03]',
      ],
      style: bgColor ? { backgroundColor: bgColor } : undefined,
      'data-row': idx,
      'data-side': side,
      'data-changed': row.isChanged ? 'true' : 'false',
      'data-line': lineNum !== null ? String(lineNum) : undefined,
    },
    [
      // Gutter: line number cell. Card-bg colored so the number stays
      // readable against the row's red/green bg. Inline-block so it
      // sits next to the content on the same line.
      h(
        'span',
        {
          class:
            'inline-block px-2 py-0.5 select-none text-[var(--semantic-text-muted)] font-mono align-top',
          style: { background: 'var(--semantic-card-bg)' },
          ...gutterClickHandler,
        },
        lineNum !== null ? String(lineNum) : '\u00a0',
      ),
      // Line content. Plain text — no inline highlights. Inline-block
      // + white-space:pre keeps each line as one logical line.
      h(
        'span',
        {
          class: ['inline-block py-0.5 pr-2 whitespace-pre align-top', textColorClass],
        },
        text ?? '\u00a0',
      ),
    ],
  )
}

// renderInlineChanges was removed in the chunks 5+6 redesign — users
// found the combination of row bg + strikethrough + per-word highlight
// on the same line impossible to parse. See renderSplitRow and
// renderUnifiedRow for the new plain-text rendering.

/**
 * Renders the unified-view rows: line numbers, diff prefix, and content,
 * all in a single column. The before/after line numbers and the diff prefix
 * are sticky on horizontal scroll.
 */
const DiffUnifiedSide = defineComponent({
  name: 'DiffUnifiedSide',
  props: {
    rows: { type: Array as PropType<UnifiedRow[]>, required: true },
  },
  setup(props) {
    return () => {
      if (props.rows.length === 0) {
        return h(
          'div',
          {
            class:
              'overflow-x-auto text-xs leading-relaxed font-mono bg-[var(--semantic-card-bg)]',
          },
          [
            h(
              'div',
              {
                class:
                  'px-2 py-1 text-[var(--semantic-text-muted)] italic text-center',
              },
              '(no content)',
            ),
          ],
        )
      }
      return h(
        'div',
        {
          class:
            'overflow-x-auto text-xs leading-relaxed font-mono bg-[var(--semantic-card-bg)]',
        },
        props.rows.map((row, idx) => renderUnifiedRow(row, idx)),
      )
    }
  },
})

function renderUnifiedRow(row: UnifiedRow, idx: number) {
  if (row.kind === 'hunk') {
    return h(
      'div',
      {
        class:
          'px-2 py-0.5 text-[var(--semantic-text-muted)] italic bg-black/[0.02] border-y border-[var(--color-border)]',
        'data-hunk': idx,
      },
      row.text,
    )
  }
  let rowBgClass = ''
  if (row.kind === 'delete') rowBgClass = '!bg-red-400/15 !text-red-500'
  else if (row.kind === 'insert') rowBgClass = '!bg-green-400/15 !text-green-500'

  // Unified view: prefer the after-line for click (that's the file's new
  // state). For delete-only rows there is no after-line; fall back to the
  // before-line so the user can still jump to that line in the original
  // (pre-edit) snapshot — for an inserted row that line no longer exists,
  // but the editor's revealLine clamps gracefully.
  const jumpLine = row.afterLine ?? row.beforeLine
  const gutterClickHandler =
    jumpLine !== undefined && jumpLine !== null
      ? {
          onClick: (e: MouseEvent) => {
            e.stopPropagation()
            emit('jump-to-line', jumpLine as number)
          },
          onMouseover: (e: MouseEvent) => {
            ;(e.currentTarget as HTMLElement).style.cursor = 'pointer'
            ;(e.currentTarget as HTMLElement).style.color =
              'var(--color-violet)'
          },
          onMouseout: (e: MouseEvent) => {
            ;(e.currentTarget as HTMLElement).style.color = ''
          },
        }
      : {}

  return h(
    'div',
    {
      class: ['flex min-w-max hover:bg-violet-500/5', rowBgClass],
      'data-row': idx,
      'data-kind': row.kind,
      'data-after-line': row.afterLine ?? undefined,
      'data-before-line': row.beforeLine ?? undefined,
    },
    [
      h(
        'span',
        {
          class:
            'shrink-0 sticky left-0 z-10 w-10 px-2 py-0.5 text-right text-[var(--semantic-text-muted)] font-mono select-none border-r border-[var(--color-border)]',
          style: { background: 'var(--semantic-card-bg)' },
          ...(row.beforeLine !== null && row.beforeLine !== undefined
            ? gutterClickHandler
            : {}),
        },
        row.beforeLine ?? '',
      ),
      h(
        'span',
        {
          class:
            'shrink-0 sticky left-10 z-10 w-10 px-2 py-0.5 text-right text-[var(--semantic-text-muted)] font-mono select-none border-r border-[var(--color-border)]',
          style: { background: 'var(--semantic-card-bg)' },
          ...(row.afterLine !== null && row.afterLine !== undefined
            ? gutterClickHandler
            : {}),
        },
        row.afterLine ?? '',
      ),
      h(
        'span',
        {
          class:
            'shrink-0 sticky left-20 z-10 w-4 mr-3 font-semibold text-center',
          style: { background: 'var(--semantic-card-bg)' },
        },
        row.text.charAt(0),
      ),
      h('span', { class: 'shrink-0 px-2 py-0.5 whitespace-pre' }, row.text.slice(1)),
    ],
  )
}

// Quiet the lint when readStoredMode is unused
void readMode
</script>

<template>
  <div
    class="rounded-md border border-[var(--color-border)] bg-[var(--semantic-card-bg)] overflow-hidden"
  >
    <!-- Header: file-path title, change count, mode toggle -->
    <div
      class="flex items-center justify-between gap-2 px-2 py-1 border-b border-[var(--color-border)] bg-black/[0.02] text-xs"
    >
      <div class="flex items-center gap-2 truncate">
        <span class="text-[var(--color-violet)] font-semibold">diff</span>
        <span
          v-if="filePath"
          class="text-[var(--semantic-text-muted)] truncate"
          :title="filePath"
        >{{ filePath }}</span>
      </div>
      <div class="flex items-center gap-2 shrink-0">
        <span v-if="hasChanges" class="text-[var(--semantic-text-muted)]">
          {{ changeCount }} {{ changeCount === 1 ? 'change' : 'changes' }}
        </span>
        <div
          class="inline-flex rounded border border-[var(--color-border)] overflow-hidden"
        >
          <button
            type="button"
            class="px-2 py-0.5 text-xs border-none cursor-pointer"
            :class="
              mode === 'split'
                ? 'bg-[var(--color-violet)] text-white'
                : 'bg-transparent text-[var(--semantic-text-muted)] hover:bg-violet-500/10'
            "
            @click="setMode('split')"
          >Split</button>
          <button
            type="button"
            class="px-2 py-0.5 text-xs border-none cursor-pointer"
            :class="
              mode === 'unified'
                ? 'bg-[var(--color-violet)] text-white'
                : 'bg-transparent text-[var(--semantic-text-muted)] hover:bg-violet-500/10'
            "
            @click="setMode('unified')"
          >Unified</button>
        </div>
      </div>
    </div>

    <!-- Split view -->
    <div v-if="mode === 'split'" class="flex divide-x divide-[var(--color-border)]">
      <div class="flex-1 min-w-0">
        <div
          class="px-2 py-0.5 text-xs font-semibold uppercase bg-black/[0.02] border-b border-[var(--color-border)] text-red-500"
        >Before</div>
        <DiffSplitSide :rows="splitRows" side="before" />
      </div>
      <div class="flex-1 min-w-0">
        <div
          class="px-2 py-0.5 text-xs font-semibold uppercase bg-black/[0.02] border-b border-[var(--color-border)] text-green-500"
        >After</div>
        <DiffSplitSide :rows="splitRows" side="after" />
      </div>
    </div>

    <!-- Unified view -->
    <DiffUnifiedSide v-else :rows="unifiedRows" />
  </div>
</template>