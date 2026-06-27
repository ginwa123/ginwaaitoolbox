# Rename `web_fetching_service` → `nalar_browser` Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rename the Bun service and the matching Zig agent tool from `web_fetching_service` / `cloak_browser` to `nalar_browser` (top to bottom — directory, package, tool name, and OS process name), so the OS task manager shows a single clean process called `nalar_browser` instead of `bun` / `bun run` / `web_fetching_service`.

**Architecture:** Two layers touched. (1) Bun service: `git mv` the directory, update `package.json` name + scripts, regenerate `bun.lock`, update README + `index.ts` banner + `health.ts` `service` field, add `bun build --compile` script that produces a standalone `nalar_browser` binary. (2) Zig tool: `git mv` the tool + test files, rename every `cloak_browser` / `CloakBrowser` identifier in the tool + its callers (`tool_registry.zig`, `root.zig`, `test_runner.zig`). All work is mechanical rename — no behavior change, no API change.

**Tech Stack:** Bun (≥ 1.1.0 for `--compile`), Zig 0.16, TypeScript.

**Reference spec:** `docs/plans/2026-06-12-web-fetching-service-to-nalar-browser-design.md` (already approved).

---

## Setup

### Task 0: Create a feature worktree

**Files:**
- Create: `.worktrees/feature/nalar-browser-rename/`

- [ ] **Step 1: Create and enter a new worktree off `main`**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
git worktree add .worktrees/feature/nalar-browser-rename -b feature/nalar-browser-rename main
cd .worktrees/feature/nalar-browser-rename
git status
```

Expected: `On branch feature/nalar-browser-rename`, `nothing to commit, working tree clean`.

- [ ] **Step 2: Verify the current `web_fetching_service` is at the expected location**

```bash
ls src/modules/web_fetching_service/
ls src/modules/agent/tools/cloak_browser.zig
```

Expected: directory listing shows `package.json`, `README.md`, `index.ts`, `http_handlers/`, `bun.lock`. The Zig file exists.

---

## Chunk 1: Bun service directory & package metadata

### Task 1.1: Rename the directory with git

**Files:**
- Move: `src/modules/web_fetching_service/` → `src/modules/nalar_browser/`

- [ ] **Step 1: `git mv` the directory (preserves history)**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/feature/nalar-browser-rename
git mv src/modules/web_fetching_service src/modules/nalar_browser
git status --short
```

Expected: `R  src/modules/web_fetching_service -> src/modules/nalar_browser` (or `D`/`A` pair — both are fine for `git mv`).

- [ ] **Step 2: Verify directory renamed**

```bash
ls src/modules/nalar_browser/
ls src/modules/web_fetching_service 2>&1 | head -3
```

Expected: first command lists `package.json`, `README.md`, `index.ts`, `http_handlers/`, `bun.lock`. Second command prints `No such file or directory`.

- [ ] **Step 3: Commit the directory rename**

```bash
git add -A
git commit -m "refactor(service): rename web_fetching_service directory to nalar_browser"
```

---

### Task 1.2: Update `package.json`

**Files:**
- Modify: `src/modules/nalar_browser/package.json`

- [ ] **Step 1: Read the current file**

```bash
cat src/modules/nalar_browser/package.json
```

- [ ] **Step 2: Replace the file with the updated content**

```json
{
  "name": "nalar_browser",
  "module": "index.ts",
  "type": "module",
  "private": true,
  "engines": {
    "bun": ">=1.1.0"
  },
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
  "devDependencies": {
    "@biomejs/biome": "^2.4.16",
    "@types/bun": "latest"
  },
  "peerDependencies": {
    "typescript": "^5"
  },
  "dependencies": {
    "chromium-bidi": "^16.0.1",
    "cloakbrowser": "^0.3.31",
    "playwright-core": "^1.60.0"
  }
}
```

- [ ] **Step 3: Verify the file is valid JSON**

```bash
cd src/modules/nalar_browser && bun --print 'JSON.parse(await Bun.file("package.json").text()).name'
```

Expected output: `nalar_browser`.

- [ ] **Step 4: Commit the package.json changes**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/feature/nalar-browser-rename
git add src/modules/nalar_browser/package.json
git commit -m "chore(nalar_browser): rename package, add build:compile script and engines.bun pin"
```

---

### Task 1.3: Regenerate `bun.lock`

**Files:**
- Modify: `src/modules/nalar_browser/bun.lock` (delete + regenerate)

- [ ] **Step 1: Delete the old lockfile and regenerate**

```bash
cd src/modules/nalar_browser
rm bun.lock
bun install
ls bun.lock
```

Expected: `bun install` prints a lockfile install line and exits 0. `ls bun.lock` shows the file exists. First 20 lines of `bun.lock` should reference `"name": "nalar_browser"`.

- [ ] **Step 2: Confirm lockfile mentions the new package name**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/feature/nalar-browser-rename
head -20 src/modules/nalar_browser/bun.lock
```

Expected: a line like `"name": "nalar_browser"`.

- [ ] **Step 3: Commit the regenerated lockfile**

```bash
git add src/modules/nalar_browser/bun.lock
git commit -m "chore(nalar_browser): regenerate bun.lock with new package name"
```

---

## Chunk 2: Bun service code & docs

### Task 2.1: Update `index.ts` banner & header

**Files:**
- Modify: `src/modules/nalar_browser/index.ts`

- [ ] **Step 1: Replace the top-of-file header comment (lines 1-6)**

`old_str`:
```ts
/**
 * Web Scraping API Service
 *
 * Anti-bot bypass scraping service using CloakBrowser.
 * Uses native Bun HTTP server (no external framework).
 */
```

`new_str`:
```ts
/**
 * Nalar Browser Service
 *
 * Anti-bot bypass stealth-browser service using CloakBrowser.
 * Uses native Bun HTTP server (no external framework).
 *
 * The compiled binary (built via `bun run build:compile`) runs as a process
 * named `nalar_browser` — visible as such in `top` / `htop` / `ps` / etc.
 */
```

- [ ] **Step 2: Replace the console.log banner block (lines 106-120)**

`old_str`:
```ts
console.log(`
╔══════════════════════════════════════════════════════╗
║     Web Scraping API (CloakBrowser)                   ║
╠══════════════════════════════════════════════════════╣
║  Health:      GET  /health                           ║
║  Launch:      POST /launch                            ║
║  Close:       POST /close/:browser_id                 ║
║  Page:        POST /page  {browser_id, url}           ║
║  Snapshot:    POST /snapshot {page_id}               ║
║  Click:       POST /click  {page_id, ref}            ║
║  Fill:        POST /fill   {page_id, ref, text}       ║
║  Press:       POST /press  {page_id, ref?, key}       ║
║  Page Close:  POST /page/close/:page_id               ║
╚══════════════════════════════════════════════════════╝
`);
```

`new_str`:
```ts
console.log(`
╔══════════════════════════════════════════════════════╗
║     Nalar Browser (anti-bot stealth Chromium)         ║
╠══════════════════════════════════════════════════════╣
║  Health:      GET  /health                           ║
║  Launch:      POST /launch                            ║
║  Close:       POST /close/:browser_id                 ║
║  Page:        POST /page  {browser_id, url}           ║
║  Snapshot:    POST /snapshot {page_id}               ║
║  Click:       POST /click  {page_id, ref}            ║
║  Fill:        POST /fill   {page_id, ref, text}       ║
║  Press:       POST /press  {page_id, ref?, key}       ║
║  Page Close:  POST /page/close/:page_id               ║
╚══════════════════════════════════════════════════════╝
`);
```

- [ ] **Step 3: Verify no `Web Scraping` references remain in the file**

```bash
cd src/modules/nalar_browser
grep -nE 'Web Scraping|web-scraping-api|web_scraping' index.ts
```

Expected: no output.

- [ ] **Step 4: Commit the banner changes**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/feature/nalar-browser-rename
git add src/modules/nalar_browser/index.ts
git commit -m "refactor(nalar_browser): update index.ts banner and header"
```

---

### Task 2.2: Update `health.ts` `service` field

**Files:**
- Modify: `src/modules/nalar_browser/http_handlers/health.ts`

- [ ] **Step 1: Replace the `service` field value**

`old_str`:
```ts
    service: "web-scraping-api",
```

`new_str`:
```ts
    service: "nalar-browser",
```

- [ ] **Step 2: Verify the change**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/feature/nalar-browser-rename
cat src/modules/nalar_browser/http_handlers/health.ts
```

Expected output:
```ts
import { jsonResponse } from "./helpers";

export function healthGet(): Response {
  return jsonResponse({
    status: "ok",
    service: "nalar-browser",
    version: "1.0.0",
    timestamp: new Date().toISOString(),
  });
}
```

- [ ] **Step 3: Commit**

```bash
git add src/modules/nalar_browser/http_handlers/health.ts
git commit -m "refactor(nalar_browser): rename health endpoint service field to nalar-browser"
```

---

### Task 2.3: Update `README.md`

**Files:**
- Modify: `src/modules/nalar_browser/README.md`

- [ ] **Step 1: Replace the H1 title (line 1)**

`old_str`:
```md
# Web Fetching Service
```

`new_str`:
```md
# Nalar Browser
```

- [ ] **Step 2: Replace the health-response example in the API section (lines 39-46)**

`old_str`:
```md
Response:
```json
{
  "status": "ok",
  "service": "web-scraping-api",
  "version": "1.0.0",
  "timestamp": "2025-01-20T00:00:00.000Z"
}
```
```

`new_str`:
```md
Response:
```json
{
  "status": "ok",
  "service": "nalar-browser",
  "version": "1.0.0",
  "timestamp": "2025-01-20T00:00:00.000Z"
}
```
```

- [ ] **Step 3: Append a "Building" section at the end of the README**

`old_str`:
```md
- Each request uses a fresh browser profile in `/tmp` for isolation
- Profiles are cleaned up after each request
- reCAPTCHA v3 scores are per-session - rotating IPs mid-session can lower scores
- CloakBrowser prevents CAPTCHAs from appearing, doesn't solve them
```

`new_str`:
```md
- Each request uses a fresh browser profile in `/tmp` for isolation
- Profiles are cleaned up after each request
- reCAPTCHA v3 scores are per-session - rotating IPs mid-session can lower scores
- CloakBrowser prevents CAPTCHAs from appearing, doesn't solve them

## Building

Requires **Bun ≥ 1.1.0** (for `bun build --compile`).

```bash
# Dev (hot reload; process name is `bun` in task managers)
bun --watch index.ts

# Production: compile a standalone `nalar_browser` binary
bun run build:compile
./nalar_browser
```

The compiled binary (`./nalar_browser`, ~50–100 MB) bundles the Bun runtime + this service. The OS process is named `nalar_browser` — visible as such in `top` / `htop` / `ps` / `gnome-system-monitor`. No runtime Bun required.

The binary is `.gitignore`d; rebuild it after pulling source changes.

## Development

| Task | Command |
|---|---|
| Type-check + format check | `bun run check` |
| Lint | `bun run lint` |
| Format | `bun run format` |
| Dev server (hot reload) | `bun run dev` |
| Production binary | `bun run build:compile && bun run start:compiled` |
```

- [ ] **Step 4: Verify the README no longer mentions `Web Fetching Service` or `web-scraping-api`**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/feature/nalar-browser-rename
grep -nE 'Web Fetching|web-scraping-api' README.md
```

Expected: no output.

- [ ] **Step 5: Commit**

```bash
git add src/modules/nalar_browser/README.md
git commit -m "docs(nalar_browser): rename README to Nalar Browser, add Building/Development sections"
```

---

### Task 2.4: Verify Bun side type-checks & lints

**Files:** (verification only)

- [ ] **Step 1: Run `bun run check` from the service directory**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/feature/nalar-browser-rename/src/modules/nalar_browser
bun run check
```

Expected: `bun run check` exits 0 with no errors. (Biome runs the format + lint check; it does NOT do TS type-checking. We're verifying the rename didn't break the formatter's understanding of the file structure.)

- [ ] **Step 2: Quick type sanity check — start the service and curl health**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/feature/nalar-browser-rename/src/modules/nalar_browser
bun run dev &
SERVICE_PID=$!
sleep 2
curl -sS http://localhost:3000/health
kill $SERVICE_PID 2>/dev/null
wait $SERVICE_PID 2>/dev/null
```

Expected: `{"status":"ok","service":"nalar-browser","version":"1.0.0","timestamp":"<ISO timestamp>"}` (the `service` field must be `nalar-browser`).

---

## Chunk 3: Compiled binary & .gitignore

### Task 3.1: Add `.gitignore` entries for the compiled binary

**Files:**
- Modify: `.gitignore` (project root)

- [ ] **Step 1: Read the current `.gitignore` to find a good insertion point**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/feature/nalar-browser-rename
cat .gitignore
```

- [ ] **Step 2: Append the compiled-binary ignore rules**

`old_str`:
```gitignore
.zig-cache
zig-out
test_main
.plans
/src/apps/kerjabot/node_modules
/src/apps/kerjabot/dist
/src/apps/desktop/node_modules
/src/apps/desktop/dist
/src/apps/desktop_app/embedded
/.worktrees
.nalar/tasks/
/docs
/zig-pkg
```

`new_str`:
```gitignore
.zig-cache
zig-out
test_main
.plans
/src/apps/kerjabot/node_modules
/src/apps/kerjabot/dist
/src/apps/desktop/node_modules
/src/apps/desktop/dist
/src/apps/desktop_app/embedded
/.worktrees
.nalar/tasks/
/docs
/zig-pkg

# nalar_browser compiled binary
src/modules/nalar_browser/nalar_browser
src/modules/nalar_browser/nalar_browser.exe
```

- [ ] **Step 3: Verify the ignore rule works**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/feature/nalar-browser-rename
# Build a fake file at the would-be path
touch src/modules/nalar_browser/nalar_browser
git check-ignore -v src/modules/nalar_browser/nalar_browser
rm src/modules/nalar_browser/nalar_browser
```

Expected: `git check-ignore` prints the matching `.gitignore` line.

- [ ] **Step 4: Commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/feature/nalar-browser-rename
git add .gitignore
git commit -m "chore: gitignore nalar_browser compiled binary"
```

---

### Task 3.2: Verify `bun build --compile` produces a working binary

**Files:** (verification only)

- [ ] **Step 1: Confirm Bun version supports `--compile`**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/feature/nalar-browser-rename/src/modules/nalar_browser
bun --version
```

Expected: `1.1.0` or higher. (If lower, follow the mitigation: stop and report to the user — they need to upgrade Bun.)

- [ ] **Step 2: Compile the binary**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/feature/nalar-browser-rename/src/modules/nalar_browser
bun run build:compile
ls -lh nalar_browser
file nalar_browser
```

Expected: `bun run build:compile` exits 0, `ls -lh` shows a ~50–100 MB binary named `nalar_browser` (or slightly larger), and `file` reports it as an ELF executable (Linux), Mach-O (macOS), or PE32+ (Windows).

- [ ] **Step 3: Start the compiled binary and curl /health**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/feature/nalar-browser-rename/src/modules/nalar_browser
./nalar_browser &
BIN_PID=$!
sleep 2
curl -sS http://localhost:3000/health
kill $BIN_PID 2>/dev/null
wait $BIN_PID 2>/dev/null
```

Expected: same `{"status":"ok","service":"nalar-browser",...}` response as in Task 2.4 Step 2.

- [ ] **Step 4: Verify process name in `ps` while the binary is running**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/feature/nalar-browser-rename/src/modules/nalar_browser
./nalar_browser &
BIN_PID=$!
sleep 2
ps -o pid,comm,args -p $BIN_PID
kill $BIN_PID 2>/dev/null
wait $BIN_PID 2>/dev/null
```

Expected: the `comm` column shows `nalar_browser` (15-char kernel limit; `nalar_browser` is 13 chars, fits). The `args` column shows `./nalar_browser`.

- [ ] **Step 5: Verify process name in `top`/`htop` (manual check)**

Open a separate terminal, run `./nalar_browser` in the service dir, then check `top` / `htop` / `btop` / `gnome-system-monitor`. The process should appear as `nalar_browser` in the command column.

(Note: this step is human-verified, not scriptable in a headless environment. The `ps` check in Step 4 already proves the kernel-level `comm` is correct; GUI task managers all derive their display from `/proc/<pid>/comm`.)

- [ ] **Step 6: Confirm the binary is gitignored**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/feature/nalar-browser-rename
git status
```

Expected: working tree is clean. The compiled `nalar_browser` binary does not appear in `git status` output.

---

## Chunk 4: Zig tool file rename

### Task 4.1: `git mv` the tool + test files

**Files:**
- Move: `src/modules/agent/tools/cloak_browser.zig` → `src/modules/agent/tools/nalar_browser.zig`
- Move: `src/modules/agent/tools/cloak_browser_test.zig` → `src/modules/agent/tools/nalar_browser_test.zig`

- [ ] **Step 1: Rename both files**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/feature/nalar-browser-rename
git mv src/modules/agent/tools/cloak_browser.zig src/modules/agent/tools/nalar_browser.zig
git mv src/modules/agent/tools/cloak_browser_test.zig src/modules/agent/tools/nalar_browser_test.zig
git status --short
```

Expected: two `R` (rename) entries for the .zig files.

- [ ] **Step 2: Commit the file renames**

```bash
git add -A
git commit -m "refactor(agent): rename cloak_browser.zig → nalar_browser.zig"
```

---

### Task 4.2: Rename identifiers in `nalar_browser.zig`

**Files:**
- Modify: `src/modules/agent/tools/nalar_browser.zig`

The renames are mechanical. Use a single `sed` invocation to do all the case-sensitive identifier substitutions at once, then verify by re-reading and running the build.

- [ ] **Step 1: Apply all identifier renames**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/feature/nalar-browser-rename
sed -i \
  -e 's/CloakBrowserInput/NalarBrowserInput/g' \
  -e 's/CloakBrowserResult/NalarBrowserResult/g' \
  -e 's/execute_cloak_browser/execute_nalar_browser/g' \
  -e 's/cloak_browser_tool/nalar_browser_tool/g' \
  -e 's/cloak_browser/nalar_browser/g' \
  src/modules/agent/tools/nalar_browser.zig
```

What this does (in order — important!):
1. `CloakBrowserInput` → `NalarBrowserInput`
2. `CloakBrowserResult` → `NalarBrowserResult`
3. `execute_cloak_browser` → `execute_nalar_browser` (longer pattern first)
4. `cloak_browser_tool` → `nalar_browser_tool` (longer pattern first)
5. `cloak_browser` → `nalar_browser` (catch-all for any remaining occurrences, including in `std.debug.print` strings, error XML strings, and tool definition fields)

- [ ] **Step 2: Update the tool definition's `.name` field**

`old_str`:
```zig
        .name = "cloak_browser",
```

`new_str`:
```zig
        .name = "nalar_browser",
```

(The `sed` substitution in Step 1 should have already done this because the string `"cloak_browser"` matches the `cloak_browser → nalar_browser` pattern. Verify the result; only edit if needed.)

- [ ] **Step 3: Update the tool's `.description` field to drop the "CloakBrowser" name**

`old_str`:
```zig
        .description = "CloakBrowser - stealth Chromium browser for anti-bot bypass. " ++
```

`new_str`:
```zig
        .description = "Nalar Browser - stealth Chromium browser for anti-bot bypass. " ++
```

- [ ] **Step 4: Update the `api_url` parameter's description**

`old_str`:
```zig
                    .description = "CloakBrowser API server URL. Defaults to http://localhost:3000. Change if service runs on different port.",
```

`new_str`:
```zig
                    .description = "Nalar Browser API server URL. Defaults to http://localhost:3000. Change if service runs on different port.",
```

- [ ] **Step 5: Update the error-XML string in `toXMLError`**

`old_str`:
```zig
    try buf.appendSlice(allocator, "CloakBrowser ");
```

`new_str`:
```zig
    try buf.appendSlice(allocator, "NalarBrowser ");
```

(The `sed` substitution `CloakBrowser → NalarBrowser` would have caught the type names but not the literal string `"CloakBrowser "` because it contains a trailing space and isn't followed by an identifier character. So we do it explicitly here.)

- [ ] **Step 6: Update any remaining `cloak_browser`/`CloakBrowser` references in doc comments**

Read the file and look for any remaining references:
```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/feature/nalar-browser-rename
grep -nE 'cloak_browser|CloakBrowser' src/modules/agent/tools/nalar_browser.zig
```

Expected: no output. (If anything remains, fix it manually with `text_replace`.)

- [ ] **Step 7: Verify the file compiles in isolation**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/feature/nalar-browser-rename
zig build-obj -fno-emit-bin --dep nalarcore -Mroot=src/modules/agent/tools/nalar_browser.zig -Mnalarcore=src/root.zig 2>&1 | head -20
```

Expected: errors related to "system library sqlite3" or similar, but NO errors about undefined identifiers, mismatched types, or stale references. The system-library error means our Zig code type-checks end-to-end. If the file has its own type errors, they will appear before the link step.

- [ ] **Step 8: Commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/feature/nalar-browser-rename
git add src/modules/agent/tools/nalar_browser.zig
git commit -m "refactor(agent): rename cloak_browser identifiers to nalar_browser in tool file"
```

---

### Task 4.3: Rename identifiers in `nalar_browser_test.zig`

**Files:**
- Modify: `src/modules/agent/tools/nalar_browser_test.zig`

- [ ] **Step 1: Apply all identifier renames (mirror Task 4.2 Step 1)**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/feature/nalar-browser-rename
sed -i \
  -e 's/CloakBrowserInput/NalarBrowserInput/g' \
  -e 's/CloakBrowserResult/NalarBrowserResult/g' \
  -e 's/execute_cloak_browser/execute_nalar_browser/g' \
  -e 's/cloak_browser_tool/nalar_browser_tool/g' \
  -e 's/cloak_browser/nalar_browser/g' \
  -e 's/"cloak_browser_tool definition"/"nalar_browser_tool definition"/g' \
  -e 's/"cloak_browser_tool has correct property names"/"nalar_browser_tool has correct property names"/g' \
  src/modules/agent/tools/nalar_browser_test.zig
```

- [ ] **Step 2: Update the import statement at the top of the file**

`old_str`:
```zig
const cloak_browser = @import("cloak_browser.zig");
```

`new_str`:
```zig
const nalar_browser = @import("nalar_browser.zig");
```

- [ ] **Step 3: Replace all `cloak_browser.X` references in the test body**

The test file uses `cloak_browser.CloakBrowserInput`, `cloak_browser.CloakBrowserResult`, etc. After Step 1's sed, these should already be `nalar_browser.NalarBrowserInput` etc. Verify:

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/feature/nalar-browser-rename
grep -nE 'cloak_browser|CloakBrowser' src/modules/agent/tools/nalar_browser_test.zig
```

Expected: no output.

- [ ] **Step 4: Verify the file compiles in isolation**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/feature/nalar-browser-rename
zig build-obj -fno-emit-bin --dep nalarcore -Mroot=src/modules/agent/tools/nalar_browser_test.zig -Mnalarcore=src/root.zig 2>&1 | head -20
```

Expected: same as Task 4.2 Step 7 — only system-library errors, no type errors.

- [ ] **Step 5: Commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/feature/nalar-browser-rename
git add src/modules/agent/tools/nalar_browser_test.zig
git commit -m "refactor(agent): rename cloak_browser identifiers to nalar_browser in tool test file"
```

---

### Task 4.4: Update `test_runner.zig` import

**Files:**
- Modify: `src/modules/agent/test_runner.zig` (line 25)

- [ ] **Step 1: Update the import path**

`old_str`:
```zig
    _ = @import("tools/cloak_browser_test.zig");
```

`new_str`:
```zig
    _ = @import("tools/nalar_browser_test.zig");
```

- [ ] **Step 2: Commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/feature/nalar-browser-rename
git add src/modules/agent/test_runner.zig
git commit -m "refactor(agent): update test_runner.zig import to nalar_browser_test"
```

---

## Chunk 5: Zig tool callers

### Task 5.1: Update `tool_registry.zig`

**Files:**
- Modify: `src/ai_workflow/tui/tool_registry.zig`

This file has multiple touch points. Apply a single `sed` to do all the case-sensitive identifier substitutions, then verify and patch the registration struct manually.

- [ ] **Step 1: Apply the bulk identifier renames**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/feature/nalar-browser-rename
sed -i \
  -e 's/cloak_browser_mod/nalar_browser_mod/g' \
  -e 's/cloak_browser_tool/nalar_browser_tool/g' \
  -e 's/"cloak_browser"/"nalar_browser"/g' \
  src/ai_workflow/tui/tool_registry.zig
```

What this does:
1. `cloak_browser_mod` → `nalar_browser_mod` (longer pattern first)
2. `cloak_browser_tool` → `nalar_browser_tool` (longer pattern first)
3. `"cloak_browser"` (the LLM-facing string) → `"nalar_browser"`

The `execCloakBrowser` function name (camelCase, in the `.exec = execCloakBrowser` field) is **not** matched by the above patterns. We'll fix that explicitly in Step 2.

- [ ] **Step 2: Find and rename `execCloakBrowser`**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/feature/nalar-browser-rename
grep -n 'execCloakBrowser' src/ai_workflow/tui/tool_registry.zig
```

Expected: two hits — one defining `fn execCloakBrowser(...)` and one in the registration struct.

- [ ] **Step 3: Rename the function definition**

`old_str`:
```zig
fn execCloakBrowser(ctx: *ToolContext, tc: ToolCall) anyerror!ToolOut {
```

`new_str`:
```zig
fn execNalarBrowser(ctx: *ToolContext, tc: ToolCall) anyerror!ToolOut {
```

- [ ] **Step 4: Rename the function reference in the registration struct**

(The `sed` in Step 1 should have already changed `cloak_browser_mod` and the string `"cloak_browser"`, but `execCloakBrowser` remains. Verify the registration struct is correctly updated:)

`old_str`:
```zig
        .{ .name = "nalar_browser", .exec = execCloakBrowser, .tool_def = nalar_browser_mod.nalar_browser_tool },
```

`new_str`:
```zig
        .{ .name = "nalar_browser", .exec = execNalarBrowser, .tool_def = nalar_browser_mod.nalar_browser_tool },
```

- [ ] **Step 5: Update the import alias on line 39**

(The `sed` in Step 1 changed `cloak_browser_mod` references, but NOT the `cloak_browser` field name in `nalar_mod.cloak_browser` — that's a different identifier. Update explicitly:)

`old_str`:
```zig
const cloak_browser_mod = nalar_mod.cloak_browser;
```

`new_str`:
```zig
const nalar_browser_mod = nalar_mod.nalar_browser;
```

- [ ] **Step 6: Verify no `cloak_browser` / `CloakBrowser` references remain in the file**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/feature/nalar-browser-rename
grep -nE 'cloak_browser|CloakBrowser|execCloakBrowser' src/ai_workflow/tui/tool_registry.zig
```

Expected: no output.

- [ ] **Step 7: Commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/feature/nalar-browser-rename
git add src/ai_workflow/tui/tool_registry.zig
git commit -m "refactor(tool_registry): rename cloak_browser to nalar_browser"
```

---

### Task 5.2: Update `root.zig` re-export

**Files:**
- Modify: `src/root.zig` (line 369)

- [ ] **Step 1: Update the `pub const` line**

`old_str`:
```zig
pub const cloak_browser = @import("modules/agent/tools/cloak_browser.zig");
```

`new_str`:
```zig
pub const nalar_browser = @import("modules/agent/tools/nalar_browser.zig");
```

- [ ] **Step 2: Commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/feature/nalar-browser-rename
git add src/root.zig
git commit -m "refactor(root): rename cloak_browser re-export to nalar_browser"
```

---

### Task 5.3: Run the full Zig test suite

**Files:** (verification only)

- [ ] **Step 1: Run `zig build test`**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/feature/nalar-browser-rename
timeout 180 zig build test --summary all 2>&1 | tail -20
```

Expected: same or higher pass count as `main` (currently 252/255 — three known flakes per project NALAR.md). No new failures. Look specifically for:
- `nalar_browser_tool definition` test passes
- `nalar_browser_tool has correct property names` test passes
- No "undefined identifier" errors mentioning `cloak_browser`

- [ ] **Step 2: If a test fails, debug per the receiving-code-review skill before proceeding**

(Do NOT proceed to Chunk 6 if the test count has dropped. Investigate, fix, re-run.)

---

## Chunk 6: End-to-end verification

### Task 6.1: Final grep sweep for stragglers

**Files:** (verification only)

- [ ] **Step 1: Grep the whole repo for the old names (excluding ignored dirs and the design doc)**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/feature/nalar-browser-rename
rg -i 'cloak_browser|web_fetching|web_scraping' \
  --hidden \
  -g '!node_modules' \
  -g '!dist' \
  -g '!.git' \
  -g '!zig-out' \
  -g '!docs/' \
  -g '!*.lock' \
  2>&1 | head -30
```

Expected: no output. (The `.lock` exclusion lets `bun.lock` and `package-lock.json` slip through if they exist; in practice, the regenerated `bun.lock` no longer contains the old name.)

- [ ] **Step 2: Grep for the old CamelCase type name**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/feature/nalar-browser-rename
rg 'CloakBrowser' \
  --hidden \
  -g '!node_modules' \
  -g '!dist' \
  -g '!.git' \
  -g '!zig-out' \
  -g '!docs/' \
  2>&1 | head -10
```

Expected: no output.

- [ ] **Step 3: If anything is found, fix it before proceeding to Task 6.2**

---

### Task 6.2: Run the full test suite + build

**Files:** (verification only)

- [ ] **Step 1: Run the Zig test suite**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/feature/nalar-browser-rename
timeout 180 zig build test --summary all 2>&1 | tail -10
```

Expected: same or higher pass count as the pre-rename baseline.

- [ ] **Step 2: Run the Bun lint check on the service**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/feature/nalar-browser-rename/src/modules/nalar_browser
bun run check
```

Expected: exits 0.

- [ ] **Step 3: Build the Linux executable to make sure the Zig build still works end-to-end**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/feature/nalar-browser-rename
timeout 300 zig build install:linux 2>&1 | tail -10
```

Expected: builds `zig-out/bin/nalar`. (This is the existing `nalar` binary — unchanged. Just a smoke-test that the Zig rename didn't break the build graph.)

---

### Task 6.3: End-to-end smoke test

**Files:** (verification only)

- [ ] **Step 1: Start the compiled `nalar_browser` binary in the background**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/feature/nalar-browser-rename/src/modules/nalar_browser
./nalar_browser &
NBPID=$!
sleep 2
```

- [ ] **Step 2: Curl /health and verify the `service` field is `nalar-browser`**

```bash
curl -sS http://localhost:3000/health
```

Expected: `{"status":"ok","service":"nalar-browser","version":"1.0.0","timestamp":"<ISO>"}`.

- [ ] **Step 3: POST to /launch to verify the service works end-to-end**

```bash
curl -sS -X POST http://localhost:3000/launch | head -c 200
```

Expected: JSON response with `"success": true` and a `browser_id`.

- [ ] **Step 4: Verify process name in `ps`**

```bash
ps -o pid,comm,args -p $NBPID
```

Expected: `comm = nalar_browser`, `args = ./nalar_browser`.

- [ ] **Step 5: Shut the service down**

```bash
kill $NBPID 2>/dev/null
wait $NBPID 2>/dev/null
```

---

### Task 6.4: Final commit and PR

**Files:**
- Maybe: any fix-up commits from Tasks 6.1-6.3

- [ ] **Step 1: Confirm clean state**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/feature/nalar-browser-rename
git status
```

Expected: working tree clean (or only the compiled binary which is gitignored).

- [ ] **Step 2: View the commit log to confirm a clean linear history**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/feature/nalar-browser-rename
git log --oneline main..HEAD
```

Expected: ~10-12 commits with messages like:
```
refactor(agent): rename cloak_browser identifiers to nalar_browser in tool file
refactor(agent): rename cloak_browser identifiers to nalar_browser in tool test file
refactor(agent): update test_runner.zig import to nalar_browser_test
refactor(tool_registry): rename cloak_browser to nalar_browser
refactor(root): rename cloak_browser re-export to nalar_browser
refactor(agent): rename cloak_browser.zig → nalar_browser.zig
chore: gitignore nalar_browser compiled binary
docs(nalar_browser): rename README to Nalar Browser, add Building/Development sections
refactor(nalar_browser): rename health endpoint service field to nalar-browser
refactor(nalar_browser): update index.ts banner and header
chore(nalar_browser): regenerate bun.lock with new package name
chore(nalar_browser): rename package, add build:compile script and engines.bun pin
refactor(service): rename web_fetching_service directory to nalar_browser
```

- [ ] **Step 3: Push the branch and open a PR (per project conventions)**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/feature/nalar-browser-rename
git push -u origin feature/nalar-browser-rename
```

Then create a PR with a description summarizing the rename. Reference the design doc: `docs/plans/2026-06-12-web-fetching-service-to-nalar-browser-design.md`.

---

## Reference Skills

- `superpowers:brainstorming` — used in the design phase
- `superpowers:writing-plans` — this plan
- `superpowers:subagent-driven-development` or `superpowers:executing-plans` — for execution
- `superpowers:verification-before-completion` — for the end-of-chunk verification (Task 5.3, Task 6.1-6.3)
- `superpowers:requesting-code-review` — for review before merging the PR

## Pitfalls

- **`execCloakBrowser` is camelCase and won't match the lowercase `sed` pattern in Task 5.1** — the plan addresses this with an explicit Step 3.
- **`process.title` is NOT used** — the design chose Option A (`bun build --compile`), so the process name is the binary's filename. Don't add `process.title = "nalar_browser"` to `index.ts`; it's dead code under the compiled-binary model.
- **The `cloak_browser` import in `tool_registry.zig` line 39** (`nalar_mod.cloak_browser`) refers to the `pub const` re-export from `root.zig`. The `sed` in Task 5.1 Step 1 doesn't touch `nalar_mod.cloak_browser` because the pattern is `cloak_browser_mod`, not `nalar_mod.cloak_browser`. Task 5.1 Step 5 fixes this explicitly.
- **The compiled binary is `~50–100 MB`** and must be gitignored. The plan handles this in Task 3.1.
- **`@import("cloak_browser.zig")` inside the test file** becomes a stale path after Task 4.1's file rename. Task 4.3 Step 2 updates it to `@import("nalar_browser.zig")`.
- **`zig build-obj` in Task 4.2 / 4.3 may report "import of file outside module path"** when `root_source_file` is in a subdirectory — if so, run from the project root and use `-Mroot=<full path>` (the plan already does this). If a different error appears, report it to the user before proceeding.
