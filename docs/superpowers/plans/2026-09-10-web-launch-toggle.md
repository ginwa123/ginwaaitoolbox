# Web-Launch Toggle (browser mode, random port) — Implementation Plan

**Date:** 2026-09-10
**Task:** `task_1789052626064_0` (kanban `in_review_planning`)
**Ask:** General-tab toggle → ON launches the app as a web page (same UI as desktop, usable in browser), port is random.
**Scope of this doc:** plan only, no code. Human reviews before any `in progress` work.

---

## 1. What the user actually wants (intent)

- A checkbox/toggle in Settings → General (screenshot: Notifications + Retry section) like "Launch web / browser mode".
- Toggle ON → they get a URL they can open in Chrome/Edge/Firefox that looks and behaves exactly like the desktop app (same chats, kanban, SSE live updates).
- Toggle OFF → browser access stops (URL dead), desktop webview keeps working.
- Port random each time → no clash with the desktop daemon (`8081`), Vite default (`5173`), or another browser-mode instance.

## 2. Key fact that shapes the whole plan (from research)

**Prod never runs `pnpm run dev`.** `pnpm run dev` (= bare `vite`, default port `5173`, proxies `/api → http://localhost:8081`) is dev-only (`src/apps/desktop/vite.config.ts`, `package.json:7`).

Prod path is: `pnpm build → dist/ → codegen embeds bytes into `webapp_assets.zig` → `pabrik-desktop` extracts to temp `pabrik-desktop-webapp-<pid>/` → `pabrik` backend (`GinwaServer` on `127.0.0.1:8081`) serves API + static fallback (`/app → index.html`) → native webview opens `http://127.0.0.1:<port>/` (`src/apps/desktop_app/main.zig`, `src/main.zig:232`, `attach.zig`). Frontend uses **relative** `/api/*` + one `EventSource(/api/events)` (`api/index.ts:6,3257`), so the *same bytes* work in webview and in any browser with zero frontend fork.

**Consequence:** "launch a web" does NOT mean spawning Vite. It means making the *already-served* same-origin UI reachable from a system browser, on a random loopback port, with a toggle to start/stop it.

## 3. Recommended design (Phase 1 — reuse, don't duplicate)

### 3a. No second `GinwaServer`. One server, two viewers.

There is exactly one `GinwaServer` per process today (`src/main.zig:232-233`, `main_service.zig`). `listen()` blocks the main thread; Router/SseManager/WsManager/CronjobManager/ContextStore are per-server values (`http_server.zig:280,359-385`). A second live server in the same process needs a 2nd bind + 2nd `GinwaServer.init` + 2nd `listen()` on its own thread + shared `ContextIPCTui` (db, llm_config, active_loops, event_bus) with unclear thread-safety + duplicated shutdown/state-file bookkeeping. No precedent in-tree. **Rejected for Phase 1.**

Instead: the toggle controls a **browser-mode affordance over the existing server**:

- ON → backend ensures it is listening on a **random loopback port** (see §5) and reports the URL; frontend shows a `http://127.0.0.1:<random>/` pill with **Open in browser / Copy** buttons and optionally auto-opens the OS default browser once.
- OFF → pill disappears; server keeps serving the desktop webview (or, if the server itself was started *only* for browser mode, it shuts down — see lifecycle §6).
- Desktop webview and system browser are just two viewers of the same origin. No CORS, no proxy, no Vite, no DB fork (avoids SQLite multi-process locking and `state.json` single `{pid,port,host}` confusion).

If true isolation (desktop on 8081 + browser on random *simultaneously, separate processes*) is later required, that is Phase 2 (§8) — needs DB/WAL + state-file multi-entry design, explicitly out of Phase 1.

### 3b. Where the toggle lives (copy existing patterns, no new route family)

**Frontend — extend `PabrikGeneralSection`, don't make a new section** (206 lines, the file to copy):

- `PabrikGeneralSettings` gains one key, e.g. `web_launch_enabled: boolean` (naming TBD — alternatives `browser_mode_enabled`; pick one, stick to it).
- Checkbox row copied from the notify row: `<input type="checkbox" data-testid="toggle-web-launch" :checked="model.web_launch_enabled" @change="model = {...model, web_launch_enabled: checked}" />` + label "Launch web (browser mode)" + helper "Serve this same UI in your system browser on a random local port."
- When ON, a sub-row appears: readonly URL pill (`http://127.0.0.1:<port>/`) + Open + Copy buttons + "port changes each launch" hint. URL comes from a new status endpoint (§4), NOT from config.
- Parent `PabrikSettings.vue`: extend `generalSettings` default (`?? false`), `syncFromConfig`, `syncToConfig` (always write so dirty-pill fires), `PabrikConfig` interface in `api/index.ts:3736-3818`. Save rides the existing bulk `PUT /api/config/pabrik` — no new save path (same as MCP `enabled` toggle precedent, plan `2026-09-09-mcp-server-toggle.md`).
- Spec: extend `PabrikGeneralSection.spec.ts` (mount + click toggle → assert `update:modelValue` payload; URL pill hidden when off / shown when on with mocked status).

**Backend config — plain bool, no migration** (copy `notify_on_complete` pattern, `Config.zig`):

1. `LlmConfig.web_launch_enabled: bool = false` (+ doc comment citing firing sites).
2. `LlmConfigJson` mirror same default (missing key = false; legacy `config.json` byte-identical).
3. `init` hydrate + `clone()` copy (else `setLlmConfig` swap drops it).
4. `pabrik_config_put.zig:ConfigInput.web_launch_enabled: ?bool = null` + `if (input.web_launch_enabled) |v| config_json.web_launch_enabled = v;` (absent preserves).
5. `pabrik_config_get.zig` always emit.
6. Tests: static-contract greps + functional GET-defaults/PUT-roundtrip (copy `tests/functional/notify_on_error_test.py:_put_general_settings`).

**Live-apply:** like notify flags, the bool is read per-use from `di.llm_config`; no cache teardown needed (unlike MCP `markStale`/`evict` — there is no child pool here). The PUT tail (`setLlmConfig` atomic swap) already makes mid-run reads see the new value.

## 4. Backend API (minimal — status + start/stop, not a new family)

| Method + path | Purpose | Response |
|---|---|---|
| `GET /api/web/status` | Frontend polls on General-tab mount + after toggle (or pushes via existing SSE) | `{ enabled: bool, running: bool, url: ?string, port: ?u16 }` — `url` is `http://127.0.0.1:<port>/` when running |
| `POST /api/web/start` | Toggle ON (or Open button): pick random port if needed, ensure listener, return URL | `{ ok: true, url, port }` or `{ ok: false, error }` (port-exhausted, bind-failed) |
| `POST /api/web/stop` | Toggle OFF: stop browser-mode listener (Phase 1 = no-op on the main server except clearing the flag; see §6 for the two lifecycle options) | `{ ok: true }` |

- Register AFTER any literal `/api/web/...` siblings to avoid `matchRoute` shadowing (`router.zig:182` — literal after `:param` gets captured; add static-contract test).
- No auth today (no bearer middleware; `security.zig` is opt-in HMAC/CSRF only) — bind loopback-only (§7) is the security boundary. Document this.
- Frontend `api/index.ts`: `getWebStatus/startWeb/stopWeb` wrappers with 15 s timeout like `apiFetch`; 404 → `null` silent pattern like `getTask`.

Open question for review: should toggle-ON auto-`window.open(url)` once, or only show the pill and let the user click Open? Recommend: show pill + single auto-open on the transition OFF→ON (guarded, once), because popup-blockers eat non-gesture `window.open` — the explicit Open button is the reliable path.

## 5. Random port (the one new Zig primitive)

**No Zig picker exists today.** The only pickers are Python (`tests/functional/harness.py:find_free_port_random` — 50 random picks in `[40000,60000]`, `SO_REUSEADDR` probe on `127.0.0.1`, `reserved=(8081,)`; UI harness adds `5173`). Zig `Address.init → bindPort` binds immediately and fails with `BindFailed` on collision (`http_server.zig:194-205,228-254`) — no `port=0`/ephemeral, no retry.

**Phase 1 implementation (small, copies the harness verbatim):**

- New helper, e.g. `src/modules/config/web_port.zig` (or inside `main_service.zig`): `pickFreePort(allocator, reserved: []const u16) !u16` — CSPRNG/random pick in `[40000,60000]`, skip `{8081, 5173}`, `SO_REUSEADDR` probe-bind on `127.0.0.1` then close (same `port_is_free_with_reuse` semantics; `SO_REUSEADDR` is already set on the Zig listener so probe→real-bind handoff works despite `TIME_WAIT`). ~50 tries, then `error.PortExhausted` surfaced as `{ok:false}` (never crash the tick).
- Wire: `--port 0` (or empty) means "auto-pick" in `src/main.zig:190-217` + `main_service.zig:start/restart` parse; `0` → call picker before `Address.init`. `state.json` (`state_file.zig:14`) already stores `{pid,port,host}` — it must record the *actual* picked port so `attach.resolveAttachTarget()` (state-file → `:8081` probe → auto-spawn) and the webview URL builder (`main.zig:222`) follow the random port with no extra plumbing.
- `cli.zig`: `--port` (`0` = auto-pick) already exists as legacy-spawn; extend `--attach-port` the same way so desktop + browser agree.
- Unit tests: picker skips reserved, returns in-range, exhausts cleanly (mock bind); static-contract: `--port 0` path calls picker before `Address.init`.

Why `[40000,60000]` and not OS-ephemeral (`bind port 0` → `getsockname`)? Ephemeral is cleaner long-term, but the harness range is proven in-tree, avoids ephemeral-range platform variance (Linux/Win/macOS differ), and keeps functional tests deterministic. Note as follow-up: switch to `port 0 + getsockname` once `http_server.zig` exposes the bound port.

## 6. Lifecycle (decision needed — two options, recommend A)

**Option A (recommended): browser mode = same daemon, toggle is a flag + URL.**
- Toggle ON: `POST /api/web/start` → if server already running, return its URL (after ensuring it was started with a random port when the flag was set at spawn time); frontend shows pill.
- Toggle OFF: `POST /api/web/stop` → clear flag, pill hides; **server keeps running** (desktop unaffected). Simplest, zero shutdown races, zero DB risk. "Stop" means "stop advertising/opening browser", not "kill server".
- Restart semantics: if flag is ON at `pabrik service start`, spawn picks a random port (not 8081); if OFF, current behavior (8081) unchanged. Document that turning ON then restarting moves the desktop webview too (it reads `state.json`, so it follows automatically).

**Option B: toggle owns the listener (start/stop binds).**
- ON binds (or restarts onto) random port; OFF restarts back onto 8081 or shuts down an extra listener. Matches the mental model "toggle launches a web" most literally, but costs restart races (in-flight SSE/LLM streams drop), `shutdown()` wake-`accept` dance (`http_server.zig:1038-1064`), and state-file churn. Only choose if review insists OFF must kill the port.

Recommend shipping A, noting B as a follow-up if users report "OFF should free the port".

Edge cases to lock in tests: rapid ON→OFF→ON (idempotent start/stop, no double-bind); port taken between pick and bind (retry once, then `{ok:false}`); server restarted while browser tab open (old URL dies — pill shows new URL; document); close-desktop ≠ kill-daemon (`main.zig:225-228` — browser tab survives desktop close; document as feature).

## 7. Security + platform notes

- Bind `127.0.0.1` only. `Address.init` supports `0.0.0.0` ("required in containers", `http_server.zig:189-193`) but **no prod call site uses it** — keep it that way. Random port ≠ public exposure.
- No API auth today — anyone on the box can fetch the URL. Same exposure as 8081 today; the random port adds mild obscurity, not a boundary. If remote access is ever asked for, that needs token auth first (new work, out of scope).
- Opening the browser: frontend `window.open(url, "_blank", "noopener")` on explicit click; backend must NOT shell out to `xdg-open/open/start` in Phase 1 (platform matrix + escaping risk). Tauri/webview `shell.open` if available, else plain link.
- Windows/macOS/Linux: picker + `SO_REUSEADDR` probe is cross-platform; no `posix.poll`/winsock special-casing (unlike the MCP stdio `waitReadable` saga). CI runs on all three already.

## 8. Explicitly out of scope (Phase 2+)

- Spawning Vite dev from Zig (`build.zig` has no `dev` step; dev-vite is never spawned from Zig — keep it so).
- Second concurrent `GinwaServer` / per-session children (the MCP-stdio parallel-sessions lesson: one shared child per server name; per-session costs ~9.4 MB RAM each — same tradeoff applies here).
- Remote/LAN exposure (`0.0.0.0`, TLS, auth tokens).
- Persisting the picked port in `config.json` (ports are runtime, like `state.json`; persisting causes stale-port-on-reboot bugs — runtime only).
- New SSE event names (reuse `session.updated`-style riding or plain polling from the settings tab; if a new `event_type` is added, follow the triple-contract: backend emitter + `additionalEventTypes` + dispatch chain in `api/index.ts`, else the browser silently drops it).

## 9. Test plan (mirrors repo conventions)

- **Zig unit + static-contract** (`zig build test --summary all` must stay green): picker range/reserved/exhaustion; `Config` bool parse/hydrate/clone/omit-when-absent; route-order (literal before `:param`); `state.json` records picked port.
- **Functional (real wire, harness, never live-curl)** — new `tests/functional/web_launch_toggle_test.py` on an isolated tmpdir HOME + free port (never 8081): GET-defaults (`enabled=false`, `running` reflects spawn), PUT-roundtrip (`enabled` true/false), `POST /api/web/start` returns `http://127.0.0.1:<40000-60000>/` reachable via `/health`, `POST /api/web/stop` clears, rapid toggle idempotent. Copy `mcp_server_toggle_test.py` (3 tests) + `notify_on_error_test.py` patterns.
- **Frontend vitest** (`pnpm test:unit`): extended `PabrikGeneralSection.spec.ts` (toggle flips payload; pill hidden/shown; Open/Copy call `window.open`/clipboard with the status URL).
- **Manual:** desktop ON → browser URL works side-by-side; OFF → pill hides, desktop unaffected; restart with ON → both follow new random port; close desktop → browser tab still live (documented).

## 10. File touch-list (estimate, Phase 1)

- Backend (6-8 edits, 1 new): `Config.zig` (field+parse+hydrate+clone) + `pabrik_config_put/get.zig` (wire) + new `web_status/start/stop` handlers + `main.zig`/`main_service.zig`/`cli.zig`/`state_file.zig` (port-0 → picker → record) + new `web_port.zig` picker + `test_runner.zig` registrations.
- Frontend (4 edits): `PabrikGeneralSection.vue` (toggle + pill), `PabrikSettings.vue` (sync), `api/index.ts` (type + 3 wrappers), `PabrikGeneralSection.spec.ts`.
- Tests: 1 new functional file + Zig inline tests. No migration (config.json, not SQLite), no new SSE event, no build.zig chain change, no Vite change.

## 11. Review questions (please answer before `in progress`)

1. **Lifecycle A or B?** (§6 — recommend A: toggle = flag + URL, server keeps running when OFF.)
2. **Auto-open browser on ON, or pill-only?** (Recommend pill + one attempted auto-open, Open button as reliable path.)
3. **Field name:** `web_launch_enabled` vs `browser_mode_enabled`?
4. **Port range:** keep harness `[40000,60000]` + skip `{8081,5173}`, or go OS-ephemeral now?
5. Confirm **loopback-only** (no LAN) for Phase 1.

---
*Research sources: `src/apps/desktop_app/main.zig`, `attach.zig`, `cli.zig`, `extraction.zig`; `src/main.zig`, `src/service/main_service.zig`, `state_file.zig`; `src/modules/custom_http_server/src/http_server.zig`, `router.zig`; `src/modules/config/Config.zig`, `pabrik_config_put/get.zig`; `src/apps/desktop/src/components/PabrikSettings.vue`, `pabrik/PabrikGeneralSection.vue`, `api/index.ts`, `vite.config.ts`; `tests/functional/harness.py`, `tests/functional_ui/ui_harness.py`; prior plans `2026-09-09-mcp-server-toggle.md`.*

---
## 12. Build notes (filled in after implementation, task_1789052626064_0)

- **Single endpoint, not three.** Shipped only `GET /api/web/status`
  (`web_status.zig`, raw-JSON like `notify_test.zig`). Lifecycle A needs
  no server-side start/stop action — the flag is owned by
  `PUT /api/config/pabrik`, so `POST /api/web/start|stop` would have been
  dead code. Frontend flow: toggle → PUT → status → auto-open.
- **`--port 0` resolves via `web_port.pickFreePort(io)`** (xorshift64*
  seeded from `Io.Clock.now`, NOT `std.time.nanoTimestamp` — doesn't
  exist in this Zig version; the exe build caught it, unit tests didn't
  due to lazy analysis). Range `[40000,60000]`, skip `{8081,5173}`,
  probe via the server's own `Address.init` + `closeFd` (made `pub`).
  Flag-on startup with no explicit `--port` defaults to `0` (random);
  explicit `--port` always wins; 8081 default unchanged when off.
- **Test discovery gotcha (real):** new test blocks silently DON'T RUN
  unless registered — `web_status.zig` → `tui/test_runner.zig`,
  `web_port.zig` + `Config.zig` → `root.zig` test block (this also
  activated the 3 `config_test.zig` web-launch tests). Counts proved it:
  3192/3200 before registration → 3203/3211 after (+11). Static-contract
  grep tests lock both registrations.
- **Frontend mock-shape lesson:** `PabrikSettings.spec.ts` payloads had to
  gain `web_launch_enabled: false` — the always-write `syncToConfig`
  diffs against the snapshot, so a legacy-shaped mock (key absent)
  flashes dirty=true on load. Same reason the `vi.mock('../api')`
  factory needed `getWebStatus`, and the auto-open test needs TWO
  queued status responses (mount fetch consumes the first).
- **4 remaining vitest failures are pre-existing on main**
  (FilePickerDialog.windows, WorkspaceItemHideTasksForDesign,
  workspacesStoreNormalizeTaskDates/ImageUrls) — verified by running
  them on the untouched checkout.
