# Rename `web_fetching_service` → `nalar_browser`

**Date:** 2026-06-12
**Status:** Approved
**Owner:** ginwa
**Implementation Plan:** `docs/superpowers/plans/2026-06-12-web-fetching-service-to-nalar-browser.md` (next step)

---

## Overview

Rename the Bun-based stealth-browser service from `web_fetching_service` to `nalar_browser` everywhere it appears in this repo, and produce a compiled `nalar_browser` binary so the OS process shows as `nalar_browser` (not `bun` / `bun run`) in `top` / `htop` / `ps` / `gnome-system-monitor` / `btop` / etc.

The rename also covers the matching Zig agent tool (`cloak_browser` → `nalar_browser`) for consistency — the LLM-facing tool name, the tool file, and the `pub const` re-export all become `nalar_browser`.

The underlying stealth-browser library (`cloakbrowser` on npm) is **not** renamed — it still does the actual anti-bot Chromium work. We're renaming the wrapper service and the agent-tool entry point that uses it.

---

## Decisions (2 questions, all approved)

| # | Decision | Choice |
|---|----------|--------|
| 1 | Should the Zig tool `cloak_browser` be renamed too? | **A — Yes, rename to `nalar_browser`** (full consistency across directory, tool, and process) |
| 2 | How should the process show as `nalar_browser` in task managers? | **A — `bun build --compile` standalone binary** (real `nalar_browser` executable; visible as `nalar_browser` in every task manager; no runtime Bun required) |

---

## Scope of the rename

| Layer | Old | New |
|---|---|---|
| Bun service directory | `src/modules/web_fetching_service/` | `src/modules/nalar_browser/` |
| Bun package name (in `package.json`, `bun.lock`) | `web_fetching_service` | `nalar_browser` |
| README title | "Web Fetching Service" | "Nalar Browser" |
| Console banner in `index.ts` | "Web Scraping API (CloakBrowser)" | "Nalar Browser" |
| Health endpoint's `service` field | `"web-scraping-api"` | `"nalar-browser"` |
| Zig tool name (LLM-facing) | `cloak_browser` | `nalar_browser` |
| Zig tool file | `src/modules/agent/tools/cloak_browser.zig` | `src/modules/agent/tools/nalar_browser.zig` |
| Zig test file | `src/modules/agent/tools/cloak_browser_test.zig` | `src/modules/agent/tools/nalar_browser_test.zig` |
| Process name in task manager | `bun` (or `bun run`) | `nalar_browser` |

### Not in scope (intentionally unchanged)

- HTTP API endpoints (`/launch`, `/page`, `/snapshot`, `/click`, `/fill`, `/press`, `/page/close/:id`, `/close/:id`, `/health`) — clients don't care about the service's name.
- Default port (`3000`) and the `api_url` parameter on the Zig tool.
- The `cloakbrowser` npm package — that's the underlying stealth-browser library; it still does the actual rendering work.
- The tool's behavior, input schema, or output format.
- The HTTP request/response shapes — both sides are internal to this monorepo and there are no other clients.

---

## Process name: `bun build --compile`

### `package.json` scripts (final)

```json
{
  "scripts": {
    "dev": "bun --watch index.ts",
    "build": "bun build index.ts --target=bun --external=playwright-core --external=cloakbrowser --outdir=dist",
    "build:compile": "bun build --compile ./index.ts --outfile nalar_browser",
    "start": "bun run check && ./nalar_browser",
    "start:dist": "bun run dist/index.js",
    "start:compiled": "./nalar_browser",
    "lint": "biome lint .",
    "lint:fix": "biome lint --write .",
    "format": "biome format --write .",
    "check": "biome check ."
  },
  "engines": {
    "bun": ">=1.1.0"
  }
}
```

### Workflow

| Phase | Command | Process name in `top`/`htop` |
|---|---|---|
| Dev (hot reload) | `bun --watch ./index.ts` | `bun` |
| CI / lint | `bun run check` | n/a |
| Production / install | `bun run build:compile` once, then `./nalar_browser` (or `bun run start:compiled`) | `nalar_browser` |

### Artifact & .gitignore

- Compiled binary lives at `src/modules/nalar_browser/nalar_browser` (~50–100 MB; Bun runtime bundled in).
- Add to `.gitignore`:
  ```
  src/modules/nalar_browser/nalar_browser
  src/modules/nalar_browser/nalar_browser.exe
  ```
- Add a note in the README that the binary must be (re)compiled after pulling source changes.

---

## File-by-file change list

### Bun service (mechanical rename, in `src/modules/nalar_browser/`)

1. **Rename directory** (preserves git history):
   ```
   git mv src/modules/web_fetching_service src/modules/nalar_browser
   ```

2. **`package.json`**:
   - `"name": "web_fetching_service"` → `"name": "nalar_browser"`
   - Add `"engines": { "bun": ">=1.1.0" }`
   - Add `build:compile` and `start:compiled` scripts
   - Change `start` to `bun run check && ./nalar_browser`
   - Keep the `build` script (Bun-bundle, not compiled binary) for tooling that wants the source bundle

3. **`bun.lock`** — delete and regenerate:
   ```
   rm bun.lock && bun install
   ```
   Bun will rewrite `bun.lock` with the new package name.

4. **`README.md`**:
   - Title: "Web Fetching Service" → "Nalar Browser"
   - Section headings (where they mention "Web Scraping API" / "web-scraping-api")
   - Health response example: `"service": "web-scraping-api"` → `"service": "nalar-browser"`
   - Add a "Building" section explaining `bun run build:compile` and the Bun ≥ 1.1.0 requirement
   - Add a "Development" section explaining the dev workflow (`bun --watch index.ts`)

5. **`index.ts`**:
   - Top-of-file comment block: "Web Scraping API Service" → "Nalar Browser Service"
   - Banner `console.log` block: "Web Scraping API (CloakBrowser)" → "Nalar Browser"
   - (No `process.title` change needed — the compiled binary's filename is what the OS shows.)

6. **`http_handlers/health.ts`**:
   - `service: "web-scraping-api"` → `service: "nalar-browser"`

7. **`http_handlers/*.ts`** — verified by ripgrep: no other name references; no edits.

8. **`scripts/google_search.ts`** — verified by ripgrep: it's a client script that POSTs to `/scrape`; no name references; no edits.

### Zig side (the tool that calls the service)

1. **Rename files** (preserves git history):
   ```
   git mv src/modules/agent/tools/cloak_browser.zig      src/modules/agent/tools/nalar_browser.zig
   git mv src/modules/agent/tools/cloak_browser_test.zig src/modules/agent/tools/nalar_browser_test.zig
   ```

2. **Inside `nalar_browser.zig`** (was `cloak_browser.zig`):
   - `CloakBrowserInput` → `NalarBrowserInput`
   - `CloakBrowserResult` → `NalarBrowserResult`
   - `execute_cloak_browser` → `execute_nalar_browser`
   - `cloak_browser_tool` → `nalar_browser_tool`
   - All `std.debug.print` strings with `"DEBUG cloak_browser: …"` → `"DEBUG nalar_browser: …"`
   - The error-XML string `"CloakBrowser "` (inside `toXMLError`) → `"NalarBrowser "`
   - The `cloak_browser_tool` struct:
     - `.function.name = "cloak_browser"` → `.function.name = "nalar_browser"`
     - `.function.description`: drop the literal "CloakBrowser" name; describe the tool as "Nalar Browser — stealth Chromium browser for anti-bot bypass" (or similar; keep the workflow description intact)
     - The `api_url` parameter's `description`: "CloakBrowser API server URL" → "Nalar Browser API server URL"
   - Field doc comments that start with "CloakBrowser" → "NalarBrowser" (consistency)

3. **Inside `nalar_browser_test.zig`** (was `cloak_browser_test.zig`):
   - All `cloak_browser` identifiers → `nalar_browser` (mirroring the rename above)
   - Test names `"cloak_browser_tool definition"` and `"cloak_browser_tool has correct property names"` → `"nalar_browser_tool definition"` and `"nalar_browser_tool has correct property names"`

4. **`src/modules/agent/test_runner.zig`** (line 25):
   - `_ = @import("tools/cloak_browser_test.zig");` → `_ = @import("tools/nalar_browser_test.zig");`

5. **`src/ai_workflow/tui/tool_registry.zig`**:
   - Line 39: `const cloak_browser_mod = nalar_mod.cloak_browser;` → `const nalar_browser_mod = nalar_mod.nalar_browser;`
   - Lines 1131, 1136–1155: all `cloak_browser_mod` → `nalar_browser_mod`
   - Line 1136, 1143, 1144, 1149, 1150, 1153, 1154, 1155: string literal `"cloak_browser"` in `wrapToolOutput(allocator, "cloak_browser", …)` → `"nalar_browser"`
   - Line 1588: `.{ .name = "cloak_browser", .exec = execCloakBrowser, .tool_def = cloak_browser_mod.cloak_browser_tool },` — all four identifiers change (string `"cloak_browser"` → `"nalar_browser"`, function `execCloakBrowser` → `execNalarBrowser`, tool `cloak_browser_tool` → `nalar_browser_tool`, module `cloak_browser_mod` → `nalar_browser_mod`)
   - Line 1625: `cloak_browser_mod.cloak_browser_tool,` → `nalar_browser_mod.nalar_browser_tool,`
   - The function `execCloakBrowser` (defined elsewhere in the file) → `execNalarBrowser`

6. **`src/root.zig`** (line 369):
   - `pub const cloak_browser = @import("modules/agent/tools/cloak_browser.zig");` → `pub const nalar_browser = @import("modules/agent/tools/nalar_browser.zig");`

### `.gitignore`

Append the compiled-binary ignore rules:
```
# nalar_browser compiled binary
src/modules/nalar_browser/nalar_browser
src/modules/nalar_browser/nalar_browser.exe
```

---

## Architecture (post-rename)

```
                        ┌────────────────────────────────────┐
   LLM agent  ──────►   │ Zig tool: nalar_browser            │
   (function call)      │ src/modules/agent/tools/           │
                        │         nalar_browser.zig          │
                        │                                    │
                        │ POST http://localhost:3000/...     │
                        └─────────────────┬──────────────────┘
                                          │ HTTP
                                          ▼
                        ┌────────────────────────────────────┐
                        │ Process: nalar_browser  (ps/top)   │
                        │ src/modules/nalar_browser/         │
                        │         index.ts                   │
                        │                                    │
                        │ Bun runtime + CloakBrowser lib     │
                        │ anti-bot stealth Chromium          │
                        └────────────────────────────────────┘
```

Process name visible in OS task managers is **`nalar_browser`** (a single compiled executable). No more "bun" or "bun run" noise.

---

## Risks & mitigations

| Risk | Mitigation |
|---|---|
| Old `cloak_browser` name lingers in agent prompts / conversation history | Tool definition's `name` field is the only thing the LLM uses to invoke; once it's `"nalar_browser"`, old calls fail loudly and the LLM learns the new name. No silent breakage. |
| LLM agent calls `cloak_browser` after the rename and gets a confusing error | The tool registry's error path already returns a structured `wrapToolOutput` failure with the tool name; the LLM can adapt on its own. Acceptable. |
| Compiled binary not rebuilt after `git pull` | README documents the rebuild step (`bun run build:compile`). CI can detect a stale binary by checking git status (out of scope for this rename). |
| Bun version < 1.1.0 on a contributor's machine | `engines.bun` field added; `bun build:compile` will print a clear "Bun ≥ 1.1.0 required" error if `--compile` is unavailable. |
| `cloak_browser_mod` / `cloak_browser_tool` identifier renames in `tool_registry.zig` are not exhaustive (e.g., a `execCloakBrowser` defined earlier in the file) | A post-rename `zig build test` and `rg "cloak_browser|CloakBrowser" --hidden -g '!node_modules' -g '!dist' -g '!.git' -g '!zig-out'` over the whole repo should return zero hits except inside the `bun.lock` history and `docs/`. |
| File renames break Zig's `@import` paths | We update every `@import(".../cloak_browser.zig")` and `@import(".../cloak_browser_test.zig")` in lockstep with the file renames. `git grep` pre-merge verifies no stale imports. |

---

## Verification (post-implementation)

1. **Grep** — `rg -i 'cloak_browser|web_fetching|web_scraping' --hidden -g '!node_modules' -g '!dist' -g '!.git' -g '!zig-out' -g '!docs/'` returns zero hits.
2. **Grep** — `rg 'CloakBrowser' --hidden -g '!node_modules' -g '!dist' -g '!.git' -g '!zig-out' -g '!docs/'` returns zero hits (no leftover type names, struct fields, or display strings).
3. **Bun side** — `cd src/modules/nalar_browser && bun run check` exits 0.
4. **Bun side** — `cd src/modules/nalar_browser && bun run build:compile && ./nalar_browser` starts the service on port 3000; `curl http://localhost:3000/health` returns `{"service": "nalar-browser", ...}`.
5. **Bun side** — `ps -o comm,args -p $(pgrep -f nalar_browser | head -1)` shows `comm = nalar_browser` (15-char limit on Linux; `nalar_browser` is 13, fits).
6. **Bun side** — `top` / `htop` show the process as `nalar_browser` in the command column.
7. **Zig side** — `zig build test --summary all` passes (current 252/255 or higher).
8. **Zig side** — `zig build install:linux` produces `zig-out/bin/nalar` (no other name changes).
9. **Zig side** — the new `nalar_browser` tool appears in the agent's tool list (e.g., during a session, the LLM can call `nalar_browser(action: "launch")`).
10. **README** — human-reads the README's "Building" section to confirm the compile instructions are clear.

---

## Out of scope (deferred)

- CI workflow that automatically builds `nalar_browser` on tagged releases.
- Cross-platform `bun build --compile` targets (macOS, Windows) — out of scope for the rename; the `build:compile` script can be extended later.
- Uninstall / cleanup path for the old `web_fetching_service` (the directory rename via `git mv` is the cleanup).
- Renaming the HTTP API endpoints (kept for backward compatibility with any external test scripts that may exist in the wild; in this repo, all callers are internal and updated together).
