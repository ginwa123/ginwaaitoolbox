---
name: vue-tsc-build-emits-js-files
description: "vue-tsc --build in this project emits .js files alongside .ts source files (when tsconfig doesn't set noEmit:true). These clutter git status as untracked. Pattern: delete them before committing."
---
---
name: vue-tsc-build-emits-js-files
description: vue-tsc --build in this project emits .js files alongside .ts source files (when tsconfig doesn't set noEmit:true). These clutter git status as untracked. Pattern: delete them before committing.
tags: [environment, fix]
---

## When to Use

After running `npx vue-tsc --build` (or `bun run type-check`) in the
`src/apps/desktop/` directory of this project, BEFORE running `git
status` or committing. If `git status` shows dozens of untracked
`*.js` files in `src/apps/desktop/src/__tests__/` and `src/apps/desktop/src/*.js`, this pattern applies.

## Symptom

```
On branch worktree/feat-show-preview-bubble-click
Untracked files:
  src/apps/desktop/src/App.vue.js
  src/apps/desktop/src/__tests__/AddItemDialog.spec.js
  src/apps/desktop/src/__tests__/AddKanbanDialog.spec.js
  src/apps/desktop/src/__tests__/AddMemoryDialog.spec.js
  ...
  (200+ .js files)
```

These appear after a fresh `npx vue-tsc --build` invocation. The
build was supposed to be type-check only.

## Root Cause

`tsconfig.node.json` has `noEmit: true` (correct for the vite.config
type-check). But `tsconfig.app.json` and `tsconfig.vitest.json`
(extended via `@vue/tsconfig/tsconfig.dom.json`) inherit a default
that allows emit. So `vue-tsc --build` transpiles every TS file to JS
sibling files when it runs.

Verified at `src/apps/desktop/tsconfig.app.json:5-17`:
- Extends `@vue/tsconfig/tsconfig.dom.json` (no `noEmit`).
- Includes `src/**/*` (every .ts/.vue).
- Does NOT set `"noEmit": true`.

`tsconfig.vitest.json:6-7`:
- Includes `src/**/__tests__/*`.
- Does NOT set `"noEmit": true`.

## Fix

After any `vue-tsc --build` run that produces these files, clean
them up before `git status` / `git add` / `git commit`:

```bash
find .worktrees/<branch>/src/apps/desktop -name "*.js" \
  -path "*/src/*" -not -path "*/node_modules/*" \
  -exec rm {} \;
```

One-liner alternative (in the worktree cwd):
```bash
find src -name "*.js" -not -path "*/node_modules/*" -delete
```

Then verify:
```bash
git status
# should show no untracked .js files
```

## Why They Aren't in .gitignore

The repo's `.gitignore` does NOT ignore these `.js` files at the
source level (only `dist/` is ignored). They're correctly
untracked-but-not-staged — they appear in `git status` as
untracked. Adding `*.js` to `.gitignore` would also ignore legitimate
JS files at the source level (none currently, but defensive).

The cleanest long-term fix is to add `"noEmit": true` to
`tsconfig.app.json` and `tsconfig.vitest.json`. But this is a
project-wide change touching the build infrastructure and was
deliberately NOT included in any of the feature branches I've worked
on — it's a separate infrastructure PR.

## How to verify after the fix

1. `find src/apps/desktop -name "*.js" -not -path "*/node_modules/*"` → empty.
2. `git status` → no untracked .js files.
3. `bunx vitest run` still passes (the emit is purely cosmetic — it
   doesn't affect Vitest's runtime, which uses esbuild's transform).

## When this bites

- After any `npx vue-tsc --build` or `bun run type-check` in a fresh
  worktree where `node_modules/` is fresh-installed.
- After changing the `tsconfig.*.json` files (the emit config might
  shift).
- During code review: a reviewer running `git status` will see 200+
  untracked files and may panic-think the dev committed vendor JS.
  They haven't — it's vue-tsc emit debris.

## Concrete precedent in this repo

Fix applied on `worktree/feat-show-preview-bubble-click` after the
bubble-click feature's type-check. The 221 generated `.js` files
were cleaned up before commit `28ef1172`.
