# desktop — Pabrik web app

The Vue 3 + TypeScript + Pinia single-page app for Pabrik. It talks to a running
`pabrik` backend over REST + SSE (`/api/*`); the Vite dev server proxies `/api`
and the terminal websocket to `http://localhost:8081` (override with
`VITE_API_PROXY_TARGET`).

See the [root README](../../../README.md) for the full project overview.

## Project Setup

pnpm 11 is the canonical package manager for this workspace — `pnpm-lock.yaml`
lives here and there is no `package-lock.json` (npm and Bun were dropped from
the webapp build on 2026-08-28). The repo-root `.npmrc` sets
`node-linker=hoisted`.

```sh
pnpm install
```

## Scripts

```sh
pnpm dev            # Vite dev server with HMR (proxies /api → :8081)
pnpm run build      # type-check (vue-tsc) + vite build → dist/
pnpm run build-only # vite build only, no type-check
pnpm run type-check # vue-tsc --build
pnpm run test       # vitest --run (single pass)
pnpm run test:unit  # vitest (watch mode)
pnpm run lint       # oxlint --fix + eslint --fix
pnpm run format     # prettier --write src/
```

`dist/` is what `zig build pabrik-desktop` embeds into the native shell, and
what `pabrik --static-dir src/apps/desktop/dist` serves from the backend.

## Layout

```
src/
├── components/
│   ├── views/        # the main screens (ChatView, DesignView, …)
│   ├── tool_outputs/ # per-tool rendering cards
│   ├── dialogs/ · kanban/ · design/ · shell/ · git/ …
├── stores/           # Pinia stores
├── composables/ · helpers/ · api/
├── sync/             # Effect-TS offline-sync slice (see docs/effect-migration.md)
└── __tests__/        # 313 spec files (component specs also sit next to their subject)
```

Vitest runs in `jsdom` with a Monaco stub and a 15 s timeout; `e2e/**` is
excluded (Playwright lives in `tests/functional_ui/` at the repo root).

## Recommended IDE Setup

[VS Code](https://code.visualstudio.com/) + [Vue (Official)](https://marketplace.visualstudio.com/items?itemName=Vue.volar) (and disable Vetur).

TypeScript cannot handle type information for `.vue` imports by default, so we
replace the `tsc` CLI with `vue-tsc` for type checking. In editors, we need
[Volar](https://marketplace.visualstudio.com/items?itemName=Vue.volar) to make
the TypeScript language service aware of `.vue` types.

## Recommended Browser Setup

- Chromium-based browsers (Chrome, Edge, Brave, etc.):
  - [Vue.js devtools](https://chromewebstore.google.com/detail/vuejs-devtools/nhdogjmejiglipccpnnnanhbledajbpd)
  - [Turn on Custom Object Formatter in Chrome DevTools](http://bit.ly/object-formatters)
- Firefox:
  - [Vue.js devtools](https://addons.mozilla.org/en-US/firefox/addon/vue-js-devtools/)
  - [Turn on Custom Object Formatter in Firefox DevTools](https://fxdx.dev/firefox-devtools-custom-object-formatters/)

## Customize configuration

See [Vite Configuration Reference](https://vite.dev/config/) and
`vite.config.ts`. Note that Monaco is deliberately excluded from
`optimizeDeps.include` — it is loaded via a dynamic `import()` in
`CodeEditor.vue` because pre-bundling it pinned a CPU core at 80–100 %.
