# Plan: Enhance Kanban Description — Rich Editor with Image & File-Path Support

## Goal

Replace the plain `<textarea>` description field in the kanban task detail
dialog with a rich editor component that supports:

1. **Image attachments** — paste (Ctrl/Cmd+V) and paperclip-button upload of
   images, rendered inline in the description.
2. **`@`-trigger file-path references** — typing `@` opens a fuzzy file picker
   (powered by the existing `/api/system/folder?action=list` endpoint) and
   inserts the picked path as `@/relative/path/to/file`.
3. **Rendered preview** — the description is stored as Markdown and rendered
   with the existing `marked` library + `.markdown-content` CSS in both the
   detail dialog (when not editing) and the card preview on the column.

The user can keep writing plain text — markdown support is opt-in. The
existing data column (`workspace_item_tasks.description`, TEXT) is reused;
no backend migration required.

## Current state (verified in source)

| File | Lines | What it does today |
|---|---|---|
| `src/apps/desktop/src/components/kanban/KanbanTaskDetailDialog.vue` | 411-426 | Plain `<textarea>` bound to `description`, `maxlength=5000`, `rows=10` |
| `src/apps/desktop/src/components/workspace/WorkspaceItemTaskCard.vue` | 449-456 | Card preview: `{{ task.description }}` with `line-clamp-2`, no markdown, no images |
| `src/apps/desktop/src/stores/workspaces.ts` | 1652-1707 | `updateTaskDetails` does optimistic update + rollback; calls `api.updateTaskSimple(taskId, patch)` |
| `src/apps/desktop/src/api/index.ts` | 571-592 | `updateTaskSimple(taskId, { name?, description?, ... })` PUTs to `/workspaces/tasks/<taskId>` |
| `src/apps/desktop/src/api/index.ts` | 101-107 | `FolderInfo` + `FolderEntry` already exported; `listFolder(path)` available |
| `src/apps/desktop/src/components/file/FileInput.vue` | full | Reference impl: `@` trigger, image paste/paperclip, FilePreview |
| `src/apps/desktop/src/components/file/FilePreview.vue` | full | Reusable `<FilePreview v-model="previewFiles" max-height="...">` |
| `src/apps/desktop/src/stores/workspaces.ts` | 104-144 | `Task.description?: string` |
| `src/apps/desktop/package.json` | 20 | `"marked": "^18.0.2"` already a dep; used by ChatView + PreviewSidePanel |
| `src/apps/desktop/src/style.css` | 125-281 | `.markdown-content` CSS already present |

## Design decisions

### D1. Storage format: Markdown text, inlined images, plain `@path` references

The existing `description` column is reused. The new value is a Markdown
string. Three content kinds are interleaved:

- **Plain text** — entered by the user, rendered as paragraphs.
- **Images** — pasted or picked via the paperclip button. Stored inline as
  `![filename](data:image/<ext>;base64,<payload>)`. Data URLs are self-contained
  — no upload endpoint, no per-task image table, no image cleanup on delete.
- **`@` file-path references** — typed as `@<query>` and resolved through the
  existing `/api/system/folder?action=list` picker. Inserted as the literal
  string `@/relative/path/to/file.vue` (no markdown wrapping). In render mode,
  these are detected via regex `/@(\/[^\s)\]}>,"'`]+)/g` and rendered as
  clickable chips that resolve against the kanban's `item.path`.

**Why inline data URLs (not an upload endpoint):**
- No backend migration needed (DESCRIPTION_MAX stays at 5000 chars of *base64*
  payload — see D4 for the actual cap strategy).
- Existing `updateTaskSimple` already accepts `description?: string`.
- Self-contained: deleting a task cleans up its images automatically (no
  orphan-file cleanup logic).
- Acceptable for the kanban use case (1-3 screenshots per task).

**Why no markdown wrapping around `@path`s:**
- The user explicitly typed `@/path/file.vue` as a literal — wrapping it in
  `[link](url)` would obscure the intent.
- Detection in render mode uses a stable regex (the path starts with `/` and
  contains no spaces/whitespace from the `[^\s)\]}>,"'`]+` class).
- Clicking the chip opens the file in the editor (`vscode://` URL for
  desktop app, `?path=` deep-link otherwise) — same convention as chat
  messages use.

### D2. New component: `KanbanDescriptionEditor.vue` (edit-mode only)

A self-contained `<textarea>`-wrapper that adds:

- Image paste handler (copied from `FileInput.vue::handlePaste`, scoped to
  our textarea only).
- Paperclip button that triggers a hidden `<input type="file" accept="image/*" multiple>`.
- `@`-trigger file picker (re-uses the same recursion logic + dropdown UI
  from `FileInput.vue::detectAtTrigger` + `loadAllFiles`).
- Inline image-preview row above the textarea (using `<FilePreview>`).
- `v-model` on a Markdown string.

**Props:**

```ts
defineProps<{
  modelValue: string                  // the markdown string
  cwd: string                         // absolute path for the @ picker root
  maxLength?: number                  // default 5000 (preserved from dialog)
  placeholder?: string                // default 'Add a description…'
  testId?: string                     // default 'kanban-description-editor'
}>()
```

**Emits:**

```ts
defineEmits<{
  'update:modelValue': [value: string]
}>()
```

The component owns its own state for `previewFiles` (the `File[]` objects
backing the data URLs) — derived from parsing the modelValue on mount/watch,
so the editor can be re-opened with existing image data without re-uploading.

**Cap strategy:** base64 inflates images by ~33%. A 5000-char cap is too
tight for real screenshots. The plan splits the cap:

- `MAX_DESCRIPTION_LENGTH = 5000` (existing) — applies to the **text portion only**.
- `MAX_IMAGE_BYTES = 4 * 1024 * 1024` (4 MB) — applies to each image; larger
  pasted/picked images are downscaled with a `<canvas>` before being base64-encoded.
- Total description length = text length + sum of data-URL lengths. Enforced
  before each emit (truncate via `MAX_DESCRIPTION_LENGTH`).

The 5000-char cap for text is preserved (no breaking change for users with
existing descriptions). The 4 MB / image cap is new; documented in the
component header.

### D3. New component: `MarkdownDescription.vue` (display-mode only)

A wrapper around the existing `.markdown-content` CSS + `marked.parse` that
adds the `@path` chip rendering on top of standard markdown output.

**Props:**

```ts
defineProps<{
  source: string                      // the markdown string
  cwd?: string                        // optional, used to resolve @path chips to absolute paths
  maxHeight?: string                  // e.g. '4.5rem' for the card preview's line-clamp-2 effect
  testId?: string                     // default 'markdown-description'
}>()
```

**Implementation:**

1. Run `marked.parse(source, { async: false }) as string` to get HTML.
2. POST-process the HTML: for each `@/path/to/file.vue` token (regex on the
   ORIGINAL source string, not the rendered HTML — avoids tripping over
   `<code>` / `<a>` boundaries), inject a `<span class="md-file-chip"
   data-file-path="...">` element. Render-mode uses `display: inline-block`
   with the file-icon glyph + monospace path.
3. The whole rendered HTML is bound via `v-html` inside `<div class="markdown-content md-file-chip-host">`.

**`@path` chip behavior:**

- Click → opens the file in the user's default handler (same as chat-message
  file references; reuse the existing helper).
- Hover → tooltip showing the resolved absolute path.

**Safety:**

- `marked.parse` output is set via `v-html`. The risk of XSS via unescaped
  HTML is mitigated because the description is user-authored (they can
  only inject into their own task) and the existing `ChatView.vue:183` uses
  the same pattern. Document the assumption in the component header.
- Image data URLs are rendered as `<img src="data:image/...">` — `marked`
  emits these verbatim from `![alt](data:...)` syntax; safe.

### D4. Editor ↔ display mode in the detail dialog

`KanbanTaskDetailDialog.vue` toggles between the two:

- Default state when `props.show` becomes true → **display mode** (the
  rendered MarkdownDescription).
- "Edit" button (or click anywhere on the description block) → switches to
  edit mode (the KanbanDescriptionEditor).
- Edit mode shows the textarea + image preview + paperclip + char counter.
- Save commits the editor's modelValue via the existing
  `emit('save', { ..., description: modelValue })` contract.

The dialog already has a dirty-tracking + Save/Cancel flow; we add an
internal `isEditingDescription` ref that flips between modes without
breaking the dirty logic.

### D5. `cwd` plumbing

`KanbanView.vue:378-395` (`handleCreateTaskSave`) and the `props.item` it has
in scope both confirm `WorkspaceItem.path: string` is the absolute path
on disk. The dialog already accepts `task` and `column`; we add a `cwd`
prop:

```ts
defineProps<{
  ...
  cwd?: string  // optional — falls back to '' (file picker shows nothing)
}>()
```

`KanbanView.vue` passes `:cwd="props.item.path ?? ''"` to both the edit and
create dialogs.

For `WorkspaceItemTaskCard.vue` (the card preview), `cwd` comes from the
column-level `item.path` via the same prop chain as today (`workspaceId` +
`itemId` are passed; we extend `KanbanCard.vue` + `KanbanColumn.vue` to
thread `cwd` through).

### D6. Migration / backwards compatibility

- Existing descriptions are plain text. `marked.parse('hello world')`
  renders as `<p>hello world</p>` — visually identical to today's plain
  text (modulo the `markdown-content` padding/margin). Users who don't
  use markdown features see no behavior change.
- `@path` regex matches strings starting with `/`. If a user happened to
  write a sentence like `the /usr/bin/whatever is broken`, the leading
  `@` is required to be present, so no false positives.

## Files to create

| Path | Purpose |
|---|---|
| `src/apps/desktop/src/components/kanban/KanbanDescriptionEditor.vue` | New editor component (D2) |
| `src/apps/desktop/src/components/kanban/MarkdownDescription.vue` | New display component (D3) |
| `src/apps/desktop/src/__tests__/KanbanDescriptionEditor.spec.ts` | Vitest unit tests |
| `src/apps/desktop/src/__tests__/MarkdownDescription.spec.ts` | Vitest unit tests |
| `src/apps/desktop/src/__tests__/KanbanTaskDetailDialogRich.spec.ts` | Dialog integration tests (edit ↔ display toggle, save flow) |

## Files to modify

| Path | Change |
|---|---|
| `src/apps/desktop/src/components/kanban/KanbanTaskDetailDialog.vue` | Replace `<textarea id="kanban-task-detail-description">` block with `<MarkdownDescription>` (display) + `<KanbanDescriptionEditor>` (edit) + edit-mode toggle button. Thread `cwd` prop. Add `isEditingDescription` ref. |
| `src/apps/desktop/src/components/kanban/KanbanView.vue` | Pass `:cwd="props.item.path ?? ''"` to both `<KanbanTaskDetailDialog>` instances. |
| `src/apps/desktop/src/components/workspace/WorkspaceItemTaskCard.vue` | Replace `<p>{{ task.description }}</p>` block (lines 449-456) with `<MarkdownDescription :source="task.description" :cwd="cwd" max-height="3rem" />`. |
| `src/apps/desktop/src/components/kanban/KanbanCard.vue` | Add `cwd` prop (forwarded from column). |
| `src/apps/desktop/src/components/kanban/KanbanColumn.vue` | Add `cwd` prop. Pass through to `<KanbanCard>`. |
| `src/apps/desktop/src/components/kanban/KanbanView.vue` | Pass `:cwd="props.item.path ?? ''"` to `<KanbanColumn>`. |

## Implementation steps

### Chunk 1 — MarkdownDescription component (display-only)

RED-then-GREEN:

1. Write `MarkdownDescription.spec.ts` with:
   - Renders plain text as `<p>` (sanity).
   - Renders `**bold**`, `*italic*`, `# heading`, `- list`, ``` ```code``` ``` correctly.
   - Detects `@/path/to/file.vue` and wraps it in a `.md-file-chip` span.
   - Does NOT match `@somewhere` (no leading slash) or `some /path/without/at` (no `@`).
   - Image data URLs render as `<img src="data:...">` with correct sizing.
   - `max-height` prop applies `style="max-height: ..."` and `overflow: hidden`.
   - Empty / null source renders nothing (no `<p></p>` artifact).
2. Implement `MarkdownDescription.vue`:
   - `<script setup>` imports `marked`, parses via `marked.parse(source, { async: false }) as string`.
   - Computes `html` ref; updates via `watch(() => props.source, ...)` (also `immediate: true`).
   - Computes `displayHtml` that walks the original source for `@/...` tokens and
     inserts `<span class="md-file-chip" data-file-path="...">📄 /path/...</span>`
     at the right position. (Implementation: regex-replace in the HTML before
     `v-html` set, preserving the path's relative order. Simpler approach:
     do the replacement on the SOURCE string before parsing — `marked` passes
     unknown tokens through, but we need the original `@` preserved. Use the
     HTML post-process approach: find `>/@/path/<` sequences in the HTML.)
   - Template: `<div class="markdown-content" :style="maxHeight ? { maxHeight, overflow: 'hidden' } : {}" v-html="displayHtml"></div>`.
3. Add `.md-file-chip` styles to `style.css` (inline-block, mono font, subtle
   background, hover state for the tooltip).

Verification: `bunx vitest run MarkdownDescription` (all green).

### Chunk 2 — KanbanDescriptionEditor component

RED-then-GREEN:

1. Write `KanbanDescriptionEditor.spec.ts` with:
   - `v-model` two-way binding works (typing into the textarea emits `update:modelValue`).
   - `@`-trigger opens the file picker dropdown; `cwd` prop is passed to the picker.
   - Picking a file inserts `@/relative/path` at the cursor.
   - Pasting an image (mock `ClipboardEvent` with image file) inserts a
     data URL into the textarea and renders the preview row.
   - Clicking the paperclip button triggers the hidden file input (verified
     via `trigger('click')` on the hidden input — uses jsdom file APIs).
   - Removing an image preview removes the corresponding data URL from the textarea.
   - Char counter shows `textLength / 5000`.
   - Test id is applied to the textarea + paperclip + picker dropdown.
2. Implement `KanbanDescriptionEditor.vue`:
   - Import `FilePreview` (existing) + the picker logic (factor out from
     `FileInput.vue` if it's reusable, OR copy the minimal subset).
   - On mount: parse existing modelValue for `![...](data:image/...)` blocks,
     build `previewFiles` array (data URL → `File` via fetch+blob).
   - On preview removal: strip the corresponding `![...](data:...)` from
     the textarea content; emit `update:modelValue`.
   - On paste: handle image-paste exactly like `FileInput.vue::handlePaste`,
     but scoped to the component's textarea (no document-level listener).
   - Image data URL downscaling: use `<canvas>` if image > 4MB; otherwise
     encode as-is via `FileReader.readAsDataURL`.
   - On `@`-trigger detection (debounced 150ms like FileInput): show dropdown
     using `loadAllFiles(cwd)` (re-use the recursive scan logic). Pick inserts
     `@/path` at cursor.
3. Register in `test_runner.zig` if Zig tests are involved (probably not —
   these are Vue/TS tests, run via `bunx vitest`).

Verification: `bunx vitest run KanbanDescriptionEditor` (all green).

### Chunk 3 — Wire into KanbanTaskDetailDialog

1. Write `KanbanTaskDetailDialogRich.spec.ts` with:
   - Renders `<MarkdownDescription>` by default (display mode).
   - Clicking the "Edit description" button swaps to `<KanbanDescriptionEditor>`.
   - Save in edit mode emits `save` with the new description string.
   - Cancel reverts to the original description.
   - In create mode, the description starts empty; edit-mode button isn't
     rendered (the form is already an editor).
2. Implement `KanbanTaskDetailDialog.vue` changes:
   - Add `cwd?: string` prop.
   - Add `isEditingDescription = ref(false)`.
   - Replace the textarea block (lines 400-427) with:
     ```vue
     <div v-if="!isEditingDescription && description">
       <MarkdownDescription :source="description" :cwd="cwd" test-id="kanban-task-detail-description-display" />
       <button @click="isEditingDescription = true" data-testid="kanban-task-detail-description-edit">Edit description</button>
     </div>
     <KanbanDescriptionEditor
       v-else
       v-model="description"
       :cwd="cwd ?? ''"
       :test-id="isCreateMode ? 'kanban-task-detail-create-description' : 'kanban-task-detail-description'"
     />
     ```
   - The dirty-tracking logic stays unchanged (it watches `description`).
3. Update `KanbanView.vue` to pass `cwd` to the dialog:
   ```vue
   <KanbanTaskDetailDialog
     :cwd="props.item.path ?? ''"
     ...
   />
   ```

Verification: `bunx vitest run KanbanTaskDetailDialog` (existing tests stay
green + new tests pass).

### Chunk 4 — Card preview rendering

1. Update `WorkspaceItemTaskCard.vue` lines 449-456:
   ```vue
   <MarkdownDescription
     v-if="task.description"
     :source="task.description"
     :cwd="cwd ?? ''"
     max-height="3rem"
     test-id="task-description"
   />
   ```
2. Add `cwd?: string` prop to `WorkspaceItemTaskCard`, `KanbanCard`, and `KanbanColumn`.
3. Pass `cwd` from `KanbanView` → `KanbanColumn` → `KanbanCard` → `WorkspaceItemTaskCard`.

Verification: manual smoke test — open a task, add a description with an
image and a `@path`, save, then look at the kanban column. The card
preview should show the rendered markdown (or the first 2 lines of it)
with the image and `@path` chip visible.

### Chunk 5 — Full integration tests + docs

1. Add E2E-style test (jsdom) that:
   - Mounts `KanbanView` with a stubbed kanban item containing one task.
   - Opens the detail dialog.
   - Pastes a base64 image into the description editor (mock `ClipboardEvent`).
   - Types `@` + picks a file from the dropdown.
   - Saves the dialog.
   - Asserts the API was called with `PUT /api/workspaces/tasks/<id>` and
     the body contains the expected `description` string.
2. Update `docs/frontend/kanban-description-editor.md` (new file) with
   the data format, the `cwd` requirement, the cap (text vs image), and
   screenshots.

## Pitfalls

| Pitfall | Mitigation |
|---|---|
| `marked.parse` runs sync; large descriptions (>10k chars) can block the main thread for tens of ms. | Cap at 5000 chars text + 4MB images. For very large descriptions, show a "click to expand" disclosure (out of scope for v1). |
| Data URLs in HTML returned by `marked` — `marked` preserves `data:image/...` URLs in `![alt](url)` syntax unchanged. | Verified in `marked@18` docs. If a future regression breaks this, fall back to a custom `marked.use({ renderer: { image: ... } })` that re-emits `<img src="...">`. |
| `v-html` injection — description is user-authored, so self-XSS only. | Same trust model as ChatView. Document in component header. No CSP change. |
| `@path` regex matches substrings inside other tokens (e.g., backtick-wrapped paths). | The regex excludes whitespace and markdown-delimiter characters. Document known limitation; out of scope for v1 to handle edge cases like `[\`@/path\`](url)`. |
| `cwd` is `null` for legacy kanbans created before the `path` field existed. | File picker shows empty list, `@`-trigger is a no-op. Add a small "Set workspace path" hint in the dropdown (matches existing behavior for legacy kanbans). |
| 5000-char limit is too tight for descriptions with images. | Cap the **text** portion at 5000; allow base64 payload beyond it (DB TEXT column accepts multi-MB). Document the asymmetry. |
| Existing 8+ test files construct `Task` literals without `cwd` plumbing. | All new props are optional. Existing tests pass `:cwd="undefined"` implicitly via the default. |
| Lazy analysis (Zig) doesn't apply here (Vue/TS), but `bun run build` (vue-tsc) catches type errors `bunx vitest run` misses. | Run both per `nalar-frontend-patterns.md`. |

## Verification

```bash
cd src/apps/desktop

# Type-check + bundle (catches vue-tsc errors)
timeout 120 bun run build 2>&1 | tail -n 20

# Unit tests (all new + existing)
timeout 120 bunx vitest run MarkdownDescription KanbanDescriptionEditor KanbanTaskDetailDialog KanbanCard KanbanColumn 2>&1 | tail -n 30

# Full unit test suite (regression check)
timeout 120 bunx vitest run 2>&1 | tail -n 10
```

Manual smoke test (per `project-working-patterns.md::verification-before-completion`):

1. Open the kanban view in the dev build.
2. Click any task card → detail dialog opens.
3. Description shows in rendered markdown form (display mode).
4. Click "Edit description" → editor mode opens with textarea + paperclip + char counter.
5. Paste an image (screenshot from clipboard) → preview thumbnail appears, markdown
   `![...](data:image/png;base64,...)` is in the textarea.
6. Type `@` → file picker dropdown opens (scoped to the kanban's `item.path`).
7. Type `com` → fuzzy filters to files containing `com` (e.g.
   `components/file/FileInput.vue`).
8. Press Enter → `@/src/apps/desktop/src/components/file/FileInput.vue` is
   inserted at the cursor.
9. Click Save → dialog closes, card preview shows the image + the file chip.
10. Reload the page → description persists, still rendered.

## Out of scope (future work)

- **Image resizing/cropping UI** — v1 only auto-downscales large pastes.
- **Markdown editor with toolbar** (bold/italic buttons) — v1 only supports
  raw markdown + image paste + @paths. A toolbar can be added later.
- **`@path` resolution to absolute paths in render mode** — v1 stores the
  user-typed `@/relative/path` literally. A future iteration can resolve
  to absolute via the kanban's `cwd` and show a tooltip.
- **Description formatting per-task-type** — routines and memory tasks
  might want different default templates. Out of scope.
- **Cross-window drag-and-drop image attachment** — desktop-only; out of
  scope for the webview build.

## Related references

- `src/apps/desktop/src/components/file/FileInput.vue` — reference impl for
  `@`-trigger, image paste, paperclip. Reuse the picker + paste logic;
  factor out the image-paste handler into `src/apps/desktop/src/helpers/`
  if it's reused in a third place.
- `src/apps/desktop/src/style.css::.markdown-content` — existing markdown
  CSS to reuse (don't duplicate).
- `src/apps/desktop/src/components/views/ChatView.vue:183` —
  `marked.parse(cleanContent, { async: false }) as string` — the canonical
  usage pattern.
- `src/apps/desktop/src/__tests__/FileInput.spec.ts` — existing test
  conventions for the FileInput patterns we're re-using.
- `src/apps/desktop/src/__tests__/workspacesStoreTaskUpdate.spec.ts` —
  existing test for `updateTaskDetails`; new tests should layer on top.
- Memory: `nalar-frontend-patterns.md::bun run build is the type-check` —
  always run BOTH `bun run build` AND `bunx vitest run`.
