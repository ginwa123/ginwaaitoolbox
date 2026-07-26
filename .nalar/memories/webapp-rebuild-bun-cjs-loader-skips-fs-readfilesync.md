# `zig build webapp-rebuild` fails in bun-only environments — vue-tsc patching bypassed

## Symptom

`zig build webapp-rebuild` (which runs `bun run build` in `src/apps/desktop`,
which in turn runs `vue-tsc --build` + `vite build` in parallel via `run-p`)
exits non-zero with hundreds of `TS2307: Cannot find module '.../*.vue'`
errors from `vue-tsc --build`.

The same `bun run build` succeeds for `build-only` (vite) but fails for
`type-check` (vue-tsc). `zig build webapp-rebuild` propagates the failure.

`vue-tsc --listFiles` shows only TypeScript lib files (lib.es5.d.ts,
lib.dom.d.ts, …) and a small handful of `.ts` source files. **No `.vue`
files appear in the file list at all** — the compiler never even tries
to load them.

## Root cause

`vue-tsc` (and its `@volar/typescript` dependency) uses a regex-patching
strategy to register `.vue` as a recognized TypeScript source-file
extension:

1. `vue-tsc` resolves `typescript/lib/tsc.js` (which is a small shim in
   TS 5.7+ / 6.x / 7.x — `module.exports = require("./_tsc.js");`).
2. `@volar/typescript` patches `fs.readFileSync` so that the read of
   `tsc.js` returns a *transformed* string with `.vue` spliced into
   `supportedTSExtensions` / `supportedJSExtensions` / `allSupportedExtensions`,
   plus `function createProgram` wrapped with a proxy that injects the
   Vue language plugin.
3. The patched string is then `require()`'d and executed as TS.

This whole mechanism relies on **Node.js's CJS loader routing file
reads through `fs.readFileSync`**. **Bun's native CJS loader does NOT**
— Bun uses its own module loader that reads compiled modules internally
and bypasses `fs.readFileSync`. Verified by patching
`fs.readFileSync` and watching a target file's read go un-intercepted
while still seeing `require()` succeed.

Result: vue-tsc silently runs with un-patched TS internals. No `.vue`
is added to the supported-extensions list, no language plugin is
created, every `import './Foo.vue'` fails TS2307. There is no error
from Bun — the patching just isn't applied.

## Why CI doesn't catch this

`.github/workflows/ci.yml` was deliberately edited to **not** run
`vue-tsc --build`. Comment: "Type-check (vue-tsc) and lint (oxlint,
eslint) are caught locally before PRs." The local-dev expectation is
that the developer runs `bun run type-check` (or `bun run build`) via
**Node.js**, not Bun. The CI deliberately assumes this and skips the
type-check step because it's expected to fail under bun.

The project `package.json` `engines` field also asserts
`"node": "^20.19.0 || >=22.12.0"` — implying Node is required for the
type-check paths even though `bun` is the default runner.

## Why `vite build` works but `vue-tsc` doesn't

`vite` is a real bundler — it parses `.vue` files itself via
`@vitejs/plugin-vue` and never asks TypeScript about them. It does NOT
depend on the patched `fs.readFileSync` mechanism. So `bun run build-only`
succeeds even though `bun run type-check` fails.

`run-p` (npm-run-all2) runs both in parallel and propagates the first
non-zero exit. Because `vue-tsc` exits 2, the wrapping `bun run build`
exits non-zero, and `zig build webapp-rebuild` reports failure even
though `dist/` was successfully populated.

## Fix options

### Option A — install Node.js and use Node for type-check (recommended)

```bash
# Arch Linux: pacman -S nodejs npm
# macOS:     brew install node
# Ubuntu:    apt install nodejs npm
```

Then add a `type-check-node` script that forces Node:

```jsonc
// src/apps/desktop/package.json
"scripts": {
  "type-check": "node node_modules/vue-tsc/bin/vue-tsc.js --build",
  "type-check-node": "node node_modules/vue-tsc/bin/vue-tsc.js --build"
}
```

`bun run build` (the zig step) still uses Bun for the vite bundling,
but the `type-check` script path used by CI / pre-PR hooks would need
to swap to `node` invocation.

### Option B — skip type-check in the webapp-rebuild step (accept regression)

If `vue-tsc` is not gating anywhere (CI doesn't run it, vite bundling
succeeds without it), edit `src/apps/desktop/package.json`:

```jsonc
"build": "vite build",  // drop the run-p wrapper
```

This makes `zig build webapp-rebuild` succeed because the bundler is
the only thing that runs. Trade-off: no type-check before embedding
the bundle.

### Option C — switch to `vue-tsc` 2.x (still doesn't help on Bun)

`vue-tsc@2.x` used a different runtime strategy (language-service-only,
not tsc-source-mutation), but it ALSO uses the same `fs.readFileSync`
patching approach internally (verified in `vue-tsc@2.2.x` source).
So Option C does not fix the underlying bun-loader issue.

## Verification

```bash
# Confirm Bun is the active runtime
which node || echo "NO NODE — vue-tsc patching will silently no-op"
which bun  # bun path

# Show that fs.readFileSync patching has no effect in bun:
bun -e 'const fs=require("fs"); const orig=fs.readFileSync;
        fs.readFileSync=function(...a){console.error("INTERCEPTED",a[0]);
                                        return orig.apply(fs,a);};
        require("/path/to/typescript/lib/tsc");'
# Expect: no "INTERCEPTED" line.
```

## Pitfalls

- **Bun is fast and silent**: no error is thrown when the patching
  mechanism is bypassed. The only symptom is TS2307 errors that don't
  exist under Node.
- **CI being green is not sufficient evidence** — CI runs `bun` too,
  and the CI was deliberately edited to skip the failing step. A local
  Node run is the only ground truth.
- **Don't assume version pins are the problem**. Replacing
  `typescript@6.x` with `typescript@5.9.3`, or
  `vue-tsc@3.2.6` with `vue-tsc@3.3.8`, leaves the error identical.
  The bun/Node CJS-loader split is the variable that matters.
- **`@volar/typescript@2.4.28` is the latest** (no newer releases).
  There's nothing newer in the Volar line that fixes bun support.
- **After fixing, run a Node-based type-check** to confirm: e.g.
  `cd src/apps/desktop && node node_modules/vue-tsc/bin/vue-tsc.js -b -p tsconfig.app.json --noEmit`.

## Related

- `src/apps/desktop/package.json:12` — `"type-check": "vue-tsc --build"`
- `src/apps/desktop/package.json:53` — `engines.node` requires Node 20.19+ or 22.12+
- `build.zig:228-264` — `webapp-rebuild` step implementation
- `.github/workflows/ci.yml:380-385` — comment explaining why vue-tsc is intentionally not in CI
- `node_modules/@volar/typescript/lib/quickstart/runTsc.js` — the patching mechanism
- `node_modules/vue-tsc/index.js` — the vue-tsc entry that calls `runTsc`
