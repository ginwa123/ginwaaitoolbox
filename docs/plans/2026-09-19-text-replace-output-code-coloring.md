# Plan: text_replace output code coloring

Date: 2026-09-19
Task: `text replace output code coloring` (task_1789844988331_2)
Worktree: `/home/ginwa/.config/nalar/.worktrees/text-replace-output-code-coloring-1789844985140`
Status: planning — for human review before any implementation

## 1. Problem

`text_replace` results render as monochrome plain text. The card
(`TextReplace.vue` → `_shared/DiffView.vue`) colors whole rows
red/green (removed/added) but every token inside is a single ink
color. For code edits the user cannot scan keywords, strings,
comments, or types at a glance — unlike the full file editor
(`CodeEditor.vue`, monaco) which does highlight.

Scope of this plan: colorize the **before/after code inside the
text_replace diff card only**. Not shell output, not read_file,
not generic markdown fences (those stay monochrome unless the
human approves a follow-up).

## 2. Current state (verified in repo)

### Backend — payload already carries everything the frontend needs

- Definition: `src/modules/agent/tools/text_replace.zig`
  - `TextReplaceInput { path, old_str, new_str }` (L9-13)
  - `TextReplaceResult { ok, diff_view: ?DiffView }`, `DiffView { unified, before (=old_str), after (=new_str), lines_changed }` (L30-58)
  - `generateUnifiedDiff()` builds `--- a/… / +++ b/… / @@ … @@` plus conflict-style BEFORE/AFTER block
  - Wire JSON: `TextReplaceSuccessJSON { path, unified?, before?, after?, lines_changed?, error? }` + `toJSONSuccess/toJSONError` (~L478-520). No full file content — only the changed region.
- Envelope: `src/agentic_loop/tools_wrap_output.zig:32-63` `wrapToolOutput()` → `{ tool, parameters, success, data: {inner}, error, v: 1 }`
- Exec: `src/agentic_loop/tools_exec_text_replace.zig:31-66` `execTextReplace()`; dispatch table in `src/agentic_loop/tools.zig`
- SSE: no dedicated `tool_*` event. Results ride `event: llm_full` via `src/agentic_loop/sse_on_event_send_llm_history.zig:17-48` (`SseEventLLMHistory { …, tool_calls_json, tool_call_id, tool_name, diffview_before, diffview_after, … }`). `src/agentic_loop/handle_tool.zig:780-835` splits the envelope with `parseDiffViewFromResult()` → stores `diffview_before/after` columns → re-emits via `sendSSEForId()`. REST parity: `get_llm_histories.zig:52-98`, `session_messages_get.zig:138-139`, `http_response.zig:265-266`, frontend reads via `src/apps/desktop/src/api/index.ts:1578`.

Conclusion: **no backend change needed for v1**. `path` (for language inference) + `before/after` already reach the card.

### Frontend — where the plain text lives

- Dispatcher: `src/apps/desktop/src/components/views/ChatView.vue` (~L4319-4326) `v-else-if="msg.tool_name === 'text_replace'"` → `<TextReplace :content :diffview-before :diffview-after :cwd :parameters />`
- Card: `src/apps/desktop/src/components/tool_outputs/TextReplace.vue` (186 lines)
  - `parseTextReplace(normalized.data)` (`_shared/toolOutputParser.ts:220-233`) → `{ path, before, after, unified, lines_changed, success, error }`
  - Precedence: `props.diffviewBefore/After` → envelope `before/after` → `parameters.old_str/new_str` (L84-100)
  - `ARGS_EXCLUDE = ['old_str','new_str','before','after','unified']`; renders `<DiffView v-if="hasDiff" :before :after :file-path />` (L168-174) + `<ToolParameters/>`
- Diff engine: `_shared/myersDiff.ts` — `myersDiff()` LCS-DP SES, `computeSplitView()`, `computeUnifiedView()` (`@@` hunks, 3 lines context), `computeInlineView()`; `computeInlineWordChanges()` exists but is computed-then-ignored
- Diff renderer: `_shared/DiffView.vue` — Split (default, GitHub-style) vs Unified toggle persisted in `localStorage:diffview.mode`; split rows `renderSplitRow` (L196-220) red `rgba(248,81,73,.15)` / green `rgba(46,160,67,.15)` bg+ink; unified `renderUnifiedRow` (L333-336) same palette; hunk header muted italic. L262-265 comment: word-diff deliberately removed ("impossible to parse") — rows render `text ?? '\u00a0'` as a plain text node, no tokenization, no `language-*` class.
- Clickable gutters emit `jump-to-line` → `useCodeEditor.ts:6` `openInCodeEditor({filePath, cwd, line})` (`TextReplace.vue:130-150`).

### Highlighting infra — there is none (by prior decision)

- `src/apps/desktop/package.json:26-27`: only `marked@18.0.2` + `monaco-editor@0.52.2`. No shiki/prism/hljs/lowlight. `docs/superpowers/plans/2026-09-02-llm-history-inspector-in-settings.md:172` explicitly decided *not* to add a dep for v1.
- `marked` is used without a highlight callback (`helpers/renderResponse.ts:105`, `ChatView.vue:4603`, `PreviewContentRenderer.vue:142`, `MarkdownDescription.vue:132`) → fenced blocks get `<code class="language-X">` but render monochrome. `style.css:230-252` single-ink code chip.
- Only real highlighter: `CodeEditor.vue` lazy `import('monaco-editor')` (static import banned — 96 MB workers note, L62-96 workers for json/css/html/ts only). Its `detectLanguage()` (L136-183, ext→language map: js/jsx→javascript, vue→html, py→python, zig→zig, rs→rust, toml→ini, sh/bash→shell, default plaintext) is the repo's **only language-detection table** — reusable verbatim.
- `PreviewContentRenderer.vue:154-157` `code` branch echoes `language` as a `[lang]` label only.

## 3. Options considered

| # | Approach | Pros | Cons | Verdict |
|---|----------|------|------|---------|
| A | Reuse monaco for read-only highlight in DiffView (lazy `monaco.editor.colorize` / `colorizeElement`) | Best fidelity; already a dep; same tokenizer as editor; `detectLanguage` reusable | Heaviest runtime (~MBs, worker setup); must keep lazy pattern; overkill for small diffs | **Recommended for v2 / large files**, not v1 |
| B | Add shiki (or lowlight/hljs) dep | Best static colors, no workers | New dep — needs human approval; bundle + theme-token plumbing; contradicts prior no-new-dep decision | **Needs approval — not in v1** |
| C | Hand-rolled regex tokenizer per language (keyword/string/comment/number) + CSS token classes, language from `detectLanguage(path)` | Zero deps; tiny; fits existing hand-rolled diff palette; easy to keep red/green row bg while tinting tokens | Regex highlighters are approximate (nested strings, template literals); must escape HTML first; per-language keyword lists to maintain | **Recommended for v1** |
| D | Server-side highlight (Zig emits token spans) | Single implementation | Zig has no highlighter; bloats SSE payload; duplicates frontend CSS; breaks plain-text consumers (LLM history, tests) | Rejected |

## 4. Recommended v1 (Option C — zero-dep, frontend-only)

### 4.1 Behavior

- `TextReplace.vue` derives `language = detectLanguage(filePath ?? path)` (import the existing map out of `CodeEditor.vue` into a shared helper — no duplication).
- `DiffView.vue` tokenizes each rendered line into `<span class="tok-{keyword,string,comment,number,plain}">` while **keeping** the existing row bg + red/green ink as the base. Token colors are layered *within* the row (e.g. keyword bold/brighter, string green-shifted, comment muted italic) so red=removed / green=added stays unambiguous.
- Unknown / `plaintext` language → today's plain-text path (no spans) — zero visual change.
- Split and Unified modes both colorize (same tokenizer call in `renderSplitRow` + `renderUnifiedRow`).
- `unified` raw text (the `---/+++/@@` block) stays plain — only `before/after` panes colorize.
- No backend / SSE / DB / API change. No new npm dep. No URL change (card is not a routed view).

### 4.2 Files to touch (v1)

1. NEW `src/apps/desktop/src/helpers/codeHighlight.ts` — `detectLanguage(path)` (moved verbatim from `CodeEditor.vue:136-183`), `highlightLine(line, language): Token[]` (escape-then-tokenize; languages: javascript/typescript, python, zig, rust, vue/html, css, json, shell, ini/toml, plaintext-fallback), `TOKEN_CLASS` map. ~150 lines + spec.
2. EDIT `CodeEditor.vue` — import `detectLanguage` from the helper (delete local copy; keep badge behavior identical).
3. EDIT `_shared/DiffView.vue` — accept optional `language` prop (fallback: derive from existing `file-path` prop via helper); replace plain-text node in `renderSplitRow`/`renderUnifiedRow` with token spans; add scoped `.tok-*` CSS using existing semantic tokens (no light-palette hardcodes — dark transcript: bg `#1D1C19`-family, text `#c5c9c5`, muted `#a6a69c`, border `#282727`, link `#8ba4b0`).
4. EDIT `TextReplace.vue` — compute `language` from `path`, pass to `<DiffView :language>`. No parser change (`toolOutputParser.ts` untouched).
5. EDIT `style.css` (or DiffView scoped CSS only — preferred) — `.tok-keyword/.tok-string/.tok-comment/.tok-number` colors that remain legible on both red and green row tints.
6. SPECS `codeHighlight.spec.ts` (tokenizer: keywords/strings/comments/numbers, HTML-escape, plaintext passthrough) + `DiffView.spec.ts` additions (language prop renders spans; unknown lang renders plain) + `TextReplace.spec.ts` (passes language from `.zig`/`.py`/`.vue` paths).

Explicitly OUT for v1: shiki/monaco in the diff card, `ReadFile.vue`/`ShellTool.vue`/markdown-fence highlighting, backend payload changes, new deps.

### 4.3 v2 (only if human asks)

- Swap the regex tokenizer for lazy `monaco.editor.colorizeElement` behind the same `language` prop + `IntersectionObserver` (colorize only visible cards, keep 96 MB worker caution + test stub in `__tests__/stubs/monaco-editor.ts`).
- Extend to `ReadFile.vue` (full-file, needs line-range windowing) and `PreviewContentRenderer.vue` `code` branch.

## 5. Verification

- `pnpm -C src/apps/desktop test` (vitest): new `codeHighlight.spec.ts` + updated `DiffView`/`TextReplace` specs.
- `pnpm -C src/apps/desktop run build` (pre-push hook already runs this).
- No Zig tests needed (no backend change). If the human later requests backend changes, add in-memory SQLite `useCase` test in-file; any HTTP/wire change graduates to `tests/functional/harness.py` on a free 8080-8199 port (never 8081, never `nohup`+`curl`).
- Manual: open a session, run `text_replace` on a `.zig` + a `.py` file, confirm keywords/strings/comments tint inside red/green rows in both Split and Unified modes; unknown extension (e.g. `.log`) renders exactly as today.

## 6. Risks / notes

- Regex highlighting can mis-color exotic syntax (nested template literals, Zig raw strings) — mitigated by keeping row red/green as the source of truth and token tint subtle; `plaintext` fallback for unknown langs.
- Must HTML-escape **before** tokenizing (XSS via `old_str` content rendered with `v-html`-adjacent paths — DiffView uses text nodes today; keep that property when adding spans).
- Dark-theme-only palette — reuse semantic vars, never hardcode light backgrounds.
- Keep `detectLanguage` a pure move (no behavior change in `CodeEditor.vue` badge).

## 7. Acceptance

- [ ] `text_replace` diff rows show keyword/string/comment/number tints for `.zig/.py/.ts/.vue` etc., red/green row meaning preserved, both Split + Unified
- [ ] Unknown extensions byte-identical to today
- [ ] No new dependencies, no backend/SSE changes, `pnpm build` + vitest green
- [ ] Human approves before any v2 (monaco/shiki) work starts
