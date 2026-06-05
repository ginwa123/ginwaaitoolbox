/**
 * Stub for the `monaco-editor` package. The real package is not installed
 * in the test environment, but it is imported (transitively) by
 * `CodeEditor.vue` which is itself a transitive import of `AppLayout.vue`.
 *
 * `vi.mock('monaco-editor', …)` runs at the module loader level, which
 * is *after* vite's `import-analysis` plugin. So the import must resolve
 * via vite's resolver first — we alias `monaco-editor` to this stub in
 * `vitest.config.ts`.
 *
 * CodeEditor is stubbed at mount-time (it never actually renders in
 * these tests), so the stub's contents do not matter — the default
 * `export {}` is enough to satisfy both `import * as monaco from …` and
 * any named imports a future maintainer might add.
 */
export {}
