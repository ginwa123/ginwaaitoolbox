<!--
  MarkdownDescription — display-only renderer for a Markdown string.

  Used to show a kanban task description in two places:
    1. The Task details dialog (when not in edit mode).
    2. The KanbanCard preview on the column (with `maxHeight` to clip).

  What it does:
    - Calls `marked.parse(source, { async: false })` to get HTML.
    - Post-processes the HTML to wrap `@/path/to/file` tokens in a
      clickable `.md-file-chip` span. The user types these tokens
      directly into the description via the `KanbanDescriptionEditor`
      `@`-trigger file picker; this is how we surface them visually.
    - Renders the HTML via `v-html` inside `<div class="markdown-content">`.

  Trust model (XSS):
    The `source` is user-authored task data. `marked.parse` is the same
    library ChatView uses (line 183) — and the same self-XSS trust model
    applies: a user can only inject markup into their own task. No CSP
    change is required. Image data URLs are passed through verbatim by
    marked, which is exactly what we want for the inline-image case.

  @path chip detection:
    - Regex: `/@(\/[^\s)\]}>,"'`]+)/g` — leading `@`, then `/`, then any
      chars except whitespace, closing brackets, quotes, backticks.
    - Two non-matches: `@username` (no leading slash) and `/path/with/no/at`.
    - The path is escaped via a small replace; the surrounding markdown
      continues to be rendered normally (the chip is a `<span>` that sits
      inside whatever block the markdown produced).
-->
<script setup lang="ts">
import { computed } from 'vue'
import { marked } from 'marked'

const props = withDefaults(
  defineProps<{
    source: string | null | undefined
    cwd?: string
    maxHeight?: string
    testId?: string
  }>(),
  {
    cwd: '',
    maxHeight: '',
    testId: 'markdown-description',
  },
)

// Matches `@/path/to/file` where path is the sequence of non-whitespace
// and non-markdown-delimiter characters. Captures the path (group 1).
// Does NOT match `@username` (no leading slash after `@`).
const AT_PATH_REGEX = /@(\/[^\s)\]}>,"'<`]+)/g

// Private-use Unicode char used as a sentinel in the source before it
// is fed to marked. Marked treats unknown chars as plain text and
// passes them through verbatim, so the placeholder survives the
// round-trip and we can substitute the chip span in afterwards. Using
// `\uE000` (private use area) means there's essentially zero chance a
// user types this exact sequence naturally.
const PLACEHOLDER_PREFIX = '\uE000_FILECHIP_'
const PLACEHOLDER_SUFFIX = '_\uE000'

// Render the source through marked, then splice `@/path` tokens into
// clickable chip spans.
//
// Two-phase approach (placeholder substitution):
//   1. Pre-process: replace each `@/path` with `\uE000_FILECHIP_<i>_\uE000`
//      and stash the path in an array. Marked never sees the `@`, so it
//      can't try to autolink the path or wrap it in `<a>` / `<code>`.
//   2. Run marked.parse() on the placeholder-bearing source.
//   3. Post-process: substitute each placeholder with a chip span.
//
// Why not just regex on the rendered HTML?
//   Fragile — the regex character class must perfectly exclude every
//   char marked might emit adjacent to the path. Earlier revision let
//   `<` through, which caused `/lib/util/d.ts</p>` to be captured as
//   the "path" when the third token in a sentence sat just before
//   marked's closing `</p>`. The placeholder approach is immune to
//   marked's wrapping behavior — it operates on a string we control.
const renderedHtml = computed<string>(() => {
  if (!props.source) return ''

  // Phase 1 — collect chips and substitute placeholders.
  const chips: string[] = []
  const preProcessed = props.source.replace(AT_PATH_REGEX, (_match, path: string) => {
    const idx = chips.length
    chips.push(path)
    return `${PLACEHOLDER_PREFIX}${idx}${PLACEHOLDER_SUFFIX}`
  })

  // Phase 2 — marked.parse on the safe input.
  let html: string
  try {
    html = marked.parse(preProcessed, { async: false }) as string
  } catch {
    // Fallback to escaped pre block on parse error — same convention as
    // PreviewSidePanel.vue:203.
    const escaped = props.source
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
    return `<pre>${escaped}</pre>`
  }

  // Phase 3 — substitute placeholders with chip spans.
  for (let i = 0; i < chips.length; i++) {
    const placeholder = `${PLACEHOLDER_PREFIX}${i}${PLACEHOLDER_SUFFIX}`
    const path = chips[i] ?? ''
    const chip = `<span class="md-file-chip" data-file-path="${path}">📄 ${path}</span>`
    html = html.split(placeholder).join(chip)
  }

  return html
})

const hostStyle = computed<string>(() => {
  if (!props.maxHeight) return ''
  return `max-height: ${props.maxHeight}; overflow: hidden;`
})
</script>

<template>
  <div
    class="markdown-content"
    :data-testid="testId"
    :style="hostStyle || undefined"
    v-html="renderedHtml"
  />
</template>

<style scoped>
/* Chip styling — visual marker for `@/path` references inside markdown.
   Keeps the chip readable on both light and dark backgrounds; the
   `--semantic-text-dim` muted text color echoes the inline-code chip
   already present in the .markdown-content stylesheet. */
.md-file-chip {
  display: inline-block;
  padding: 1px 6px;
  margin: 0 1px;
  border-radius: 4px;
  font-family: var(--font-mono);
  font-size: 0.85em;
  background-color: var(--color-bg-p1);
  color: var(--semantic-text);
  border: 1px solid var(--color-border);
  cursor: pointer;
  white-space: nowrap;
  transition: background-color 0.15s ease, border-color 0.15s ease;
}

.md-file-chip:hover {
  background-color: var(--color-violet);
  color: var(--color-bg);
  border-color: var(--color-violet);
}
</style>