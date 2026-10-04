# HTML Tag Support Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the LLM wrap raw-HTML responses in `<html>...</html>` tags, and have the chat UI render that inner content as live HTML in a sandboxed iframe instead of markdown.

**Architecture:** Three coordinated changes: (1) extend the `ResponseFormatting` system-prompt block so the model knows about the new tag; (2) teach `stripTags.ts` about `<html>` so unwrapping/visibility logic treats it like `<plain>`/`<markdown>`; (3) branch ChatView's `renderResponse` pipeline — when an assistant message contains an `<html>` block, render it via a sandboxed iframe (`sandbox="allow-scripts"`, srcdoc), mirroring the proven pattern in `PreviewContentRenderer.vue`. Backend Zig needs no functional change (verified: only `<think>` is processed server-side, for session-name generation).

**Tech Stack:** Zig 0.16 (prompt constant only), Vue 3 + TypeScript + marked@18 (frontend), vitest + @vue/test-utils.

## Global Constraints

- **Do NOT kill port 8081.** Any manual server testing uses port 8080.
- **No new npm dependencies.** No DOMPurify etc. — use the existing sandboxed-iframe pattern (`PreviewContentRenderer.vue:322`: `sandbox="allow-scripts" :srcdoc=...`). The iframe's null origin is the security boundary; inner content cannot touch parent DOM, cookies, or localStorage.
- **Surgical changes only.** Do not refactor `renderResponse`'s signature or the message-group template structure beyond what's needed for the html branch.
- **Streaming must not crash.** During token streaming, `<html>` may be unclosed mid-stream; rendering must degrade gracefully (show nothing/raw text until close tag arrives), never throw.
- **Backward compatibility:** messages with no `<html>` tag render exactly as today. Existing tests must stay green.
- **Zig prompt string syntax:** multi-line strings use `\\` line continuations inside a single const declaration — match the existing style in core.zig exactly.

## File Structure

| File | Change |
|---|---|
| `src/modules/agent/prompts/core.zig` | EDIT — add `<html>` section to `ResponseFormatting` |
| `src/apps/desktop/src/helpers/stripTags.ts` | EDIT — add `getHtmlTags`, `isHtmlTags`; extend `stripThinkingTags` to unwrap `<html>` |
| `src/apps/desktop/src/helpers/index.ts` | EDIT — re-export new helpers |
| `src/apps/desktop/src/components/views/ChatView.vue` | EDIT — html branch in `renderResponse` + iframe in template |
| `src/apps/desktop/src/__tests__/stripTags.spec.ts` | NEW — unit tests for helpers |
| `src/apps/desktop/src/__tests__/ChatView.hiddenMessages.spec.ts` | EDIT — source-contract tests for html branch |
| `tests/functional_ui/chatview_html_tag_ui_test.py` | NEW — DB-seeded Playwright E2E tests for the `<html>` render path |

---

## Task 1 — Prompt: add `<html>` to ResponseFormatting (backend)

The LLM currently has no way to emit raw HTML. Extend the formatting contract.

- [ ] T1.1 Write failing test first: create `src/modules/agent/prompts/core_test.zig` with a test asserting `ResponseFormatting` contains the literal `<html>` and `</html>` and the word "HTML". Register it in `src/root.zig` test imports if prompts tests are aggregated there (check how other module tests are registered — e.g. grep `core_test` / look at how `parse_anthropic_sse_test.zig` is wired). Run `zig build test --summary all` → expect FAIL (constant lacks `<html>`).
- [ ] T1.2 Edit `src/modules/agent/prompts/core.zig` lines 108–138: append a new **HTML Responses** paragraph after the Plain Text block:

```zig
    \\
    \\**HTML Responses:** If you want to show the user a rich rendered
    \\response, you can use HTML output wrapped inside custom XML tags:
    \\```
    \\ <html>
    \\ [complete raw HTML document or fragment here]
    \\ </html>
    \\```
    \\Example: `<html> <div>hello</div> </html>` renders as a live HTML
    \\block in the chat. The UI renders this content directly — do NOT
    \\escape or fence the markup, emit it verbatim.
```

- [ ] T1.3 Run `zig build test --summary all` → PASS. Also confirm baseline count unchanged elsewhere.
- [ ] T1.4 Commit: `feat(prompts): add <html> wrapper tag to ResponseFormatting`

### Notes
- `ResponseFormatting` flows into every main-agent system prompt automatically via `PROMPT_SECTIONS` (`prompts.zig:114`) consumed by `build_agent_prompt` (`prompts.zig:345-350`) — no wiring needed.
- Sub-agents / compaction / session-name agents don't include this block — out of scope by design.

---

## Task 2 — Helpers: teach stripTags.ts about `<html>` (frontend)

New helpers + unwrap support, mirroring the existing plain/markdown handling.

- [ ] T2.1 Write failing tests: create `src/apps/desktop/src/__tests__/stripTags.spec.ts` covering:
  - `getHtmlTags('<html><div>x</div></html>')` → `'<div>x</div>'`
  - multiple blocks joined with `\n\n` (mirror getThinkingTags)
  - returns `''` when no `<html>` present
  - `isHtmlTags('<html>a</html>')` → true; `'<think>t</think><html>a</html>'` → true; `'plain'` → false
  - `stripThinkingTags('<think>s</think><html><b>hi</b></html>')` → `'<b>hi</b>'` (think dropped, html unwrapped)
  - `stripThinkingTags('<html>a</html>')` → `'a'`
  - `stripThinkingTags('no tags')` → unchanged
  - Run `bun run test -- stripTags.spec.ts` → FAIL (helpers don't exist).
- [ ] T2.2 Implement in `src/apps/desktop/src/helpers/stripTags.ts`:
  - Add `hasHtml = /<html>/i.test(str)` alongside hasPlain/hasMarkdown (line ~12).
  - In the think-only early return (line ~15): treat `<html>` like its siblings — `if (hasThink && !hasPlain && !hasMarkdown && !hasHtml)` keep original.
  - Think-strip condition (line ~22): include `hasHtml`.
  - After markdown unwrap (line ~30): add `result = result.replace(/<html>\s*/gi, '').replace(/\s*<\/html>/gi, '')`.
  - Add `getHtmlTags(content)` mirroring `getThinkingTags` but matching `/<html>([\s\S]*?)<\/html>/gi`.
  - Add `isHtmlTags(content)`: true when stripping all `<html>` blocks leaves nothing meaningful AND at least one exists.
- [ ] T2.3 Export from `src/apps/desktop/src/helpers/index.ts` line 1.
- [ ] T2.4 Run helper tests → PASS. Then run FULL suite `bun run test` → all green (hiddenMessages spec asserts lone-think passthrough — verify unaffected).
- [ ] T2.5 Commit: `feat(helpers): add getHtmlTags/isHtmlTags + unwrap <html> in stripThinkingTags`

### Pitfall
- `stripThinkingTags` is used for **visibility filtering** (ChatView L1213/L1417/L2362). Unwrapping `<html>` there means html-only messages stay visible — desired. But do NOT remove the `<html>` regex from the think-only early-return guard, or thinking+html messages would leak raw `<think>` text into marked.

---

## Task 3 — ChatView: render `<html>` blocks in a sandboxed iframe (frontend)

The core UX change. Branch the render pipeline on html-tagged content.

- [ ] T3.1 Write failing source-contract tests in `ChatView.hiddenMessages.spec.ts` (source-grep style, mirroring existing F1 contract tests):
  - source contains `isHtmlTags(` inside `renderResponse` body region
  - source contains `sandbox="allow-scripts"` within the assistant-message template region (between `assistant-messages` div and end of file)
  - source contains `renderHtmlBlocks(` referenced in template
  - Run → FAIL.
- [ ] T3.2 Implement in `ChatView.vue`:
  - Import new helpers (line 6): add `getHtmlTags, isHtmlTags`.
  - Add a small component-level function `extractHtmlBlocks(content): {pre: string, blocks: string[]}[]`... simpler: implement `splitHtmlContent(content): { before: string, blocks: string[], after: string }` returning surrounding non-html text plus each `<html>...</html>` inner payload (regex `/<html>([\s\S]*?)<\/html>/gi`).
  - In `renderResponse` (after the isThinkingTags branch, line ~211):
    ```ts
    const htmlBlocks = getHtmlTags(content)
    if (htmlBlocks) {
      // handled by template via renderHtmlBlocks; return '' here would hide the bubble...
    ```
    **Design decision (locked):** `renderResponse` stays a pure string renderer. For html-containing messages, the TEMPLATE branches FIRST: compute `msgHasHtml(msg.content)` per message; if true, render `<iframe sandbox="allow-scripts" :srcdoc="buildSrcdoc(...)">` per block plus normal `v-html="renderResponse(...)"` for any surrounding text outside the tags. This keeps v-html path untouched for all legacy content.
  - Template edit at the assistant-item span (lines 3140–3154): wrap in a conditional:
    ```html
    <template v-if="msgHasHtml(msg.content)">
      <div v-for="(block, bIdx) in extractHtmlBlocks(msg.content)" :key="bIdx">
        <!-- eslint-disable-next-line vue/no-v-html -->
        <span v-if="block.before" v-html="marked.parse(block.before, { async: false })"></span>
        <iframe class="chat-html-frame" sandbox="allow-scripts" :srcdoc="block.html" ...></iframe>
     div>
    </template>
    <span v-else v-html="renderResponse(...)">...</span>
    ```
    (fix the typo'd closing tag above when writing real code)
  - `buildSrcdoc(block)`: wraps fragment in a minimal document with `<base target="_blank">`? No — keep minimal: if block starts with `<html`/contains `<body`, use verbatim; else wrap in `<!DOCTYPE html><html><head><meta charset="utf-8"><style>body{margin:8px;font-family:system-ui}</style></head><body>${block}</body></html>`.
  - Streaming safety: unclosed `<html>` mid-stream matches nothing (regex requires close tag) → falls to v-else legacy path showing raw text until close arrives, then flips to iframe. Acceptable degradation, no crash.
- [ ] T3.3 Add scoped CSS for `.chat-html-frame` (width 100%, min-height 120px, border rounded, background white).
  - Optional polish (skip unless trivial): auto-resize via postMessage listener — PreviewContentRenderer has a protocol (L83–138); NOT required for first cut.
  - Optional height hint: parse `height="..."` attribute on the opening `<html ...>` tag if present; skip if fiddly.
- [ ] T3.4 Run targeted specs → PASS; then full `bun run test` → green; `npm run build` (vue-tsc) → clean.
- [ ] T3.5 Commit: `feat(chatview): render <html> response blocks in sandboxed iframe`

### Pitfalls
- **Don't put the iframe inside `renderResponse`'s returned string** — nested v-html of an iframe works but breaks the "pure string" contract and complicates streaming. Template branching keeps concerns separate.
- **jsdom + iframe srcdoc**: jsdom doesn't execute srcdoc content; tests assert attributes only (`sandbox`, `srcdoc` presence), never inner execution.
- **Multiple `<html>` blocks**: loop them; don't assume one.
- **`hasVisibleContent` (L1417)** uses `stripThinkingTags(...).trim().length > 0` — since Task 2 made stripThinkingTags unwrap `<html>`, html-only messages remain visible automatically. Verify with a unit assertion in T2.1 (`stripThinkingTags('<html>a</html>').length > 0`).

---

## Task 4 — Functional UI test: DB-seeded Playwright coverage for `<html>` rendering

Real-Chromium E2E in `tests/functional_ui/` (the suite's whole point: jsdom can't execute iframe srcdoc, real Chromium can). Follows `chatview_ui_test.py` conventions exactly — seed `sessions` + `llm_history` rows via `DbSeed`, navigate to `/app?view=chat&session=<id>`, assert rendered DOM. No real LLM.

- [ ] T4.1 Create `tests/functional_ui/chatview_html_tag_ui_test.py` with 5 tests:
  1. **html-only assistant message renders an iframe** — seed assistant text `<html><button id="probe" onclick="document.title='clicked'">Click</button></html>`; assert `page.wait_for_selector("iframe.chat-html-frame")`; assert its `sandbox` attribute == `"allow-scripts"`; assert NO `.markdown-content` wrapper around it.
  2. **inner HTML actually executes (real Chromium advantage)** — locate the iframe's content frame (`locator.content_frame` / `frame_locator("iframe.chat-html-frame")`), assert the button is present and **click it**, then verify the click handler ran (e.g. `page.title()` changed or a JS-set marker attribute appears) — proves scripts run inside the sandbox rather than being inert markup.
  3. **mixed message: surrounding markdown + html block** — seed `Here is your widget:\n<html><b>live bold</b></html>\nEnjoy!`; assert BOTH the marked-rendered text ("Here is your widget:" inside `.markdown-content`) AND the iframe exist; assert iframe srcdoc contains `live bold`.
  4. **legacy messages untouched** — seed a plain markdown assistant message; assert zero `iframe.chat-html-frame` on page and normal `.markdown-content h1` renders (regression guard).
  5. **unclosed tag degrades safely** — seed assistant text `<html><div>never closed` (no close tag); assert no iframe appears and no console error/crash — raw text path shows through.
- [ ] T4.2 Seed-shape notes: use `DbSeed.seed_assistant_message(conn, sid, text=...)` with the raw tagged string as `response_content` — identical to how production stores LLM output (tags included); timestamps via `DbSeed.baseline_timestamps(count=2)`; reuse `_open_chatview` + `_wait_for_text` patterns from `chatview_ui_test.py`.
- [ ] T4.3 Run:
  ```bash
  PABRIK_BIN=./zig-out/bin/pabrik pytest tests/functional_ui/chatview_html_tag_ui_test.py -v
  ```
  All 5 pass. Backend port comes from harness pool (8080, 8082–8199 — never 8081).
- [ ] T4.4 Update `tests/functional_ui/README.md` "Covered scenarios" list (+1 entry pointing at the new file).
- [ ] T4.5 Commit: `test(functional-ui): DB-seeded Playwright coverage for <html> chat rendering`

### Pitfalls
- **iframe sandbox blocks same-origin reads** — with `sandbox="allow-scripts"` (no `allow-same-origin`) the frame is null-origin; `frame_locator` still works for DOM queries but `frame.evaluate` of parent-page globals won't. Assert via DOM presence + click effects, not cross-frame JS state.
- **VirtualScroller viewport caveat** — single-message sessions render fully; keep each test's session small so the html bubble is always mounted.
- **Playwright auto-waiting** — `wait_for_selector` on the iframe only proves attachment; srcdoc load is async, so follow with an explicit wait for inner content before asserting.
- If Vite cold-start makes tests flaky locally, warm once with any existing `chatview_ui_test.py` run first.

---

## Task 5 — Full verification & docs

- [ ] T5.1 Frontend: `cd src/apps/desktop && bun run lint:check && bun run type-check && bun run test && npm run build` — all green.
- [ ] T5.2 Backend: `zig build test --summary all` — all green, no leaks.
- [ ] T5.3 Functional UI: `PABRIK_BIN=./zig-out/bin/pabrik pytest tests/functional_ui/ -v` — full suite green including the new html-tag file.
- [ ] T5.4 Manual smoke (optional, port 8080 only — NEVER 8081): send a chat message asking for a simple HTML button; confirm iframe renders clickable button; confirm legacy markdown messages unchanged.
- [ ] T5.5 Commit any stragglers; push branch `worktree/html-tag-support`; open PR referencing this plan.

## Verification Checklist

- [ ] Prompt includes `<html>` instructions (grep core.zig)
- [ ] `getHtmlTags`/`isHtmlTags` exported and tested
- [ ] `stripThinkingTags` unwraps `<html>` (visibility preserved)
- [ ] ChatView renders html blocks as sandboxed iframes; legacy path untouched
- [ ] Functional UI: 5 Playwright tests green (iframe renders, scripts execute, mixed content, legacy untouched, unclosed-tag safety)
- [ ] All frontend checks green (lint/type/test/build)
- [ ] zig build test green
