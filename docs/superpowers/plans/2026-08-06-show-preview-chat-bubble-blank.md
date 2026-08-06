# ShowPreview.vue renders blank for HTML — fix XML params parsing

## Symptom (user report, task `task_1786002189411`, 2026-08-06)

User: *"fix the tool output show_preivew - why theres a 2 different result ? one is blank one is not, [...]"*

Screenshots showed:
- **Side panel (works):** `load_memory — example output card` rendered with snippet
  highlighting, tag chips, pagination badges — full content visible.
- **Chat bubble (blank):** `show_preview.html 2.0 KB` card with a blank white iframe
  where the HTML content should have rendered.

Same show_preview invocation. Two different places. One worked, one didn't.

## Root cause

`ShowPreview.vue` (the chat-bubble card for show_preview tool output) tried
`JSON.parse(props.parameters)` directly. In production, the parameters prop
carries the XML form produced by `jsonArgsToXml` (in `tools_wrap_output.zig`)
and XML-unescaped once by `tryUnwrapToolOutput`:

```
Backend envelope stored in DB:
  <tool>
    <name>show_preview</name>
    <parameters>
      <content_type>html</content_type>
      <content>&lt;h1&gt;Hi&lt;/h1&gt;</content>
      <title>...</title>
    </parameters>
    <success>true</success>
    <data>...</data>
  </tool>

After tryUnwrapToolOutput:
  unwrapped.parameters = '<content_type>html</content_type>
                          <content><h1>Hi</h1></content>
                          <title>...</title>'
  (one layer of XML-unescape already applied to the whole string)
```

`JSON.parse` throws `SyntaxError` on this XML (the `<` at position 0 isn't
valid JSON start). ShowPreview's try/catch silently fell through to `{}`:

```ts
const previewArgs = computed(() => {
  try {
    const parsed = JSON.parse(props.parameters) as PreviewParameters
    if (parsed && typeof parsed === 'object') return parsed
  } catch {
    // silently fall through — the real production shape never parsed
  }
  return {}  // ← production ends up here
})
```

Result: `previewArgs.value.content` was undefined. The `<PreviewContentRenderer>`
then built an iframe `srcdoc` of just `<style>html,body{margin:0...}</style>`
(the empty-content fallback). User saw a blank white iframe.

## Why the side panel worked but the chat bubble didn't

`PreviewSidePanel.vue` already handled both shapes — try XML via `findTag`
first, fall back to `JSON.parse` for legacy raw-JSON rows. ShowPreview.vue
was missed when `jsonArgsToXml`'s double-wrap was fixed (PR #55 area).
Result: the SAME preview rendered correctly in the right-side panel but
blank in the chat bubble.

## Fix (single source of truth for parameter extraction)

1. **NEW helper** `src/apps/desktop/src/helpers/previewArgs.ts`
   - `extractPreviewArgs(parameters: string | undefined | null): PreviewArgs`
   - `PreviewArgs` interface (`content_type`, `content`, `title`, `language`, `caption`)
   - Tries XML extraction first (current backend) via `findXmlTag`
   - Falls back to `JSON.parse` for legacy raw-JSON rows
   - Returns `{}` on malformed/empty input

2. **NEW test file** `src/__tests__/previewArgs.spec.ts` — 14 behavioural tests:
   - XML happy paths (html/markdown/code/image)
   - Legacy raw-JSON paths
   - Edge cases (empty string, null/undefined, malformed, truncated tags)
   - XML-takes-precedence-over-JSON invariant

3. **UPDATED** `ShowPreview.vue`:
   - Drops the local `JSON.parse(...)` branch
   - Calls `extractPreviewArgs(props.parameters)`
   - Removes the now-unused `findTag` extraction from parameters (kept for `content` envelope)

4. **UPDATED** `PreviewSidePanel.vue`:
   - Same helper, eliminating the duplicate XML/JSON extraction logic
   - The two renderers now share one source of truth (no future drift)

5. **EXPORTED** `findXmlTag` from `unwrapToolOutput.ts` (was private) so the
   new helper can reuse it.

6. **NEW regression tests** in `__tests__/ShowPreview.spec.ts` (6 tests in a
   new `production-shape parameters (XML from jsonArgsToXml)` describe block):
   - HTML iframe renders the raw HTML (the bug)
   - Markdown body is non-empty
   - Code language class appears
   - Image src is preserved
   - Title (from XML params) appears in the header
   - Raw HTML inside `<content>` is preserved through the extractor

## TDD trace

- **RED (pre-fix):** 6 new tests failed:
  - `renders the html content into the iframe when parameters are XML (production shape)` — blank iframe
  - `renders the markdown content body when parameters are XML` — empty div
  - `renders the code language class when parameters are XML` — no language-zig class
  - `renders the image src when parameters are XML` — no img element
  - `renders the title (from XML params) next to the content_type in the header` — header shows content_type instead
  - `the raw user HTML is passed through into the iframe srcdoc` — content swallowed

- **GREEN:** All 6 pass after applying the helper-based fix.

## Files

| File | Change |
|---|---|
| `src/apps/desktop/src/helpers/previewArgs.ts` | NEW — `extractPreviewArgs` + `PreviewArgs` |
| `src/apps/desktop/src/__tests__/previewArgs.spec.ts` | NEW — 14 tests |
| `src/apps/desktop/src/components/tool_outputs/ShowPreview.vue` | Use helper; remove local JSON.parse |
| `src/apps/desktop/src/components/preview/PreviewSidePanel.vue` | Use helper; eliminate duplicate logic |
| `src/apps/desktop/src/helpers/unwrapToolOutput.ts` | Export `findXmlTag` |
| `src/apps/desktop/src/__tests__/ShowPreview.spec.ts` | +6 regression tests |

## Verification

- `bunx vitest run` on touched files: 70/70 pass (14 helper + 10 old ShowPreview + 17 new ShowPreview + 29 previewSidePanel).
- `bunx vitest run src/__tests__/chatViewShowPreviewBubble.spec.ts`: 11/11 pass.
- `bun run build` (vue-tsc --build): clean.
- Full vitest suite: 221 pass / 4 fail. The 4 failures are pre-existing baseline
  (AppLayout.memoriesGate ×4, AppLayout.urlPersist ×2, DesignView.nudge ×1,
  sidebarKanbanSortUrl ×2) — unchanged from main.
- `zig build test --summary all`: 2343/2356 pass + 6 skip + 6 fail + 1 crash
  (same as main, pre-existing PR #181 baseline) — frontend-only change, zero
  backend regressions.

## Out of scope (deferred)

- **Test fixture cleanup in `previewSidePanel.spec.ts::buildEnvelope`** — still
  uses raw JSON parameters. The XML variant `buildXmlEnvelope` already exists
  and is used in 3 tests. The legacy helper is fine for back-compat.
- **Removing `unwrapToolOutput.ts::findTag` from `PreviewSidePanel.vue`** —
  still used for `findTag(activePreview.value?.content ?? '', 'content_type')`
  which extracts from the INNER envelope `<show_preview>...</show_preview>`
  (not the parameters). Different extraction path; not affected by this bug.
- **Migration plan for legacy raw-JSON rows** — no schema migration needed;
  the helper handles both shapes. Old rows in DB continue to render correctly.

## Pitfalls (record for future agents)

- **The "happy path" test fixtures often diverge from production wire format.**
  The pre-fix `ShowPreview.spec.ts::makeShowPreviewMessage` used
  `JSON.stringify(params)` (legacy shape) — which masked the production bug
  because all tests "passed" against the wrong fixture. **Always validate
  that your test fixture matches the actual production wire shape, not a
  hand-rolled convenience form.**

- **XML-escape / XML-unescape is layered.** The full production flow has:
  1. Backend's `jsonArgsToXml` → XML-escapes each JSON value (one layer)
  2. Frontend's `tryUnwrapToolOutput` → XML-unescapes the entire parameters
     string (one layer)
  Net: raw user content (with `&`, `<`, `>`) inside `<content>...</content>`
  reaches the extractor. Don't pre-escape inside the test fixture — that
  double-escapes and breaks the assertion.

- **When two components duplicate logic, ONE will lag.** Both `ShowPreview.vue`
  and `PreviewSidePanel.vue` extracted parameters locally; one (PreviewSidePanel)
  got the XML-shape fix when `jsonArgsToXml` was fixed, the other (ShowPreview)
  didn't. Future show_preview arg access should go through `extractPreviewArgs`.

## Branch / commit

- Branch: `worktree/show-preview-fix-xml-params`
- Commit: `a5855776` (squash candidate)
- Worktree: `/home/ginwa/ginwaaitoolbox/.worktrees/show-preview-fix-xml-params`
- Plan: `docs/superpowers/plans/2026-08-06-show-preview-chat-bubble-blank.md`
- Memory: `.nalar/memories/show-preview-parameters-xml-vs-json-2026-08-06.md`
- AGENTS.md changelog entry: `### 2026-08-06: ShowPreview.vue renders blank for HTML — fix XML params parsing`
