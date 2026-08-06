# show_preview parameters — XML in production, JSON in tests (2026-08-06)

## Symptom (real instance, task_1786002189411)

User reported: `show_preview.html 2.0 KB` card in the chat bubble shows
a blank white iframe. Same preview in the right-side `PreviewSidePanel`
renders correctly. Two different results for the same `show_preview` invocation.

## Root cause

`ShowPreview.vue` (the chat-bubble card) tried `JSON.parse(props.parameters)`
directly. In production, `props.parameters` is the XML form produced by
the backend's `jsonArgsToXml` (tools_wrap_output.zig), not raw JSON:

```
Backend produces:
  <parameters><content_type>html</content_type>
    <content>&lt;h1&gt;Hi&lt;/h1&gt;</content></parameters>

After tryUnwrapToolOutput's XML-unescape:
  <content_type>html</content_type><content><h1>Hi</h1></content>
```

`JSON.parse` throws SyntaxError on this XML. ShowPreview's try/catch
silently fell through to `{}`, so `previewArgs.value.content` was
undefined. The iframe rendered just the empty `<style>` reset — blank
white page.

`PreviewSidePanel.vue` already handled both shapes (XML via `findTag`,
then JSON.parse fallback). ShowPreview.vue was missed when jsonArgsToXml's
double-wrap was fixed (PR #55 area). Result: two renderers, divergent
behaviour, silent regression.

## Fix (2026-08-06)

Single source of truth for parameter extraction:
`src/apps/desktop/src/helpers/previewArgs.ts::extractPreviewArgs`.

Tries XML first (current backend), falls back to JSON.parse (legacy
rows), returns `{}` on malformed input. Used by BOTH ShowPreview.vue
and PreviewSidePanel.vue. Eliminates the drift.

## Why this matters (test fixture mismatch)

The pre-fix `ShowPreview.spec.ts::makeShowPreviewMessage` used
`JSON.stringify(params)` for the parameters prop — a "legacy raw-JSON"
shape that's no longer produced by the backend. The tests passed because
the bug only manifested on the XML shape. The fixture matched the OLD
backend, not the current production wire shape.

**Lesson**: when a test fixture doesn't match production data shape,
the test only validates the test's invented shape — production bugs
slip through silently. Always verify fixtures against a live `agentic_coding.log`
capture or a backend unit test for the actual wire format.

## The full escape/unescape flow (3 layers)

```
1. Backend jsonArgsToXml (tools_wrap_output.zig)
   - Parses JSON: {"content": "<h1>Hi</h1>"}
   - Calls xmlEscape on each value: <h1>Hi</h1> → &lt;h1&gt;Hi&lt;/h1&gt;
   - Outputs: <content>&lt;h1&gt;Hi&lt;/h1&gt;</content>

2. (No second xmlEscape at wrapToolOutput level — params_xml is inserted
   directly into <parameters>{s}</parameters> template)

3. Frontend tryUnwrapToolOutput (helpers/unwrapToolOutput.ts)
   - findTag returns the inner string (no escape inside findTag)
   - unescapeXml converts the entire string back: &lt; → <, &gt; → >, &amp; → &
   - Result: unwrapped.parameters = <content><h1>Hi</h1></content>
   (raw HTML, NOT escaped — because unescape already happened)

4. extractPreviewArgs finds the <content> tag value
   - Result: previewArgs.content = <h1>Hi</h1> (raw)

5. Iframe srcdoc = `<style>...</style><h1>Hi</h1>`
   - Browser encodes for wire format: &lt;style&gt;...&lt;h1&gt;...
   - Iframe parser decodes back: <style>...</style><h1>...</h1>
   - Renders as expected H1 element ✓
```

**Test fixture rule**: the parameters string passed to `props.parameters`
should match step 3 (post-unescape, raw text inside tags) — NOT step 1
(pre-unescape, escaped text). If your fixture has escaped text inside
`<content>...</content>`, it'll double-escape when the iframe renders.

## Files

- `src/apps/desktop/src/helpers/previewArgs.ts` (new, ~95 lines)
- `src/apps/desktop/src/__tests__/previewArgs.spec.ts` (new, 14 tests)
- `src/apps/desktop/src/components/tool_outputs/ShowPreview.vue` (use helper)
- `src/apps/desktop/src/components/preview/PreviewSidePanel.vue` (use helper)
- `src/apps/desktop/src/helpers/unwrapToolOutput.ts` (export `findXmlTag`)
- `src/apps/desktop/src/__tests__/ShowPreview.spec.ts` (+6 regression tests)

## Verification

- RED phase: 6 new tests failed on pre-fix code (blank iframe, missing
  markdown body, missing image src, missing title, etc).
- GREEN phase: 17/17 pass in ShowPreview.spec.ts, 14/14 in previewArgs.spec.ts,
  29/29 in previewSidePanel.spec.ts (no regression), 11/11 in chatViewShowPreviewBubble.spec.ts.
- bun run build (vue-tsc --build) clean.
- Full vitest suite: 221 pass / 4 fail. The 4 failures are the documented
  pre-existing baseline (AppLayout.memoriesGate ×4, AppLayout.urlPersist ×2,
  DesignView.nudge ×1, sidebarKanbanSortUrl ×2) — unchanged from main.
- zig build test --summary all: 2343/2356 pass + 6 skip + 6 fail + 1 crash
  (same as main, pre-existing PR #181 baseline) — frontend-only change,
  zero backend regressions.

## Branch / commit

- Branch: `worktree/show-preview-fix-xml-params`
- Commit: `a5855776` (squash candidate)
- Plan: `docs/superpowers/plans/2026-08-06-show-preview-chat-bubble-blank.md`

## Cross-references

- Cross-project: `static-contract-test-when-to-prefer-behavioural` (the rule
  that bit this bug — fixture must match production shape)
- Cross-project: `zig-slice-headers-across-defer-lifetimes` (different but
  related fixture-must-match-production rule for Zig)

## Pitfalls (record for future agents)

- **Test fixtures that diverge from production wire shape silently mask
  bugs.** The pre-fix `JSON.stringify(params)` shape passed every test
  because no test exercised the XML path. Add an "integration" test with
  the REAL production wire shape alongside the convenience-shape tests.

- **`tryUnwrapToolOutput` is NOT a no-op.** It XML-unescapes the parameters
  string ONCE. So the value reaching `ShowPreview.vue::props.parameters`
  has the inner content as raw text (NOT escaped). Forgetting this leads
  to "missing content" bugs when the iframe renders escaped HTML as
  literal text.

- **`JSON.parse` on XML throws `SyntaxError`, not a custom error class.**
  The catch MUST silently fall through (or log + fall through). A
  re-throw would surface every production message as a tool error to
  the user.

- **Two components sharing data shape logic = future drift.** The fix
  consolidated to one helper. If a third consumer ever needs the same
  shape, route through `extractPreviewArgs` too.

- **Header comments lie.** The pre-fix `ShowPreview.vue` header comment
  claimed ChatView passes "JSON-string of the show_preview tool-call args"
  — that was true at one point but is FALSE after the jsonArgsToXml
  double-wrap fix. Comments documenting cross-component behaviour
  rot silently unless backed by tests; the new `production-shape parameters`
  describe block is the regression guard.
