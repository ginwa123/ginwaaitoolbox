# Code Editor Viewer — blank body fix + diff-review rendering pattern

**User report (kanban `task_1790594549955_1`):** "refactor and fixing code editor viewer — when i click code editor there is not code. we need to follow pattern code git diff review."
Screenshot: `?sidebar=explorer&view=code-editor` on `AGENTS.md` — the header (📄 name, `markdown` pill, footer path) renders, the body is empty.

**Root cause (reproduced in the shipped bundle):** `CodeEditor.vue` lazy-loaded monaco through `await import(/* @vite-ignore */ 'monaco-editor')`. The `@vite-ignore` marker tells Vite not to rewrite the specifier, so the built chunk carries a **bare module specifier**:

```
dist/assets/index-*.js:  let e = await nu(() => import(`monaco-editor`), [])
```

A browser cannot resolve that → `onMounted` rejected with
`TypeError: Failed to resolve module specifier "monaco-editor"` → the editor instance was never created, so the header painted and the body stayed blank. Captured live by the new production-mode UI test against unmodified `main`.

**Why nothing caught it:** the jsdom spec only grepped the *source* for the import shape; `vitest.config.ts` aliases `monaco-editor` to a stub and runs with `dangerouslyIgnoreUnhandledErrors: true`; and the Vite **dev** server resolves bare specifiers itself, so the dev-mode UI harness cannot see the class of bug either. Only the built artifact fails.

**Tech stack:** Vue 3 (`src/apps/desktop/src/components/views/CodeEditor.vue`, `AppLayout.vue`, `composables/useCodeEditorSession.ts`), vitest spec, Playwright production-mode functional test (`tests/functional_ui/code_editor_viewer_ui_test.py`).

## Implementation

`CodeEditor.vue` is now a **read-only viewer built on the git-diff-review pattern** — the same rendering the user already reads in the diff panels:

- one table row per line, `data-line` / `data-testid="code-line"` selected so a row can be addressed;
- sticky line-number gutter (`.code-gutter`, `position: sticky; left: 0`), same as `SidebarDiffView.vue` / `DiffView.vue`;
- soft-wrap always on (`white-space: pre-wrap; word-break: break-word`) — the same call the diff views made when they dropped their Wrap toggle;
- content painted by the repo's zero-dependency tokenizer (`helpers/codeHighlight`: `detectLanguage` + `highlightLine`) into `tok-*` spans with the diff cards' exact palette, so no runtime module resolution is involved at all;
- `?line=N` / the diff review's "open at this line" marks the target row (`data-target="true"`) and scrolls it to the middle of the viewport — the native replacement for monaco's `revealLineInCenter`;
- header keeps the file name + language + a line count; footer keeps the shared `displayPathFor` path binding.

The dead save path is removed end-to-end (`CodeEditor.vue` save button/readonly toggle, `AppLayout.handleCodeEditorSave` + its two debug `console.log`s and the unused `_handleCodeEditorFileClick`, `useCodeEditorSession.save()` + its `writeFile` dep, and the now-uncalled `api.writeFileContent`). It could never work: the backend registers only `GET /api/system/folder` (`src/main.zig:675`) — there is no write route, and the handler's `action=write` branch reads the file like `action=read`. Making it a viewer is therefore not a capability loss, and the viewer is the surface the sidebar button and diff-review "Open" actually promise ("Open file in code browser").

## Verification

- [x] **New production-mode UI test (3 tests) — the bug's own level.** `tests/functional_ui/code_editor_viewer_ui_test.py` builds the real bundle once (`pnpm run build-only`, ~2s) and boots nalar with `--static-dir dist`, so the production bundle and `/api` share one origin. Asserted:
  - deep link → the file's text is on screen, one numbered row per line, `tok-*` spans present, URL carries `view=code-editor`;
  - reload → same content again (no silent blank);
  - `?line=3` → exactly the target row marked.
  **Before the fix:** `FAILED` with `TypeError: Failed to resolve module specifier 'monaco-editor'` at `assets/index-CryMsrLn.js:231` — the reported symptom, reproduced. **After:** 3 passed in 4.5s.
- [x] Bundle contract: `import(\`monaco-editor\`)` count in the built chunk **2 → 1** (the remaining one is `PropertiesPanel.vue`, see Out of scope); entry chunk 1 767 347 → 1 764 123 bytes, **no** monaco code in it.
- [x] `CodeEditor.spec.ts` (12 tests, replaces the deleted grep-only `CodeEditor.lazy-monaco.spec.ts`): rows/numbering, verbatim text, no phantom trailing line, token classes, markdown stays token-free, `line` target marking, empty state, header language/line count, `close` emit — plus a source contract that the `monaco-editor` specifier and `@vite-ignore` can never come back.
- [x] Full frontend unit suite: **4130 passed / 27 failed — the identical 27 pre-existing failures on `main`** (ChatView.center*, renderResponse, FilePickerDialog.windows, workspacesStore*, …, verified by running both checkouts and diffing the failure lists: zero new regressions).
- [x] `pnpm run type-check` (vue-tsc) clean; `oxlint` + `eslint` clean on every touched file (`api/index.ts` prettier drift is pre-existing on `main`).

## Out of scope (follow-ups worth their own card)

1. **`PropertiesPanel.vue`** carries the same `@vite-ignore` monaco import, so its design-HTML editor falls back to the textarea placeholder ("TODO: install monaco-editor…") in production. Unlike the code viewer it degrades gracefully, and the fix is a bundle-size decision (monaco as a lazy chunk vs. another zero-dep editor), so it is deliberately left alone.
2. **The code-editor overlay is `absolute inset-0 z-10` over the whole `<main>`**, and `currentView` returns `code-editor`, which unmounts `ChatView` — that is why the right sidebar disappears when a file is opened from it (kanban `task_1790229937829_0`, still on hold). Out of scope here: fixing it means rendering the viewer inside ChatView's center column so the sidebar survives.
3. **A fresh chat has no sidebar cwd**: `GET /api/llm/session/:id/messages` returns `cwd: null` while the session has no messages, and `ChatView.effectiveCwd` reads only that endpoint, so the Explorer shows "Pass a cwd to browse files" until the first message. That is why the functional test drives the reader through the deep link (`?view=code-editor&file=…&cwd=…`) rather than the Explorer click; the click path itself is unchanged and covered by `AppLayout.urlPersist.spec.ts` + `useCodeEditorSession.spec.ts`.
