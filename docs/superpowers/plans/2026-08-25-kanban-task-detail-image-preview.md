# Kanban task detail — persisted-image gallery preview

Date: 2026-08-25
Branch: `worktree/kanban-task-detail-image-preview`
PR: https://github.com/ginwa123/ginwaaitoolbox/pull/339
Kanban: task_1787663308829_1

## Symptom (reported by user)

"fix i cannot preview attachment images — the case occuer when task already created"

Screenshot shows the Kanban Task details dialog open on an existing task with a small thumbnail visible at the top of the description area. User could see the thumbnail but could not open a full-size preview.

## Root cause

`KanbanTaskDetailDialog.vue:1296` (pre-fix) renders the persisted-image gallery:

```vue
<img
  v-for="(url, idx) in imageUrls"
  :key="idx"
  :src="url"
  :alt="`Task image ${idx + 1}`"
  class="w-24 h-24 object-cover rounded border"
  style="border-color: var(--color-border);"
  :data-testid="`kanban-task-detail-image-${idx}`"
/>
```

**No click handler.** The `imageUrls` computed (`props.task?.imageUrls ?? []`) loads correctly via the store's `normalizeTaskImageUrlsInPlace` (snake→camel bridge — see `workspaces.ts:330`). The thumbnails render. But there's no way to preview them at full size.

The create-mode flow does NOT have this problem because the editor stages pasted images in `previewFiles` (File + blob: URL) and renders through `FilePreview.vue`, which has a working `Teleport`-based click-to-popup modal (`FilePreview.vue:68`). Persisted `data:` URLs don't fit `FilePreview` (it expects `File` objects + blob: URLs), so reusing it wasn't an option.

## Fix

Surgical patch to `KanbanTaskDetailDialog.vue`:

1. **Script** (next to existing `previewFilePath` for the file-chip modal):
   - New `imagePopupUrl = ref<string|null>(null)` — holds the currently-popped src.
   - `openImagePopup(url)` / `closeImagePopup()` handlers.
   - `handleImagePopupKeydown(e)` — closes on Escape; attached on `document` in `onMounted`, removed in `onBeforeUnmount`.
   - Import `onBeforeUnmount` (already had `onMounted`).

2. **Template** (gallery thumb):
   - Added `cursor-pointer transition-opacity hover:opacity-80` and `@click="openImagePopup(url)"`.

3. **Template** (root, after the existing `<FilePreviewModal>`):
   ```vue
   <Teleport to="body">
     <div
       v-if="imagePopupUrl"
       class="fixed inset-0 z-[10000] flex items-center justify-center bg-black/85 p-5"
       data-testid="kanban-task-detail-image-popup-overlay"
       @click="closeImagePopup"
     >
       <button type="button" … @click.stop="closeImagePopup">×</button>
       <img :src="imagePopupUrl" alt="…" data-testid="kanban-task-detail-image-popup-img" @click.stop />
     </div>
   </Teleport>
   ```

   `Teleport to="body"` ensures the overlay escapes the dialog's `overflow:hidden` ancestors and renders full-screen. `z-index: 10000` sits above the dialog's `z-9999`.

## Tests (TDD, 7 new in `KanbanTaskDetailDialog.imagePreview.spec.ts`)

1. Renders one thumbnail per persisted `imageUrls` entry in edit mode.
2. Does NOT render the gallery when `imageUrls` is empty.
3. Clicking a thumbnail opens a Teleport overlay with the full-size image.
4. Pressing Escape closes the overlay.
5. Clicking the overlay backdrop closes the overlay.
6. Clicking a second thumbnail swaps the popup image (only one overlay in DOM).
7. Closing then reopening the overlay works (no stale state).

## Verification

- `vitest run` — 281 files / 2650 pass / 8 pre-existing fetch-stub noise (AppLayout.taskClickUrlOverwrite, unrelated).
- `vue-tsc --build --noEmit` — clean.
- `vite build` — clean (2.75 s).
- `eslint` on the 2 changed files — clean.
- Full KanbanTaskDetailDialog suite — 8 files / 111 tests pass (no regression).

## Files

- EDIT: `src/apps/desktop/src/components/kanban/KanbanTaskDetailDialog.vue` (+46 / −1)
- NEW: `src/apps/desktop/src/__tests__/KanbanTaskDetailDialog.imagePreview.spec.ts` (239 lines)

## Gotchas

- `Task` interface uses `is_auto_retry_until_stop: '0'|'1'`, NOT `isUnattended` (vue-tsc caught this on first pass).
- Selector prefix `kanban-task-detail-image-` matches the gallery wrapper, the popup overlay, and the popup img — the test uses `:not([data-testid*="popup"]):not([data-testid$="gallery"])` to scope to thumbnails only.
- `vue-tsc --build` (without `noEmit:true`) emits .js files alongside .ts — clean these before committing (per `.nalar/skills/vue-tsc-build-emits-js-files`).
- `vitest.config.ts` doesn't pick up worktree's `node_modules` automatically; symlink the main repo's `node_modules` into the worktree (`ln -s /home/ginwa/ginwaaitoolbox/src/apps/desktop/node_modules .worktrees/.../src/apps/desktop/node_modules`) before running vitest.

## Related work

- PR #322 (commit 130ad9bc): snake→camel bridge for `imageUrls` in the store normalizer.
- PR #327 (kanban-task-detail-single-fetch, commit on main): single-task GET endpoint + frontend `api.getTask` + `refreshTask` rewrite that plucks one task from the cache.
- Both pre-requisites for the user to *see* thumbnails on edit mode; this PR adds the *interactivity* (click → preview) that was always missing.