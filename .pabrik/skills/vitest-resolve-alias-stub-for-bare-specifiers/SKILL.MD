---
name: vitest-resolve-alias-stub-for-bare-specifiers
description: When a Vue component transitively imports a heavy/optional npm package (e.g. monaco-editor), `vi.mock` alone cannot satisfy the bare specifier — vite's import-analysis runs at file-transform time, BEFORE the module loader, so a missing/unresolvable import crashes the test suite. The fix is a `resolve.alias` in `vitest.config.ts` pointing the bare specifier to a tiny stub file. Use this when adding tests for a component that pulls in heavy transitive deps (Monaco, Three.js, Mapbox, Chart.js, etc.) and seeing "Failed to resolve import" errors from vite:import-analysis.
tags: [frontend, vitest, vite, fix, environment]
---

## When to Use

You're adding a unit test that mounts a Vue component (or imports any
module) that *transitively* imports a heavy / optional / not-installed
npm package, and the test suite fails to even load with:

```
Failed to resolve import "monaco-editor" from "src/components/CodeEditor.vue"
   Plugin: vite:import-analysis
```

The error appears at the test-file's transform step, before any test
runs. Adding `vi.mock('monaco-editor', () => ({}))` to the test file
does NOT fix it.

## Context

The plugin chain in a `vite + vitest` setup runs in this order:

1. **`vite:import-analysis`** — runs at file-transform time. Resolves
   bare specifiers (`import x from 'monaco-editor'`) via the resolver.
   If resolution fails, the test file fails to load.
2. **Module loader** — only runs *after* a resolved import reaches it.
   This is where `vi.mock(...)` can swap an already-resolved module
   for a stub.

`vi.mock` is a loader-level tool. It cannot help with a bare specifier
that step (1) has already failed on.

## Procedure

1. **Create a tiny stub file** for the offending package. The contents
   don't matter — the real package is stubbed at mount-time anyway.
   ```ts
   // src/__tests__/stubs/monaco-editor.ts
   export {}
   ```

2. **Add a `resolve.alias` in `vitest.config.ts`** (test-only — do NOT
   touch the production `vite.config.ts`):
   ```ts
   import { fileURLToPath } from 'node:url'
   import { mergeConfig, defineConfig } from 'vitest/config'
   import viteConfig from './vite.config'

   export default mergeConfig(
     viteConfig,
     defineConfig({
       resolve: {
         alias: {
           'monaco-editor': fileURLToPath(
             new URL('./src/__tests__/stubs/monaco-editor.ts', import.meta.url),
           ),
         },
       },
       test: { /* ... */ },
     }),
   )
   ```

3. **Stub the component at mount-time** so the import is exercised but
   the package's runtime is never used:
   ```ts
   mount(ParentComponent, {
     global: { stubs: { CodeEditor: true } },  // or whatever the leaf is
   })
   ```

## Pitfalls

- **`vi.mock` alone is never enough for bare specifiers.** It cannot
  intercept a file that failed to load. Always pair it with the alias
  or use the alias alone.
- **Alias `monaco-editor` to a *file*, not a directory.** `fileURLToPath(new URL('./stub.ts', ...))` works; pointing at `./stubs/` does not.
- **Don't pollute `vite.config.ts`.** The alias belongs in
  `vitest.config.ts` only — production builds should still try to
  resolve the real package.
- **Stub exports matter for `import * as ns from 'pkg'`.** If the
  importing file does `import * as monaco from 'monaco-editor'`, the
  stub must allow namespace imports. An empty `export {}` works for
  most cases; if the consumer uses `monaco.editor.create(...)` at
  module top level, the stub's namespace will be empty and the call
  will throw. Stub the *component* at mount-time to avoid executing
  the top-level body of the importing file.
- **If multiple tests need different stubs**, use `vi.mock` ON TOP OF
  the alias. The alias satisfies import-analysis; `vi.mock` then
  overrides the stub for the modules that do get evaluated.

## Verification

After applying the fix:
- The test file should load without `Failed to resolve import` errors.
- `bunx vitest run` should report all test files passing.
- A test that uses the component should run the component's
  onMounted/setup but not the stubbed child's setup (because the
  component is stubbed at mount-time, not the package).
