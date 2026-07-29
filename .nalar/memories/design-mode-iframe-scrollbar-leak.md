# Design mode iframe scrollbar leak — sandbox boundary

## Symptom

Design canvas elements with `overflow-x: auto` / `overflow-y: auto` /
`overflow: auto` / `overflow: scroll` show a default light-gray
webkit scrollbar (transparent track, ~8px gray thumb) inside the
iframe preview. Looks ugly against the dark nalar theme.

## Root cause

`src/apps/desktop/src/components/design/DesignElementPreview.vue:118`
renders each element in a sandboxed `<iframe sandbox="allow-scripts">`
(no `allow-same-origin`). The iframe is a **separate document** —
parent-page CSS does NOT propagate in. The host's `::-webkit-scrollbar`
rules in `style.css` are ignored inside the iframe.

## Fix (2 layers)

### 1. Each design element must embed its own scrollbar `<style>`

Top of the `html` body:

```html
<style>
  ::-webkit-scrollbar { width: 6px; height: 6px; }
  ::-webkit-scrollbar-track { background: transparent; }
  ::-webkit-scrollbar-thumb {
    background: #393836;
    border-radius: 3px;
  }
  ::-webkit-scrollbar-thumb:hover { background: #625e5a; }
  * { scrollbar-width: thin;
        scrollbar-color: #393836 transparent; }
</style>
```

Tokens:
- `#393836` = `--color-border-light`
- `#625e5a` = `--color-whitespace`

Covers WebKitGTK (Linux), WKWebView (macOS), WebView2 (Windows via
Chromium), and Firefox (via `scrollbar-width`).

### 2. The system prompt must teach the LLM about the boundary

`BuildDesignCanvasPrompt` in
`src/ai_workflow/tui/build_messages_for_agent_prompt.zig` has a
"Styling scrollbars inside the iframe" section that explains why
the iframe is separate + provides the copy-pasteable template.
Without this guidance, future designs keep leaking the default
scrollbar.

## Why static-substring tests

`BuildDesignCanvasPrompt` produces a markdown string that is
concatenated into the LLM system prompt. There's no "render the
prompt into a mock LLM" affordance. The nearest behavioural check
is "the prompt contains the right sentences" — same pattern as the
existing BuildKanbanStatusPrompt tests.

5 tests in
`src/ai_workflow/tui/build_messages_for_agent_prompt_design_canvas_test.zig`:

1. Renders non-empty markdown for design parent.
2. Mentions the iframe sandbox boundary.
3. Provides a usable `<style>` template (webkit + Firefox + tokens).
4. Lists the CSS properties that trigger the leak.
5. Returns empty string for non-design parent (regression guard).

## Test schema gotcha

`design_pages` table must include `updated_at` (NOT NULL DEFAULT
CURRENT_TIMESTAMP is fine). `listPages` reads
`COALESCE(dp.updated_at, '')` (design_model.zig:329-330) — SQLite
raises `no such column: dp.updated_at` at prepare time even when
no rows exist. Previous BuildKanbanStatusPrompt tests used a
different schema and didn't catch this.

## Reference

- Plan: `docs/plans/2026-07-28-design-mode-scrollbar-fix.md` (deleted,
  content rolled into commit message)
- Commit: `75d12bf6 fix(design): system prompt aware of iframe
  scrollbars + mockup uses dark scrollbar`
- PR: https://github.com/ginwa123/ginwaaitoolbox/pull/134
- Live scrollbar bug: kanban task `design mode scrollbar look ugly`
  (task_1785171551697)
- Render component: `src/apps/desktop/src/components/design/DesignElementPreview.vue`
- System prompt: `src/ai_workflow/tui/build_messages_for_agent_prompt.zig::BuildDesignCanvasPrompt`