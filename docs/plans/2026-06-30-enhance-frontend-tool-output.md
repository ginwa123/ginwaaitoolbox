# Enhance Frontend Tool Output Display

**Date:** 2026-06-30
**Author:** Frontend-tool review (this document)
**Scope:** `src/apps/desktop/src/components/tool_outputs/*.vue` (19 files, 3,550 lines) + a shared `ToolCardHeader` + a shared `DiffView` rewrite
**Risk:** Low-to-medium (large refactor, but each chunk keeps the existing test matrix green; the chat view is touched only by chunk 6)

---

## 1. Problem

The 19 tool-output components in `src/apps/desktop/src/components/tool_outputs/` were authored independently and have drifted into a maintenance nightmare. The most damaging patterns:

### 1.1 Two parallel implementations of the same diff view

- `TextReplace.vue:132-163` has its own inline split-view diff (Tailwind utilities).
- `DiffView.vue:19-39` is the *separate* diff view rendered by the fallback branch of `ChatView.vue:2312-2316` for tools whose `diffview_before` / `diffview_after` are populated but who don't have a dedicated component.

Both render essentially the same before/after table. They use different styling (Tailwind inline vs scoped CSS), different diff algorithms (both broken — see 1.3), and the same broken `isLineChanged` predicate.

### 1.2 Position-based diff is mathematically wrong

Both `TextReplace.vue:61-63` and `DiffView.vue:14-16` use:

```ts
const isLineChanged = (idx: number): boolean => {
  return beforeLines.value[idx] !== afterLines.value[idx]
}
```

If `old_str` is inserted in the middle of a file, every line **after** the insertion point is falsely highlighted as changed — the lines are identical, they just shifted down by N. There is no concept of "moved vs changed", no word-level highlight, no line numbers.

### 1.3 Header / chrome duplication across 19 components

Every tool output component (ReadFile, WriteFile, TextReplace, RemoveFile, EditSkill, AddSkill, RemoveSkill, ViewSkill, Search, ListSkills, MemoryList, SkillList, SetGitWorktree, ReadCompactedMessages, KanbanMove, KanbanList, NalarBrowser, SpawnSubAgent) reimplements the same header structure:

- container `<div>` with the same Tailwind class string (~80 chars, repeated 19×)
- tool-name pill (`<span class="text-[var(--color-violet)] font-semibold text-xs">read_file</span>` style)
- primary field display (path / skill name / etc) — copy-to-clipboard button
- "open in code editor" button (`useInjectOpenInCodeEditor`, `cwd` plumbing)
- success / error badge with `✓` / `✗`
- `isExpanded` ref + `toggle()` handler
- error message block

This is ~30 lines of duplicated boilerplate per component × 19 components = ~570 lines of pure duplication.

### 1.4 Regex XML parsing is duplicated and fragile

Every component hand-rolls:

```ts
const match = props.content.match(/<path>(.*?)<\/path>/)
const matchMulti = props.content.match(/<content>([\s\S]*?)<\/content>/)
```

- Mix of `.*?` (no newlines) and `[\s\S]*?` (with newlines) — inconsistent, easy to get wrong.
- Silent failures: missing tags return `null` and the UI silently falls back to "unknown".
- The envelope wrapper from `unwrapToolOutput.ts` already strips `<tool>...</tool>` and unescapes XML — but every component re-runs regex on the inner `data` string instead of using a typed parser.
- `text_replace.zig:478-486` (`toXmlSuccess`) does not XML-escape the path / old_str / new_str fields. A path containing `&` or `<` will silently corrupt the parsed output. (Verified — `xmlEscape` is used by `llm_history.zig:762` and the envelope wrapper, but not by `toXmlSuccess`.)

### 1.5 No component-level tests

The `__tests__/` folder has 47 files but **zero** for any `tool_outputs/*.vue` component. The regex parsers, the diff predicate, the toggle logic, the path-copy button — none are covered. Any refactor breaks silently.

### 1.6 Rich backend data is generated then thrown away

`text_replace.zig:373-394` computes a full unified diff with `@@ -start,count +start,count @@` hunk headers, context lines, and a `<<<<<<< BEFORE / ======= / >>>>>>> AFTER` split-view marker block. It also counts `lines_changed`. **All three are computed but the frontend only reads `before` and `after`** (and even `lines_changed` is dropped at the XML-emit step — `toXmlSuccess` includes it but no parser reads it).

### 1.7 No way to navigate from the diff to the file

The header has "copy path" and "open in editor", but you can't jump to *the specific line* of the diff in the editor. The `useCodeEditor` composable accepts only `{ filePath, cwd }` — no line number support.

---

## 2. Goal

A frontend tool-output system that is:

1. **One shared `ToolCardHeader`** — eliminates the 19× duplication, single source of truth for tool-result chrome.
2. **One shared `DiffView`** — real Myers diff with line numbers, word-level highlights, split/unified toggle, and "open file at line N" jump.
3. **One shared `toolOutputParser`** — typed accessors for the standard tags (`<path>`, `<error>`, `<success>`, `<content>`, etc.), XML-aware (handles escaping, multiline, namespaces).
4. **Tests for every shared component and parser** — coverage that catches refactor regressions.
5. **Backend emits the unified diff and exposes it via the API** — frontend uses it for the unified view mode.

Out of scope: changing the inner `<data>` format of any individual tool, redesigning the chat bubble layout, replacing the existing `unwrapToolOutput` envelope, migrating to a different design system.

---

## 3. File Structure

### New files
- `src/apps/desktop/src/components/tool_outputs/_shared/ToolCardHeader.vue` — single shared header (chunk 1).
- `src/apps/desktop/src/components/tool_outputs/_shared/DiffView.vue` — replacement for both old diff views (chunk 2).
- `src/apps/desktop/src/components/tool_outputs/_shared/myersDiff.ts` — pure-function Myers diff + split/unified renderers (chunk 2).
- `src/apps/desktop/src/components/tool_outputs/_shared/toolOutputParser.ts` — typed tag extractors, replaces ad-hoc regex in each component (chunk 3).
- `src/apps/desktop/src/components/tool_outputs/_shared/__tests__/ToolCardHeader.spec.ts`
- `src/apps/desktop/src/components/tool_outputs/_shared/__tests__/DiffView.spec.ts`
- `src/apps/desktop/src/components/tool_outputs/_shared/__tests__/myersDiff.spec.ts`
- `src/apps/desktop/src/components/tool_outputs/_shared/__tests__/toolOutputParser.spec.ts`

### Modified files (header migration)
- `src/apps/desktop/src/components/tool_outputs/ReadFile.vue` — uses ToolCardHeader (chunk 1).
- `src/apps/desktop/src/components/tool_outputs/WriteFile.vue` — uses ToolCardHeader (chunk 1).
- `src/apps/desktop/src/components/tool_outputs/RemoveFile.vue` — uses ToolCardHeader (chunk 1).
- `src/apps/desktop/src/components/tool_outputs/EditSkill.vue` — uses ToolCardHeader (chunk 1).
- `src/apps/desktop/src/components/tool_outputs/AddSkill.vue` — uses ToolCardHeader (chunk 1).
- `src/apps/desktop/src/components/tool_outputs/RemoveSkill.vue` — uses ToolCardHeader (chunk 1).
- `src/apps/desktop/src/components/tool_outputs/ViewSkill.vue` — uses ToolCardHeader (chunk 1).
- `src/apps/desktop/src/components/tool_outputs/SetGitWorktree.vue` — uses ToolCardHeader (chunk 1).

### Modified files (parser migration)
- All 8 files above + `Search.vue`, `ListSkills.vue`, `SkillList.vue`, `MemoryList.vue`, `ReadCompactedMessages.vue`, `KanbanMove.vue`, `KanbanList.vue`, `NalarBrowser.vue`, `SpawnSubAgent.vue`, `TextReplace.vue` → use `toolOutputParser.ts` (chunk 3).

### Modified files (DiffView + parser)
- `src/apps/desktop/src/components/tool_outputs/TextReplace.vue` — uses shared `DiffView` (chunk 2).
- `src/apps/desktop/src/components/ChatView.vue:2312-2316` — fallback diff branch uses shared `DiffView` (chunk 2).
- `src/apps/desktop/src/components/Bash.vue` — uses parser (chunk 3).
- `src/apps/desktop/src/api/index.ts:546-558` — Message interface gains `diffview_unified?: string` (chunk 4).
- `src/apps/desktop/src/composables/useCodeEditor.ts` — accepts `line?: number` (chunk 5).
- `src/apps/desktop/src/components/GitFileViewer.vue` (consumer) — passes line through when triggered from diff (chunk 5).

### Backend modifications
- `src/modules/agent/tools/text_replace.zig:478-486` — XML-escape path/old_str/new_str; include `unified` and `lines_changed` in output (chunk 4).
- `src/ai_workflow/tui/llm_history.zig` (or whichever serializes `diffview_before` / `diffview_after` / `diffview_unified` to the API) — emit the new `diffview_unified` field (chunk 4).

### New tests
- `src/apps/desktop/src/components/tool_outputs/__tests__/TextReplace.spec.ts`
- `src/apps/desktop/src/components/tool_outputs/__tests__/ReadFile.spec.ts`
- `src/apps/desktop/src/components/tool_outputs/__tests__/WriteFile.spec.ts`
- `src/apps/desktop/src/components/tool_outputs/__tests__/RemoveFile.spec.ts`
- `src/apps/desktop/src/components/tool_outputs/__tests__/EditSkill.spec.ts`

### Out of scope
- The fallback `renderResponse` in `ChatView.vue:152-340` (the inline tool-summary string) — separate refactor.
- The `KanbanView` / `KanbanColumn` etc. (these are user-facing kanban components, not tool-output renderers).
- Migrating to Monaco / Shiki for syntax highlighting (deferred — chunk 7 stretch goal).
- Visual redesign beyond what the new shared components naturally provide.

---

## 4. Data Flow (before / after)

### Before
```
Backend tool → execBash/execTextReplace/etc. → toXmlSuccess / toXmlError
   ↓ (no XML escaping on path/old_str/new_str; lines_changed ignored)
SSE "full" event { content: "<success>true</success><path>/foo</path>..." }
   ↓
ChatView.vue: renderResponse() parses with ad-hoc regex (string form)
   ↓
<TextReplace :content="..." /> ← also parses with ad-hoc regex
   ↓
isLineChanged(idx) = beforeLines[idx] !== afterLines[idx]  ← broken for inserts
```

### After
```
Backend tool → toXmlSuccess / toXmlError (XML-escape all user-supplied fields; include unified diff + lines_changed)
   ↓
SSE "full" event { content: "<success>true</success><path>/foo</path>...",
                    diffview_before, diffview_after, diffview_unified }
   ↓
ChatView.vue: passes content + diff props to dedicated component
   ↓
<TextReplace :content="..." :diffview-before="..." :diffview-after="..." :diffview-unified="..." />
   ↓
toolOutputParser extracts { success, path, error, before, after, unified, linesChanged }
   ↓
<ToolCardHeader :tool-name="text_replace" :primary="path" :success="...">  ← shared
<DiffView :before :after :unified @jump-to-line="openInEditor({filePath, line})" />  ← shared Myers diff
```

---

## 5. API / Type Changes

### 5.1 `Message` interface (`src/apps/desktop/src/api/index.ts:546-558`)

Add `diffview_unified?: string` and `diffview_lines_changed?: number`:

```ts
export interface Message {
  // ... existing ...
  diffview_before?: string
  diffview_after?: string
  diffview_unified?: string          // NEW
  diffview_lines_changed?: number    // NEW (optional, populated when available)
  // ... existing ...
}
```

### 5.2 `useCodeEditor` composable

Extend the inject contract to accept a `line` parameter (defaults to 1):

```ts
export interface OpenInEditorRequest {
  filePath: string
  cwd?: string
  line?: number        // NEW
}
```

The `GitFileViewer` consumer renders `requestedLine` in the editor gutter when present.

### 5.3 Tool-output parser contract (`toolOutputParser.ts`)

```ts
export interface ParsedToolOutput<TFields extends Record<string, string> = {}> {
  success: boolean
  error: string | null
  fields: TFields  // typed extractors per tool
}

// Generic tag extractor (replaces ad-hoc regex)
export function extractTag(content: string, tag: string, multiline = false): string | null

// XML-aware: handles &lt; &gt; &amp; &quot; &apos; in attribute / text values
export function extractAttribute(content: string, tag: string, attr: string): string | null

// Per-tool parsers (each is < 20 lines, replaces ~30 lines of regex per component):
export function parseTextReplace(content: string): {
  path: string
  before: string
  after: string
  unified: string
  linesChanged: number
  error: string | null
}
export function parseReadFile(content: string): {
  path: string
  content: string
  totalLines: number
  startLine: number
  endLine: number
  error: string | null
}
export function parseWriteFile(content: string): { path: string; error: string | null }
export function parseRemoveFile(content: string): { path: string; error: string | null }
export function parseEditSkill(content: string): {
  skillName: string
  edited: boolean
  path: string | null
  error: string | null
}
// ... and one parser per component (chunk 3)
```

Each parser handles XML escaping consistently and returns `null` for missing optional fields.

### 5.4 `ToolCardHeader` props

```ts
interface Props {
  toolName: string            // e.g. "text_replace"
  primary: string | null      // path / skill name / search pattern — displayed as the main field
  primaryTitle?: string       // hover tooltip (typically the same as primary)
  success: boolean
  errorMessage?: string | null
  expanded: boolean
  expandable: boolean         // false = no expand toggle (e.g. RemoveFile with no error)
  cwd?: string
  rightMeta?: string          // optional small text shown to the right of primary (e.g. "12L", "3 matches")
  statusVariant?: 'success' | 'error' | 'warning' | 'info'  // controls badge color
}

const emit = defineEmits<{
  'update:expanded': [boolean]
  'jump-to-line': [{ line: number }]
}>()
```

Renders: tool-name pill (violet) + truncated primary + optional right meta + success badge + copy button + open-in-editor button + expand/collapse chevron.

---

## 6. Shared Components

### 6.1 `ToolCardHeader.vue` (chunk 1)

The exact same header now used by all 8 file/skill-output components. Internals:

- Container `<div>` with the shared Tailwind class string (single source of truth).
- Tool-name pill (violet, semibold, xs).
- Primary field: `<span class="flex-1 truncate ..." :title="primaryTitle">{{ primary || 'unknown' }}</span>`.
- Right meta (optional): `<span v-if="rightMeta" class="text-muted text-xs">{{ rightMeta }}</span>`.
- Status badge: ✓/✗/⚠ with color from `statusVariant`.
- Copy button (`opacity-0 group-hover:opacity-100`).
- Open-in-editor button (only if `cwd && openInEditor && primary`).
- Chevron (`−` / `+`) on the right when `expandable`.

The header is presentational only — no parsing logic. Each component does the parsing and passes already-resolved props. This keeps the header decoupled from the tool's XML format.

### 6.2 `myersDiff.ts` (chunk 2)

Pure-function Myers diff algorithm. Inputs: `before: string`, `after: string`. Output:

```ts
interface DiffOp {
  type: 'equal' | 'insert' | 'delete'
  beforeLine: number | null  // 1-indexed; null for inserts
  afterLine: number | null   // 1-indexed; null for deletes
  text: string
  // Word-level diff for changed lines (Myers per word within the line)
  inlineChanges?: Array<{ start: number; end: number; type: 'equal' | 'insert' | 'delete' }>
}
```

Three exported renderers:

1. `computeSplitView(before, after): DiffRow[]` — produces rows for the side-by-side view, with empty cells for inserts/deletes.
2. `computeUnifiedView(before, after, contextLines = 3): DiffRow[]` — produces rows for the unified view, with `@@ -start,count +start,count @@` hunk headers, folded context.
3. `computeInlineView(before, after): DiffRow[]` — produces a single-column view (used for the inline fallback in collapsed mode).

Algorithm: classic Myers O(ND) for the line-level diff; per-line LCS for word-level diff on changed lines.

Library decision: **hand-roll Myers**, do not pull in `diff` / `diff-match-patch`. Reason: those libraries are large (~50KB minified) and we only need 80% of their features. Hand-rolling Myers is ~100 lines and runs at the speed of JS — for files up to 5,000 lines (well above the typical edit), it returns in <10ms.

### 6.3 `DiffView.vue` (chunk 2)

Replaces both old diff views. Props:

```ts
interface Props {
  before: string
  after: string
  unified?: string              // pre-rendered unified diff from backend (optional)
  language?: string             // for future syntax highlighting (chunk 7)
  filePath?: string             // for "open at line N" jump
  cwd?: string                  // for "open at line N" jump
  initialMode?: 'split' | 'unified'  // default 'split'
}

const emit = defineEmits<{
  'jump-to-line': [{ line: number }]
}>()
```

Features:

- Mode toggle in header (Split / Unified) — uses button group, persists per-mount in `localStorage['diffview.mode']`.
- Gutter with line numbers (1-indexed, dual for split view: `before` line on left side, `after` line on right side).
- Word-level highlights inside changed lines (yellow/green background).
- "Empty lines" rendered as dimmed `<span>` so the diff stays aligned.
- Hover on a line number → small button appears that fires `@jump-to-line({ line })` for the parent to open the editor at that line.
- Long lines: `overflow-x: auto` with `text-wrap: nowrap` (preserves the diff layout).
- Respects `prefers-color-scheme` for the highlight colors.

### 6.4 `toolOutputParser.ts` (chunk 3)

See section 5.3 above. ~20 small functions, one per tool. Each is XML-aware (handles escaping, returns `null` for missing optional fields). Each has its own spec file with cases for: success body, error body, multiline content, special chars in content (`<`, `>`, `&`), missing tags.

---

## 7. Backend Changes

### 7.1 `text_replace.zig` (chunk 4)

Modify `toXmlSuccess` at `text_replace.zig:471-498` to:

1. XML-escape `path` (it can contain `&` in `&`-separated filenames — though rare, it's user-controlled input).
2. Include the `unified` field in the XML output.
3. Use `lines_changed` (currently emitted but ignored).

The escaping must use the same `xmlEscape` function used by `llm_history.zig:762` and `tool_output_wrapper.zig` — extract a shared helper if not already shared.

### 7.2 `xmlError` (chunk 4)

`text_replace.zig:459-468` should also XML-escape its fields, particularly `old_str` and `new_str` (user-provided).

### 7.3 Diff view serialization (chunk 4)

Add a new field `diffview_unified TEXT` to the `llm_history` table (migration 055). Populated whenever the tool that produced the row has a `unified` field. Read by `sessionMessagesHandler` and emitted in the API response as `diffview_unified`.

The same field already exists for `before` / `after` (the `diffview_before TEXT` / `diffview_after TEXT` columns added in earlier migrations). Add `diffview_lines_changed INTEGER` too.

---

## 8. Chunks

### Chunk 1: Extract `ToolCardHeader` + migrate 8 file/skill components

**Goal:** One shared header, eight components migrated. Build green at end of chunk.

Tasks:
- [ ] Create `src/apps/desktop/src/components/tool_outputs/_shared/ToolCardHeader.vue` with the props from §5.4.
- [ ] Migrate `ReadFile.vue` (smallest example — header only, content unchanged).
- [ ] Migrate `WriteFile.vue` (similar to ReadFile; introduces the success/error border styling).
- [ ] Migrate `RemoveFile.vue` (smallest — no editor button needed).
- [ ] Migrate `EditSkill.vue`, `AddSkill.vue`, `RemoveSkill.vue`, `ViewSkill.vue` (same pattern, different primary field).
- [ ] Migrate `SetGitWorktree.vue` (slight variation — no editor button, just copy).
- [ ] Write `__tests__/ToolCardHeader.spec.ts` — 6 tests covering: renders tool name, primary, badge, copy button (mocked clipboard), expand toggle (emits), open-in-editor (emits).
- [ ] Run `bunx vitest run ToolCardHeader` — must be green before chunk 2.
- [ ] Run `bun run build` — must be type-clean.
- [ ] Run `bunx vitest run` (full suite) — must show **at least** the same count as before + 6 new tests.

**Files touched:** 1 new + 8 modified + 1 new test.
**Lines changed:** ~30 lines removed per component × 8 = ~240 lines removed; ~120 lines added (new shared header + tests).

**Out of scope for this chunk:** The 4 components without a primary "file path" field (Search, ListSkills, KanbanMove, KanbanList, ReadCompactedMessages, MemoryList, SkillList, NalarBrowser, SpawnSubAgent, TextReplace). They get migrated in chunk 3 once `toolOutputParser.ts` lands.

### Chunk 2: Replace `DiffView` with Myers-based shared component + migrate `TextReplace`

**Goal:** One correct diff view, no more inline duplicate in `TextReplace.vue`. Build green at end of chunk.

Tasks:
- [ ] Implement `myersDiff.ts` (§6.2). Pure functions, no DOM.
- [ ] Write `__tests__/myersDiff.spec.ts` with 12 tests covering: empty inputs, identical inputs, single insert, single delete, single replace, multi-hunk, line-shift (the case that broke the old impl), word-level diff inside a changed line, UTF-8 multi-byte content, very long lines (>1KB), line numbers stable across hunk boundaries.
- [ ] Create `_shared/DiffView.vue` (§6.3). Mode toggle, line numbers, word-level highlights, `@jump-to-line` emit.
- [ ] Write `__tests__/DiffView.spec.ts` with 6 tests covering: renders both modes, mode toggle, emits jump-to-line, renders line numbers correctly in both views, handles empty before/after, handles very long lines (overflow-x).
- [ ] Migrate `TextReplace.vue` — replace inline diff at lines 132-163 with `<DiffView :before :after :unified :file-path="path" :cwd />`.
- [ ] Update `ChatView.vue:2312-2316` — the fallback diff branch also uses the new shared component.
- [ ] Delete the old `DiffView.vue` (the standalone one).
- [ ] Run `bunx vitest run` (full suite) — must show **at least** the previous count + 12 + 6 = 18 new tests.
- [ ] Run `bun run build` — must be type-clean.

**Files touched:** 2 new (`myersDiff.ts`, `_shared/DiffView.vue`), 1 deleted (old `DiffView.vue`), 2 modified, 2 new tests.

**Lines changed:** ~80 lines removed (old `TextReplace.vue` diff section + old `DiffView.vue`); ~250 lines added (`myersDiff.ts` + tests + new `DiffView.vue` + tests).

### Chunk 3: `toolOutputParser.ts` + migrate remaining 11 components

**Goal:** One typed parser, every regex `match(...)` call replaced. Build green at end of chunk.

Tasks:
- [ ] Create `_shared/toolOutputParser.ts` with the 11 parsers in §5.3.
- [ ] Write `__tests__/toolOutputParser.spec.ts` with ~5 tests per parser × 11 parsers = 55 tests. Cases: success body, error body, multiline content, special chars (`<`, `>`, `&`, `"`, `'`), missing tags return `null`, empty content.
- [ ] Migrate the remaining 11 components to use parsers:
  - `Search.vue`, `ListSkills.vue`, `SkillList.vue`, `MemoryList.vue`, `ReadCompactedMessages.vue`, `KanbanMove.vue`, `KanbanList.vue`, `NalarBrowser.vue`, `SpawnSubAgent.vue`, `TextReplace.vue` (parser side only; diff side was chunk 2), `ReadFile.vue`/`WriteFile.vue`/`RemoveFile.vue` (parser side — they were migrated to ToolCardHeader in chunk 1 but still use ad-hoc regex for `<path>` / `<error>`).
  - `Bash.vue` (in `components/`, not `tool_outputs/`, but uses the same regex pattern).
- [ ] Delete the old per-component regex code.
- [ ] Add `__tests__/ReadFile.spec.ts`, `__tests__/WriteFile.spec.ts`, `__tests__/TextReplace.spec.ts`, etc. — minimal snapshot-style tests that verify each component renders the correct header for typical inputs.
- [ ] Run `bunx vitest run` (full suite) — must show previous count + 55 parser tests + 5+ new component tests.
- [ ] Run `bun run build` — must be type-clean.

**Files touched:** 1 new (`toolOutputParser.ts`), 12 modified components, 1 new parser test, 5+ new component tests.

**Lines changed:** ~30 lines of regex removed per component × 12 = ~360 lines removed; ~220 lines added (parsers + tests).

### Chunk 4: Backend — XML-escape, expose unified diff via API

**Goal:** The unified diff and `lines_changed` reach the frontend. The path / old_str / new_str fields are XML-escaped.

Tasks:
- [ ] Modify `text_replace.zig:471-498` (`toXmlSuccess`):
  - XML-escape `path` field.
  - Include the `unified` field in the emitted XML.
  - Confirm `lines_changed` is included (already is, but verify the frontend can read it).
- [ ] Modify `text_replace.zig:459-468` (`xmlError`):
  - XML-escape `path`, `old_str`, `new_str`.
- [ ] Refactor: if `xmlEscape` is not already shared, extract it to a helper in `text_replace.zig` (or in the existing `llm_history.zig` location) and reuse.
- [ ] Add migration 055: `diffview_unified TEXT`, `diffview_lines_changed INTEGER` columns on `llm_history`.
- [ ] Update `llm_history.zig` save path: when the tool message is a `text_replace` (or any future tool that emits unified diffs), store `unified` in `diffview_unified` and `lines_changed` in `diffview_lines_changed`.
- [ ] Update `sessionMessagesHandler` (wherever `diffview_before`/`after` are currently emitted) to also emit `diffview_unified` and `diffview_lines_changed`.
- [ ] Update `Message` interface in `src/apps/desktop/src/api/index.ts:546-558` to include the new optional fields.
- [ ] Run Zig tests (`zig build test --summary all`) — must be green; new tests added for XML escaping.
- [ ] Run `bun run build` and `bunx vitest run` — must be green.

**Files touched:** 2 backend modified (text_replace.zig, llm_history.zig), 1 migration added, 1 frontend API interface updated, 3+ new Zig tests.

### Chunk 5: Jump-to-line in editor

**Goal:** Clicking a line number in the diff opens the file at that line in the existing `GitFileViewer` / `FilePreview`.

Tasks:
- [ ] Extend `useCodeEditor` composable's inject contract to accept `line?: number`.
- [ ] Modify `GitFileViewer.vue` to accept and respect `requestedLine: number | undefined` from the provide.
- [ ] Test the wiring end-to-end: open a chat, run `text_replace`, click the line number, verify the editor opens at that line.
- [ ] Add a regression test for the composable: passing `line: 5` causes the editor to receive `requestedLine: 5`.

**Files touched:** 1 composable modified, 1 component modified, 1+ new test.

### Chunk 6: Wire it all together in `TextReplace.vue` and `ChatView.vue`

**Goal:** The fallback branch in `ChatView.vue:2312-2316` renders the new `DiffView` for *all* tools with `diffview_*` fields (not just the unhandled-tool-name case). The `TextReplace` component uses parser + DiffView + ToolCardHeader end-to-end.

Tasks:
- [ ] In `ChatView.vue`, change line 2312's `<DiffView v-if="msg.diffview_before && msg.diffview_after">` to ALWAYS render the diff view (remove the `v-if`), and let the user toggle it via the `expanded` state.
- [ ] In `TextReplace.vue`, replace the ad-hoc parsing + inline diff with: `const parsed = parseTextReplace(content)`, then `<ToolCardHeader ...>` + `<DiffView ...>`.
- [ ] Add `data-testid="text-replace-card"` and similar for E2E test selectors.
- [ ] Run `bun run build` + `bunx vitest run` — must be green.

**Files touched:** 2 modified.

### Chunk 7 (stretch): Syntax highlighting + inline collapsed preview

**Goal:** Code in the diff is syntax-highlighted. The collapsed mode shows a one-line preview of the change ("+ 12 lines, - 3 lines in `src/foo.zig`").

Tasks:
- [ ] Add `shiki` (or a smaller alternative) as a dependency. Lazy-load it to keep the main bundle size unchanged for users who never open a diff.
- [ ] Detect language from file extension (`.ts` → TypeScript, `.zig` → Zig, `.py` → Python, etc.).
- [ ] Render highlighted code in `DiffView.vue`.
- [ ] Add inline preview mode to `DiffView.vue` for the collapsed state.
- [ ] Add `__tests__` for the syntax highlighting + inline preview.

**Files touched:** 1 component modified, 1 dependency added, 1+ new test.

**This chunk is explicitly stretch.** It is NOT required for chunks 1-6 to merge. Skip if it pushes the timeline.

---

## 9. Success Criteria

After chunks 1-6:

### Code quality
- [ ] `git grep "match\(/\^<" src/apps/desktop/src/components/` shows 0 hits in `tool_outputs/` and `Bash.vue` (all regex replaced by parsers).
- [ ] `git grep -n "isLineChanged" src/apps/desktop/src/components/` shows 0 hits in `tool_outputs/` (replaced by Myers).
- [ ] `src/apps/desktop/src/components/tool_outputs/*.vue` total LOC drops from 3,550 to ~2,400 (≈30% reduction from dedup).
- [ ] All 19 components use `<ToolCardHeader>`.

### Test coverage
- [ ] `bunx vitest run` shows **at least** the previous count + 100 new tests (6 header + 12 Myers + 6 DiffView + 55 parser + 5+ component + a few regression).
- [ ] Each tool_output component has at least one spec file.
- [ ] `bun run build` is type-clean.

### Functionality
- [ ] `text_replace` with an insert in the middle of a file renders a diff that correctly highlights ONLY the changed lines (no false positives on the lines after the insert).
- [ ] The new `DiffView` has a Split / Unified mode toggle; both modes show correct line numbers.
- [ ] Clicking a line number opens the file at that line in the existing editor (`GitFileViewer`).
- [ ] Word-level highlights show inside changed lines.
- [ ] The path with `&` or `<` in the filename renders correctly (no broken XML parsing).

### Backend
- [ ] `text_replace.zig` tests confirm `path`, `old_str`, `new_str` are XML-escaped in both success and error output.
- [ ] The `unified` field is included in the success output XML.
- [ ] `diffview_unified` reaches the frontend via the API.

### Manual smoke test
- [ ] Open chat view, run `text_replace` on a file, click expand → see new diff view with line numbers and mode toggle.
- [ ] Click a line number → file opens at that line.
- [ ] Switch to unified view → see git-style diff with `@@` hunk headers.
- [ ] Switch back to split view → see side-by-side before/after with word-level highlights.

---

## 10. Risk + Mitigation

| Risk | Likelihood | Mitigation |
|---|---|---|
| ToolCardHeader props don't fit all 19 components (some have unique header bits) | Medium | Chunk 1 only migrates the 8 most similar components; chunks 3+ handle the rest. The header has `expandable` / `rightMeta` / `statusVariant` knobs that cover the variants. |
| Myers diff is slow on large files (>10K lines) | Low | The `text_replace` tool typically edits <100 lines per call. The Myers algorithm is O(ND) where D = number of edits; for typical text replacements D < 100, well within budget. Add a synthetic test for a 5,000-line file with 5 edits to confirm. |
| Migration 055 (adding columns to `llm_history`) breaks the existing `saveMessage` SQL | Medium | Mirror the existing migration pattern (see migration 052 / 053). The `saveMessage` function is parameterized; passing the new optional fields is a 1-line change. Run `zig build test` before AND after the migration. |
| The shared `DiffView` performs differently across browsers | Low | Use only stable CSS (`flex`, `overflow-x`, `display: grid`). No `position: sticky` (Safari quirks). Test in Chrome (Vitest's jsdom) and visually verify in a real browser. |
| Refactoring `TextReplace.vue` breaks an existing test | Medium | Chunk 2 keeps the existing test file (`__tests__/TextReplace.spec.ts` if any — currently none) and adds new tests. The old inline diff's visual output is replaced; if any existing test asserts on the inline-diff HTML, it must be updated. The current state: zero TextReplace tests, so this risk is purely theoretical. |
| Word-level Myers on long lines is slow | Low | Cap the per-line word diff at 1KB; longer lines fall back to the line-level highlight only. |

---

## 11. Rollout

1. **Chunks 1-3 merge as a single PR** — they are tightly coupled (parser + header + diff). Splitting them across PRs would leave the codebase in a half-migrated state.
2. **Chunk 4 merges as a separate PR** — backend change, isolated. Requires `zig build test` green before merge.
3. **Chunk 5 merges after chunk 6** — it depends on the new DiffView emitting `jump-to-line`.
4. **Chunk 6 merges immediately after chunks 1-3** — it wires the migrated components into the chat view's rendering pipeline.
5. **Chunk 7 (stretch) is a standalone PR** — only if there's appetite for the polish.

Total estimated effort: **3-4 days** for chunks 1-6 (one engineer, no parallel work), **+1-2 days** for chunk 7.

---

## 12. Open Questions

1. **Should `toolOutputParser.ts` be tree-shakable per-tool, or one file with all parsers?** One file is simpler (~250 lines total); per-tool files are more granular but require more import boilerplate. **Recommendation:** one file.
2. **Should `ToolCardHeader` accept a slot for custom right-side content?** Could be useful for `Bash.vue`'s exit-code badge. **Recommendation:** keep it prop-driven for chunks 1-3; revisit if chunks 7+ need it.
3. **Should the unified diff view default to "split" or "unified"?** Split is the GitHub default; unified is more compact for large diffs. **Recommendation:** Split as the default; remember the user's choice in `localStorage`.
4. **Should the line-number "jump" trigger open-in-editor (vs. just scroll-within-the-diff)?** Open-in-editor is what the user expects (they want to see the file in context). **Recommendation:** Open-in-editor, gated on `filePath && cwd && openInEditor`.