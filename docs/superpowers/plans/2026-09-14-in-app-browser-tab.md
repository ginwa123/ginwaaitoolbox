# In-app browser tab — simplified (Cursor-shaped)

> **Status: EXECUTED (2026-09-14)** — shell + frontend + docs landed on
> `worktree/task-1789376475404`. See **Implementation status** at the bottom for
> the shipped/deviated/gates record.
>
> Rev 7 (2026-09-14). Rev 6 closed five gaps
> found in review (unauthenticated local spawn surface, the "one window per tab"
> vs. edge-case-#7 ambiguity, an unqualified PID-liveness claim, an unbounded
> chrome-bar remount, and an explicit non-goal statement). Rev 7 folds in the
> follow-up review of those fixes:
>
> * **`3.3` collapsed to a single option.** The loopback spawn route is gone
>   entirely — not merely token-gated. It could not locate `nalar-desktop` (the
>   server never learns the desktop's path) and its token could not be kept secret
>   (it would be served by the same unauthenticated loopback server). Replaced by a
>   **`webview_bind` bridge**: the SPA calls a function in the *shell's own*
>   process. No new HTTP surface at all.
> * **Window state and liveness moved into the shell**, which owns the child
>   handles — so PID reuse is *eliminated* rather than mitigated by the `startedAt`
>   heuristic rev 6 proposed (and the frontend, which cannot read a process table,
>   no longer claims to).
> * **The primary button is never disabled.** We cannot raise another process's
>   window, so "window open + primary disabled" was a dead end; one always-enabled
>   button whose label follows the state replaces it, and the "primary pid" concept
>   is dropped.
> * **Chrome-bar remount is `MutationObserver`-driven with a cap**, not a poll —
>   event-driven, zero idle cost, still bounded.
> * **The chrome script is a real embedded `.js` asset with a jsdom behavioural
>   test**, replacing the Zig string-literal check whose own wording ("or document
>   the check that stands in for it") admitted it was not a test.
> * Two gaps closed: `1.2` now calls `runBrowserWindow` (rev 6 said `runWindow`),
>   and **app-quit semantics** are decided (spawned windows survive — they are
>   independent windows, and `nalar` is not required for them to work).
>
> **For agentic workers:** this is a *planning* artefact. Before implementing, use
> subagent-driven-development / executing-plans. Steps use checkbox (`- [ ]`)
> syntax for tracking.

**Task:** `task_1789376526556_0` — *"in browser app is a feature to open a new tab,
but literally a browser"*.

**Goal:** `+` opens a browser tab; type `github.com` or a Google search; the page
opens **in a real webview — a Nalar-owned window, Q6 locked** — where links, sign-in
and dev servers work, with a new Zig work path that is one CLI flag, one injected
chrome bar and one bound function, and **no proxy, no iframe, no SSRF surface, no
frame-policy matrix, no new HTTP route.**

**Non-goal (explicit):** this ships the *primitive* Cursor's browser is built on —
a real, separate-window webview with session persistence — not Cursor's actual
headline feature, which is an **agent** driving that browser (screenshot, click,
console, approval-gated navigation). Agent control is out of scope for v1 and is its
own card (§10.3). If anyone reads this plan as "add Cursor's browser," the correct
reading is "add the window Cursor's browser would sit on top of."

Generated 2026-09-14 against `main` @ `b7c2d39e`.

---

## 1. What Cursor's Browser is, and what "mirroring" it means for us

Read from the live page on 2026-09-14. The load-bearing sentences:

> "Agent can control a web browser to test applications, audit accessibility,
> convert designs into code, and more."
>
> "Agent displays browser actions like screenshots and actions in the chat, as well
> as the browser window itself **either in a separate window or an inline pane**."
>
> "Browser state persists between Agent sessions based on your workspace … Cookies
> … Local Storage … IndexedDB."
>
> "You can use Browser **without installing or configuring any external tools**."

| Cursor has | Why it works there | What we do in v1 | Follow-up |
|---|---|---|---|
| Navigate anywhere (any site, links, back/forward, refresh) | The page is a **real top-level webview inside Electron** — no `X-Frame-Options` problem exists | ✔ A real webview in a Nalar-owned window | in-window pane (§10.2) |
| Session persistence (cookies / localStorage / IndexedDB) | A real browser context with a persistent store | ✔ the engine's default store, already persistent (`webview.h:1870` uses `webkit_web_view_new()` → the default context) | isolated per-workspace store (§10.4) |
| "separate window **or** inline pane" | Electron can parent a `WebContentsView` anywhere | ✔ **separate window** — **locked by the reviewer (Q6)** | inline pane (the expensive half — §10.2) |
| Screenshot / console / network / click / type — agent-driven | An MCP server + approval modes + allow/deny lists | ✖ not in v1: the tab is *user*-driven | §10.3 — our `agent-browser` CLI and the in-tree `nalar_browser` Bun service already do snapshot/click/fill/press |
| Security: approval per action, allow/block lists, origin allowlist | Agent actions need gating | ✖ nothing to gate: no agent control in v1 | §10.3 |
| Dev-server awareness (find the running port instead of guessing) | Prompt + tooling integration | ✔ partially, for free: type `localhost:<port>` and it works, because **dev servers send no framing headers** | — |

**The insight that simplifies everything:** revs 1–3 were hard *only* because the
page was going into an `<iframe>`. Cursor does not have that problem, and it does
not have it for one reason — its browser view is a **top-level webview**. Give our
page a top-level webview too and the entire proxy / preflight / relay / SSRF /
sandbox subsystem disappears.

## 2. The one hard constraint, measured in our own vendored shell

`vendor/webview/webview.h:1853-1885` (GTK engine constructor):

```cpp
gtk_webkit_engine(bool debug, void *window)
    : m_owns_window{!window}, m_window(static_cast<GtkWidget *>(window)) {
  if (m_owns_window) { … gtk_compat::window_new(); … }
  m_webview = webkit_web_view_new();                      // ← default context: persistent cookies
  …
  gtk_compat::window_set_child(GTK_WINDOW(m_window), GTK_WIDGET(m_webview));  // ← replaces the single child
```

Two facts follow, and they decide the whole design:

1. **A window holds exactly one engine view.** Passing our app window to
   `webview_create(0, our_window)` would **replace the SPA** with the browser view
   (`gtk_window_set_child`; Cocoa `setContentView:` at `:2632`; Windows
   `CreateCoreWebView2Controller(m_window, …)` at `:3617`). So Cursor's *inline
   pane* mode needs a patched container **per OS** — that is the multi-week half
   (§10.2), not a v1 thing.
2. **The view gets the engine's default, persistent cookie/store** — so sign-in
   survives restarts with **no code from us**. That is the whole "session
   persistence" row above, for free.

Therefore v1 = **Cursor's "separate window" mode**: `nalar-desktop --browser <url>`
opens a real webview window. Days, not weeks, and it is one of the two modes the
reference product itself ships.

## 3. Decisions (locked)

| Decision | Value | Why |
|---|---|---|
| How the page renders | **A real webview in a Nalar-owned window** (`webview_create(0, NULL)` + `navigate`), spawned as its own process — **locked by the reviewer (Q6: Cursor's "separate window" mode)** | §2. Real top-level context: any site, links, cookies, sign-in, dev servers, JS-heavy apps — the same fidelity as Cursor's browser. The inline pane is deferred to its own card because it needs a per-OS vendor patch (§10.2) |
| What the tab *is* | A **launcher + record** for that window: `?view=browser&url=…`, 1:1 with a window | The tab is the strip-integrated handle; the window owns history (native engine history) so the tab needs none |
| Window chrome (address bar, back, forward, reload) | **An injected overlay bar** via `webview_init` (`webview_lib.zig:71`) + plain JS/CSS: `location.href` to navigate, `history.back/forward()`, `location.reload()`, `location.href` to display the URL. Mounted at `DOMContentLoaded` and re-mounted by a **`MutationObserver` with a hard cap of 5 remounts per document** | One code path for Linux/macOS/Windows, no vendor patch, no per-OS widget code. The bar overlays the page (it does not push content down, which would break `position:fixed` page headers) and is appended **last** so it wins equal-`z-index` ties. Deliberate wart: a page can cover or strip it — the observer makes recovery instant and the cap makes abuse bounded |
| **How the SPA starts/controls the window** | **`webview_bind` on the app's own window** — the SPA calls `window.nalarBrowser.*`; the shell runs the callback **in its own process** | `vendor/webview/webview.h:371-384`: *"Binds a function pointer to a new global JavaScript function."* `webview_bind`/`webview_return` are **already declared and unused** in our wrapper (`webview_lib.zig:73-79`). No HTTP route, no token, nothing reachable by another local process (§3.2) |
| Proxy / new backend routes | **None, in any variant.** No spawn route, no fetch-from-a-URL endpoint, no SSRF surface, no `kabelweb` use | Rev 6's option of a token-gated loopback route was dropped: the server never learns where `nalar-desktop` lives, and the token could not be secret (§3.2) |
| Schemes | `http:` / `https:` only, validated **twice** — in the frontend (`normalizeAddressInput`) and again in the shell's bridge callback before the spawn | A `javascript:`/`data:`/`file:` URL must never reach the shell or the window. The spawn uses `std.process.Child` with the URL as an **argv element** — there is no shell string anywhere, so there is no shell-injection surface to begin with |
| Search provider | **Google** — `SEARCH_URL_TEMPLATE = 'https://www.google.com/search?q='` | Reviewer's answer (Q3). Trivially safe now: the *real* Google loads in a real view (no proxy, no cookie-less fetch, no consent-interstitial risk) |
| `+` / `Shift+Alt+T` | **Blank browser tab** (address bar focused) | Reviewer's answer (Q1); unchanged from rev 2 |
| Clicking an `http(s)` URL in the app | `openExternal()` → focus a browser **tab** (creating one if needed); spawn a window **only when none is alive for that tab** | Reroutes `ChatView.onPrCreated` (`ChatView.vue:887`) and `NalarSettings.openWeb` (`NalarSettings.vue:549`). With the strip off it just opens the window |
| Tab mode off | A browser tab still works; `?view=browser&url=…` renders (the window is unaffected by the strip) | `syncFromTarget` returns early when disabled (`stores/tabs.ts:437-440`) and `currentView` is independent of the toggle |
| **Window state (pids, liveness)** | **Owned by the shell**, not by Pinia: the shell keeps the spawned `std.process.Child` handles and the tab id it spawned for | The frontend cannot read a process table, so rev 6's `isWindowAlive({pid, startedAt})` in `helpers/browserWindow.ts` was not implementable where it was specified. Owning the handle also makes liveness **exact** (non-blocking wait) instead of heuristic, and it is what makes "close the tab closes its window" possible at all |
| **Window re-use rule (reconciled)** | At most **one auto-managed window per tab**. Spawning happens on an explicit user gesture, never on mount/restore. When a window is alive the tab shows `1 window open` and the **single, always-enabled** button says **"Open another window"** — an explicit opt-in for a second view. Cross-process **raise/focus** is not attempted; that is why the primary action is never disabled (a hidden window plus a disabled button is a dead end) | Resolves the rev-5 inconsistency between "one window per tab" and edge case #7, without rev 6's disabled-primary dead end and without the "primary pid" concept |
| Session/cookie isolation | **None in v1** — the window shares the app's default WebKit data store | One user, one app: sign-in persists, which is the point. An isolated store is a follow-up (§10.4) |
| App quit with windows open | Spawned browser windows **survive** — they are independent windows, and (unlike the app) they need no `nalar` server | Predictable, and consistent with the shell's existing commitment for its own child: `attach.zig:205-209` — *"if the desktop closes, the child is NOT auto-terminated (that's the chunk 4 architectural commitment)"*. No `PR_SET_PDEATHSIG` / job-object machinery needed. The shell forgets their handles on exit, which is harmless because windows are never restored on boot |
| Not in v1 | Agent driving (screenshot/click/console), approval/allowlist UI, inline pane, downloads, favicons, per-tab zoom, cross-process window raise/focus, page-title reporting back to the tab | §10.2–§10.4 — each is its own card or a small follow-up |

### 3.1 What this removes from the repo's risk profile

No new HTTP route, no fetch-from-URL endpoint, no outbound fetcher, no cookie
forwarding, no HTML rewriting, and no untrusted HTML in our document. The spawn
boundary is a **function call inside the shell's own process**, reachable only from
the app window's JavaScript — and the only document that window ever loads is our
own SPA. The remaining new surface is "the user opened a website", the same as any
browser, plus the injected bar (tamperable by the page; worst case the user loses
the bar and closes the window).

### 3.2 The bridge contract (and its invariant)

```
SPA (app window)                         shell (nalar-desktop process)
window.nalarBrowser.open(url)      ──►   validate scheme (http/https)
                                         reject if not; else
                                         spawn selfExePath() --browser <url>
                                         keep the child handle under the tab id
                                   ◄──   { ok: true, alive: 1 }
window.nalarBrowser.status(tabId)  ──►   non-blocking wait on the handle
                                   ◄──   { alive: 0|1 }
window.nalarBrowser.close(tabId)   ──►   terminate the child (tab close path)
```

* The shell already knows its own binary: `path_resolve.selfExePath()`
  (`path_resolve.zig:133`, used at `main.zig:100,138`). This is precisely the thing
  a *server-side* route could not know.
* Spawn uses `std.process.Child` with the URL as an argv element — the same
  handle-and-terminate pattern the shell already uses for `nalar`
  (`subprocess.zig:116-152` + `:409-446`), whose signature is nalar-specific and so
  gets a generic-argv sibling for this (Task 1.6).
* Liveness = a non-blocking wait on the handle we own: `std.posix.waitpid(pid,
  W.NOHANG)` on POSIX, `WaitForSingleObject` on the child handle on Windows. This
  is the only per-OS Zig code the plan adds, and it eliminates (not just reduces)
  PID-reuse false positives.
* **Invariant — bindings go on the APP window only, never the browser window.** The
  injected bar deliberately needs no binding (`location.href` is enough), so no
  document that renders third-party content can ever call into the shell. Any
  future feature that wants a binding in the browser window must justify breaking
  this invariant explicitly (see §10.4 for the one case that is tempting, and why
  it stays out).

---

## 4. Flow

```
+ / Shift+Alt+T                     blank browser tab (?view=browser)
        │
        ▼
tab body: address bar (Google search)  ──Enter──►  normalizeAddressInput()
        │                                                 │
        │                                        http(s) only ✓
        ▼                                                 ▼
tabsStore.navigateBrowserTab(tab.id, url)      window.nalarBrowser.open(url)
        │                                                │  (webview_bind → shell)
        ▼                                                ▼
  tab target = ?view=browser&url=…              shell spawns, detached:
  tab label = host                                selfExePath() --browser <url>
        │                                                 │
        │                                                 ▼
        │                                       webview_create(0, NULL)
        │                                       + webview_init(chrome JS)
        │                                       + webview_navigate(url)
        ▼                                                 │
  tab body shows «1 window open»                          ▼
  button = "Open another window"          Nalar browser window: the page + an
                                          injected bar (URL, ←, →, ↻); links,
                                          back/forward and sign-in are native
```

There is no cross-process channel *into* the window in v1: the shell starts it and
can terminate it, the window browses on its own. The pane card (§10.2) adds the
reverse channel that would let the tab show the live URL and title.

## 5. Tasks

**Order matters:** Task 1 first — it is independently useful and testable straight
from the CLI (`nalar-desktop --browser https://example.com`) before any frontend
work exists, and it is the only shell-touching part. Then Tasks 2–3 (tab kind, then
tab body + spawning), then 4–5 (docs, gates).

### Task 1 — Shell: `--browser <url>` mode and the bridge

- [ ] **1.1** `src/apps/desktop_app/cli.zig` — add `--browser <url>` to the existing
  flag chain (`:129-195` is a flat `else if` list; add one arm) and a
  `browser_url: ?[]const u8` field to `Config`. Validate `http(s)` at parse time and
  return a CLI error otherwise (the shell must never open a `javascript:` URL).
- [ ] **1.2** `src/apps/desktop_app/main.zig` — before the attach block (`:220-310`):
  if `cfg.browser_url` is set, **skip attach/auto-spawn entirely** and call
  `webview_lib.runBrowserWindow(...)` (1.3) with that URL, then return. Reuse the
  existing `title`/window-size flags; default title = the URL's host so the OS window
  list is readable.
- [ ] **1.3** `src/apps/desktop_app/webview_lib.zig` — add `runBrowserWindow(title,
  url, w, h, devtools, x11, chrome_js)`: `webview_create(0, null)` →
  `webview_init(chrome_js)` → `webview_navigate(url)` → `webview_run`.
  `webview_init` is already declared (`:71`); `runWindow` (`:89-126`) is the shape to
  mirror. **No bindings in this window** (§3.2 invariant).
- [ ] **1.4** NEW `src/apps/desktop_app/browser_chrome.js` — the chrome bar as a
  standalone IIFE (so the shell can embed the exact bytes it ships, and a test can
  execute those same bytes):
  * a `position:fixed` bar at `top:0`, max `z-index`, appended **last** to
    `document.documentElement`, own inline styles only;
  * URL input, ←, →, ↻, and a small "▤ Nalar" label;
  * Enter → normalize (rejecting any non-http(s) scheme) then `location.href = …`;
    `history.back()`, `history.forward()`, `location.reload()`;
  * the input is filled from `location.href` on every load;
  * mount on `DOMContentLoaded`; a `MutationObserver` on `documentElement`
    (childList, debounced) re-mounts it if the page removes it, **with a hard cap of
    5 remounts per document**, after which the observer is disconnected;
  * **no inline `<script>` tag and no `eval`** — so a page's `script-src` cannot
    block it and there is nothing to inject.
- [ ] **1.5** Embed 1.4 with `@embedFile("browser_chrome.js")` in the file that needs it.
  This works because the desktop module's root **is** `src/apps/desktop_app/`
  (`build.zig:1672-1675`), so the `.js` sits inside the module tree — unlike the
  webapp assets, which need the generated `embedded/webapp_assets.zig` table
  (`tools/codegen_webapp_assets.zig`) precisely *because* `dist/` lives outside the
  module root. A hand-written sibling `.js` is therefore the simpler choice here, and
  it keeps the chrome readable in diffs instead of embedded in generated Zig.
- [ ] **1.6** NEW `src/apps/desktop_app/browser_bridge.zig` — the SPA↔shell bridge:
  * `installBindings(w, state)`: `webview_bind` `nalarBrowser.open`, `.status`,
    `.close` on the **app** window before `webview_run` (wired in `runWindow`);
  * each callback parses the JSON request array (`webview.h:371-384` documents the
    `req` shape), validates a `http(s)` URL where relevant, acts, and answers with
    `webview_return(id, 0, result_json)` — including on rejection;
  * `open`: spawn of `path_resolve.selfExePath()` with `--browser <url>` **as an argv
    element**. The generic-argv variant is new — the existing helper is
    nalar-specific (`subprocess.zig:409-446`, `spawn(allocator, io, nalar_path, port,
    static_dir)`) — so add a small `BrowserProcess` alongside `NalarProcess`
    (`subprocess.zig:116-152`, which already models the handle + `terminate()` pattern
    to copy) using `std.process.spawn(io, …)`; the handle is stored under the tab id;
  * `status`: non-blocking wait on the stored handle (per-OS helper, §3.2);
  * `close`: terminate the stored child (no-op if already gone).
- [ ] **1.7** Inline Zig tests — CLI: `--browser` with no value → error; a non-http
  scheme → error; a valid URL parses alongside the existing flags. Bridge: a
  `javascript:`/`file:` request is rejected **without spawning**; `open` with a
  valid URL records a handle under the tab id; `status` for an unknown tab id is
  `{alive: 0}` (never an error); `close` on an unknown tab id is a no-op; the
  installed binding names are exactly the three above (the vendored API's
  `WEBVIEW_ERROR_DUPLICATE` means a second bind of the same name fails, so the
  install path must be idempotent).

**Acceptance:** `./zig-out/bin/nalar-desktop --browser https://example.com` opens a
window showing example.com with a working bar (Enter, ←, →, ↻); `--browser
javascript:alert(1)` exits with a CLI error and opens nothing; a page that strips the
bar gets it back within a frame, and after 5 strips the observer gives up (0% idle
CPU — asserted by 5.1); the app window exposes exactly
`nalarBrowser.open/status/close` and the browser window exposes none.

### Task 2 — Frontend: the `browser` tab kind

- [ ] **2.1** `helpers/tabTarget.ts` — add `'browser'` to `TabKind` (`:26`); key
  `browser:<url>` / `browser:new` in `tabKeyOf` (`:160-187`); `kindOf` (`:251-260`);
  `fallbackTitle` (`:262-278` → `'New tab'`); `asKind` allowlist (`:353-357`);
  NEW `browserTab(url?)` next to `homeTab()` (`:328-342`).
- [ ] **2.2** NEW `helpers/browserUrl.ts` — pure: `isHttpUrl`,
  `normalizeAddressInput(raw)` (absolute http(s) passes through; a bare host gains
  `https://`; anything else → `SEARCH_URL_TEMPLATE`; explicit non-http schemes are
  refused with a reason, never searched), `hostOf`, `browserTabTitle(url)`.
  Re-export from `helpers/index.ts`.
- [ ] **2.3** `stores/tabs.ts` — `openBrowserTab(url?)`
  (`open({ path: '/app', query: { view: 'browser', …(url ? { url } : {}) }, kind:
  'browser', … })`, deduping by URL key per edge case #1) and
  `navigateBrowserTab(tabId, url)` (rewrite `query.url`, `rekeyTab`, persist — no
  router call; the caller re-applies via `applyActiveTabToUrl`). **No window/pids in
  the store** (§3: the shell owns them) and **no history storage** (the engine owns
  history). Closing a browser tab calls `nalarBrowser.close(tabId)`.
- [ ] **2.4** `components/shell/TabBar.vue` — `GLYPHS.browser = '🌐'` (the exhaustive
  `Record<TabKind, string>` at `:38-45`); `titleOf` (`:73-99`) → `hostOf(url)`, else
  `New tab`; `newTab()` (`:143-146`) → `openBrowserTab()`.
- [ ] **2.5** `components/AppLayout.vue` — `v-else-if="currentView === 'browser'"`
  branch for `BrowserTabView` in the existing chain, first (before
  `KanbanSettingsView`, `:2526`); `currentView` needs **no** new branch (it falls
  through to `route.query.view`, `:946-948`); import statically like
  `KanbanView`/`DesignView`.
- [ ] **2.6** `composables/useCurrentMainView.ts:38-52` — `{ kind: 'browser'; url?: string }`
  + the `view === 'browser'` branch (sidebar active-state).
- [ ] **2.7** Tests — `tabTarget.spec.ts` (key/kind/title/`asKind` round-trip through
  `parseTabList`), `tabsStore.spec.ts` (open/dedupe by URL/navigate re-keys in
  place/`close` asks the bridge/`TABS_VERSION` stays `1`), `TabBar.spec.ts` (glyph,
  host title, blank label, `+` opens a browser tab — the deliberate flip of
  `TabBar.spec.ts:260`), `AppLayout.tabs.spec.ts` (deep link creates one browser tab
  beside the boot home tab and renders the view; two tabs do not shadow each other;
  tabs-off still renders).

**Acceptance:** `pnpm exec vitest run tabTarget.spec.ts tabsStore.spec.ts
TabBar.spec.ts AppLayout.tabs.spec.ts` green; a pre-feature `localStorage` payload
still loads its tabs.

### Task 3 — Frontend: the tab body and the bridge client

- [ ] **3.1** NEW `helpers/browserBridge.ts` — a thin, typed wrapper over the bound
  globals with an explicit **absent-bridge** path: `openBrowserWindow(url)`,
  `browserStatus(tabId)`, `closeBrowserWindow(tabId)`. If `window.nalarBrowser` is
  undefined (vitest, a plain-browser dev session at 5173, or an older shell), every
  call resolves to a documented "unavailable" result and the UI degrades to
  "Open in system browser" instead of throwing. **This is the seam the tests stub.**
- [ ] **3.2** NEW `components/browser/BrowserTabView.vue`:
  * **blank** (`url` absent): address bar (`data-testid="browser-address"`) +
    "Search or enter address" hint + Open; Enter → `normalizeAddressInput` →
    `navigateBrowserTab` → `openBrowserWindow(url)`. A refused scheme shows an inline
    error under the bar, and nothing spawns.
  * **with a url**: read-only URL row + Copy; **one always-enabled primary button**
    whose label follows the shell's status — `Open browser window` (nothing alive) /
    `Open another window` (one alive) (`data-testid="browser-open-window"`); a status
    line `1 window open` / `no window open`; "Open in system browser". No disabled
    primary (§3, window re-use rule). Recent history is **not** stored.
  * Status is fetched **on demand** (when the view mounts/activates or after an
    action) — no background polling (§7).
- [ ] **3.3** `helpers/openExternal.ts` — `http(s)` → focus/create the browser tab and
  call `openBrowserWindow` **only if the tab has no live window**; anything else →
  `window.open(url, '_blank', 'noopener')` unchanged. Reroute `ChatView.vue:887` and
  `NalarSettings.vue:549`; leave `PreviewContentRenderer.vue:210` on the `blob:` path
  (documented).
- [ ] **3.4** Tests — `browserBridge.spec.ts` (a stubbed bridge: payload shape, the
  absent-bridge degradation, no throw), `BrowserTabView.spec.ts` (blank Enter opens;
  scheme refusal; the button label follows the status; a repeat click with a live
  window does not auto-spawn twice; no window on mount; the status line), and
  `openExternal.spec.ts` (http(s) vs `blob:`/`javascript:`; strip on/off; no second
  window on a repeat click). NEW `browserChrome.spec.ts` (jsdom, §5.1 below).

### Task 4 — Documentation

- [ ] **4.1** `docs/tabs.md` — the `browser` kind and its key shape (`:107-134`); the
  label rule (`:141-163`); the gestures table (`:14-25`) with the new `+` meaning;
  "Turning it off" (`:194-205`) → a browser tab still opens its window; the Files
  table (`:221-235`); the window re-use rule (one auto-managed window per tab,
  "Open another window" as the explicit escape hatch).
- [ ] **4.2** `docs/SPEC.md` — `§3.7.12 In-app browser tab`: the window architecture,
  the one-view-per-window constraint from §2 (with the `webview.h` line numbers), the
  injected bar and its wart (bounded remount), the `--browser` flag, **the
  `webview_bind` bridge and the "bindings in the app window only" invariant**, and
  `**Plan:** docs/superpowers/plans/2026-09-14-in-app-browser-tab.md`; plus a PR index
  row (`:919+`). Append, never rewrite history.
- [ ] **4.3** Append `## Implementation status` to this plan when it lands.

### Task 5 — Gates

- [ ] **5.1** NEW `src/apps/desktop/src/__tests__/browserChrome.spec.ts` — the bar
  tested **behaviourally in jsdom** against the exact bytes the shell embeds
  (`readFileSync` the same `browser_chrome.js` and execute it; no source greps). Cases:
  the bar mounts on `DOMContentLoaded`; it is appended last and carries the max
  `z-index`; a page that removes it gets it back; **after 5 removals it stays gone and
  no further remount happens** (the cap + observer disconnect); the input shows
  `location.href`; Enter on a `javascript:` value does not navigate; Enter on
  `example.com` normalizes to `https://…`; ←/→/↻ call the history/reload paths.
- [ ] **5.2** `zig build test --summary all` (new inline tests included);
  `pnpm --dir src/apps/desktop test` compared against the baseline recorded **before**
  Task 1 (this repo carries pre-existing failures; a new red test must be new);
  `pnpm --dir src/apps/desktop run build` and `run lint:check` clean.
- [ ] **5.3** Cross-platform build proof: `zig build-obj -fno-emit-bin -target
  x86_64-windows-gnu -lc …` and `… -target aarch64-macos -lc …` on the touched shell
  modules. The chrome bar is a `.js` asset and the bridge is one API call, so the only
  per-OS Zig code is the non-blocking wait in 1.6.
- [ ] **5.4** `tests/functional/`: assert the CLI rejects a non-http scheme and that
  `--browser` **does not start a server** (the harness boots a server by design, so use
  the desktop smoke-script precedent — `scripts/desktop-autospawn-smoke.sh`). No new
  HTTP route means no new wire test is required, which is itself an assertion worth
  writing in the PR description.

---

## 6. Edge cases (each needs a test)

| # | Case | Expected | Covered by |
|---|---|---|---|
| 1 | Same URL twice | The existing tab is focused (key dedupe — documented deviation from Chrome); no second window spawns as a side effect | 2.7, 3.4 |
| 2 | Blank `+` twice | The one blank browser tab is focused | 2.7 |
| 3 | `javascript:` / `data:` / `file:` typed | Inline error, nothing opens, **no spawn** — and the shell rejects it too if it ever arrives | 2.2, 1.7, 3.4 |
| 4 | App restart with browser tabs | Tabs restored, **no** windows opened until the user asks | 3.1, 3.4 |
| 5 | Window closed from the OS, tab still open | Status reads `no window open` (exact: we hold the handle); the button says `Open browser window` and re-opens the same URL | 1.6, 3.2, 3.4 |
| 6 | Closing the tab | Its window is closed too (1:1 lifetime) — possible **only** because the shell holds the handle | 1.6, 2.3 |
| 7 | Activating a browser tab whose window is alive | No second window; the tab shows `1 window open` and the label becomes `Open another window` (explicit opt-in, one click) | 3.2 |
| 8 | Clicking the same link twice from chat/Settings | One window; the second click only focuses the tab | 1.6, 3.3, 3.4 |
| 9 | Google search from the omnibox | A **real** Google page in the window | manual §9 |
| 10 | GitHub: repo, sign-in | Works — real top-level view, no `X-Frame-Options` involvement, cookies persist | manual §9 |
| 11 | A site that refuses framing (`x-frame-options: deny`) | Irrelevant now — it is not in a frame | manual §9 |
| 12 | `localhost:<port>` dev server | Works, and sends no framing headers anyway | manual §9 |
| 13 | A page with a full-screen overlay, or one that repeatedly strips the bar | May cover it; stripping is recovered by the observer and stops after 5 attempts; documented; the OS close button always works | 1.4, 5.1 |
| 14 | A page whose CSP is strict | The bar still works (injected styles + DOM APIs, no inline `<script>`, no `eval`) | 5.1 |
| 15 | Two browser tabs, two windows | Independent histories and cookies (same store, different windows) | manual §9 |
| 16 | Very long URL | The bar's input scrolls; the tab shows the host | 3.2 |
| 17 | Tab mode off | `openExternal` opens the window directly (same re-use rule); a `?view=browser` URL still renders the tab body | 3.3, 2.7 |
| 18 | 50-tab cap | Oldest non-active evicted; the active browser tab never evicted (existing `enforceLimit`) | 2.7 |
| 19 | `?tab=` (strip) vs `?tab=` (kanban settings) | Unchanged: `migrateLegacySettingsTab` (`tabTarget.ts:297-318`) disambiguates by path | 2.7 |
| 20 | A page loaded **in the browser window** tries to call `nalarBrowser.*` | Undefined — the browser window carries **no** bindings (§3.2 invariant), so untrusted content has no door into the shell | 1.3, 1.7 |
| 21 | Another local process tries to open a browser window | No route, no port, no socket to reach — the only trigger is a call inside our own SPA's document | §3.1, §3.2 |
| 22 | Bridge absent (vitest, a plain-browser dev session, or an older shell) | Calls resolve to "unavailable"; the UI offers "Open in system browser"; nothing throws | 3.1, 3.4 |
| 23 | The `nalar` server is stopped, or was never started | The browser window still opens and browses (it needs no server); the tab body still renders | manual §9 |
| 24 | App quits with browser windows open | The windows stay; nothing is restored or re-spawned on the next launch | 1.6, manual §9 |
| 25 | PID reuse by an unrelated process | Impossible to observe as "alive": we never look up a pid, we hold the child handle and wait on it | 1.6 |
| 26 | A page navigates the window itself (link, JS) | Normal browsing; the tab keeps its original URL/host label (no reverse channel in v1 — §10.4) | manual §9 |

---

## 7. Risks

| Risk | Impact | Mitigation |
|---|---|---|
| The injected bar is in the page's document | A page can cover, remove, or repeatedly strip it | Documented; the OS close control always works; removal is recovered by a `MutationObserver` and capped at 5 remounts, so a hostile page costs a bounded amount of work and **zero idle CPU**; a native bar is the pane card's job |
| A new cross-process call surface (the bridge) | If mis-scoped, untrusted content could drive the shell | The bindings live **only** in the app window, whose only document is our SPA; the browser window has none (§3.2). Every callback validates its input (scheme allowlist) and answers on the rejection path too |
| No route at all means no *network* trigger | — (this is the mitigation, recorded so nobody "fixes" it back) | Rev 6's loopback route was dropped after finding it could neither locate `nalar-desktop` nor keep its token secret (§3.3 in rev 6; §3.2 here). If a future feature genuinely needs a network trigger, it needs its own security design, not this plan's leftover |
| Unbounded polling anywhere in or around the browser window becomes an idle-CPU bug — a recurring failure mode of WebView2/WebKitGTK/Cocoa embeds | Battery/fan complaints, "why is this app hot" | Remount is observer-driven with a cap (1.4); bridge `status` is **on demand** (view mount/activation or after an action), never a background poll; no `setInterval` is introduced anywhere in this plan |
| Spawning a child process from the shell | Process-management bugs (zombies, orphans) | The existing handle + `terminate()` pattern is reused (`subprocess.zig:116-152`), with a generic-argv spawn (`:409-446` is nalar-specific); the handle is kept and reaped on the non-blocking wait; "survives app quit" is the deliberate, documented rule (decision table), matching the shell's existing commitment at `attach.zig:205-209` |
| WebView2 / WebKitGTK / WKWebView differences in init-script timing | Bar missing on one platform | Mount at `DOMContentLoaded` + observer retry (capped); manual check per OS in §9; the bar needs no engine API beyond `webview_init`/DOM |
| Cookie-store location differences per OS (WebView2 needs a writable user-data folder) | Sign-in silently not persisting on one OS | The window reuses whatever the app window already uses, which the app's own webview proves is writable; §9 verifies persistence explicitly on all three |
| Sandboxing/entitlements | macOS may need an entitlement for outbound network | The app already loads `http://127.0.0.1`; outbound networking is a §9 check, not expected to need code |
| Two address bars (tab body + window bar) feels redundant | Mild UX wart | The tab body is a launcher/record, the window owns browsing; the pane card removes the redundancy |
| Users expect the page *inside* the tab, or expect Cursor's *agent*-driven browser | Disappointment / scope confusion | The Goal's non-goal note is explicit; §10.2 and §10.3 record both follow-ups as their own cards |
| Cross-process window raise/focus is not attempted | A live window can be behind others while the tab says it is open | The primary action is **never disabled** and its label makes the state explicit (`Open another window`), so the user always has a working next step; §10.4 records raise/focus as a possible follow-up |

---

## 8. Rollback

* Feature-additive: one CLI flag, one Zig file (bridge), one embedded `.js` asset, one
  tab kind, one component. `git revert` restores today's behaviour; nothing else reads
  the new flag, and nothing else calls the new bindings.
* No storage migration: `TABS_VERSION` stays `1`; a restored `?view=browser` tab
  renders nothing after a revert (an unknown `view` already renders empty today) and
  Settings → General → tabs off/on rebuilds a clean list (`resetToHome`,
  `stores/tabs.ts:585-593`).
* The window is a separate process and the bridge degrades gracefully (§6 #22): a
  reverted shell leaves a tab body that offers "Open in system browser" rather than a
  broken button.

---

## 9. Verification (manual, after implementation)

Backend on **8080** (never 8081); UI via `pnpm --dir src/apps/desktop dev` (5173) with
`VITE_API_PROXY_TARGET=http://localhost:8080`:

The bridge has its own repeatable check that needs no UI:
`python3 scripts/browser-bridge-probe.py` boots the real engine in connect mode
against a probe page and asserts open → alive → close → gone (needs a display;
exit 3 = skipped). Run it after touching `browser_bridge.zig`, and on each new
platform.

- [ ] `+` → blank browser tab, address bar focused, tab labelled `New tab` / 🌐.
- [ ] Type `github.com` → a **Nalar window** opens on GitHub; the bar shows the URL;
  a link inside works; ← returns; ↻ reloads; **sign in to GitHub** and confirm the
  session survives closing and re-opening the window.
- [ ] Type `zig lang` → Google results in the window; search again from the window's
  own bar.
- [ ] Type `localhost:5173` (or any dev server) → renders.
- [ ] Confirm the cookie store persists per OS (Linux, macOS, Windows) — the
  session-persistence claim is the one thing a single-platform check cannot prove.
- [ ] A page with a full-screen overlay, and one that strips injected nodes: the bar's
  worst case is bounded (5 attempts, then idle with 0% CPU), not a crash.
- [ ] `javascript:alert(1)` in the tab body → inline error, **no window**.
- [ ] Close the window from the OS → status flips to `no window open`; one click
  re-opens the same URL. Close the tab → its window closes.
- [ ] Click the same link twice from chat/Settings → exactly **one** window; the label
  becomes `Open another window`, and clicking it does open a second one.
- [ ] In the browser window's devtools (`--devtools`), evaluate `window.nalarBrowser`
  → `undefined` (invariant, §3.2). In the app window → the three functions exist.
- [ ] Stop `nalar`, then open a browser tab → the window still opens and browses.
- [ ] Quit the app with a browser window open → the window stays; relaunch → the tab
  is restored and **no** window pops up.
- [ ] Create a PR from a chat, and Settings → "Open web" → both land in a browser tab
  + Nalar window.
- [ ] Tabs off → `openExternal` still opens the window; `?view=browser&url=…` still
  renders the tab body.
- [ ] Repeat the window checks on macOS and Windows (the bar and the non-blocking
  wait are the only platform-sensitive parts).

### Reviewer answers (all locked 2026-09-14)

| # | Question | Answer |
|---|---|---|
| Q1 | `+` = blank browser tab, or keep it for the chats list? | **Blank browser tab** |
| Q2 | Drop the framing-hostile fallback, or keep it so GitHub/Google open? | **Keep real browsing power** — delivered the *right* way since rev 4 (a real webview, so no proxy is needed) |
| Q3 | Search provider? | **Google** |
| Q6 | Cursor's "separate window" mode, or jump straight to the inline pane? | **Separate window** |

**Q6 is the shape of v1:** `nalar-desktop --browser <url>` opens the page in a
Nalar-owned webview window, and the browser tab is its launcher and record. The
**inline pane** — the page inside the app window, which "open a new tab, but literally
a browser" arguably means most literally — is **not** a v1 option; it is the next card
(§10.2), because it needs the vendored container patched per OS. The tab-kind work
(Task 2) is unchanged by that future step.

---

## 10. What rev 4 deleted, and the follow-up cards

### 10.1 Deleted (revs 1–3), with the evidence that it was only ever an iframe tax

An iframe cannot host `github.com` or `google.com` — measured 2026-09-14:

```
curl -sI https://github.com/        → x-frame-options: deny
                                      content-security-policy: … frame-ancestors 'none' …
curl -sI https://www.google.com/    → x-frame-options: SAMEORIGIN
curl -sI https://example.com/       → (none)
curl -sI https://docs.python.org/3/ → (none)
```

`X-Frame-Options` / `frame-ancestors` are enforced by our own engine for **nested**
contexts, with no JS or config bypass — a real Chrome fails the same way. Every piece
below existed only to work around that, and all of it goes when the page gets a
top-level view:

* `GET /api/browser/page` (libcurl proxy), the `frameable` preflight,
  `frame-ancestors` evaluation, the SSRF guard and its private-range blocklist;
* base-href injection, title extraction, the 2 MiB cap, the 415 gate;
* the `postMessage` navigation relay, `target="_blank"` handling, GET/POST form
  relay, `resolveGetFormTarget`;
* the iframe sandbox asymmetry (`allow-same-origin` only with a remote `src`);
* the per-tab history store and its separate `nalar-browser-history:v1:<windowId>`
  localStorage key (the engine owns history now);
* the "limited view" badge and the system-browser escape hatch as the primary path.

### 10.2 Follow-up card 1 — the inline pane (the literal "browser tab", deferred by Q6)

The page rendered **inside** the app window, next to the strip: patch the vendored
container so a second view can live in the same window — Linux: wrap the window's
child in a `GtkBox` and append (`webview.h:1721-1725,1885`); macOS: `addSubview:`
instead of `setContentView:` (`:2632`); Windows: parent the second `WebView2`
controller to a child HWND (`:3617`). Then a JS↔Zig bridge for
create/close/activate/**geometry** (the pane's rectangle, reported by the SPA), a
non-blocking shell loop, and a decision about the Vue strip becoming shell-drawn.
Note that rev 7 already builds the SPA→shell half of that bridge (`webview_bind`,
§3.2), so this card inherits a working call path. Multi-week, per-OS — its own card.

### 10.3 Follow-up card 2 — agent driving (Cursor's actual headline)

Cursor's browser is *agent*-controlled; ours would be too, and we already have both
halves: the `agent-browser` CLI (used by the repo's web tool today) and the in-tree
`src/modules/nalar_browser/` Bun service (`/launch`, `/page`, `/snapshot`, `/click`,
`/fill`, `/press`). A card would wire snapshot/click/screenshot/console into the
browser view plus Cursor's approval + allow/deny-list gating. Note that the Bun service
is optional, out of CI, and unwired (`rg nalar_browser` → 6 hits, all docs), so this is
real integration work, not a lookup. **This is the piece that would make the feature
actually match Cursor's browser rather than just its window primitive.**

### 10.4 Small follow-ups (each one line of justification)

1. **Live URL + page title back to the tab** — needs a reverse channel from the
   browser window to the shell. The tempting shortcut is a binding in the *browser*
   window (a page could then call it), which breaks the §3.2 invariant. Options when
   it matters: a status file the window writes via a tightly-scoped binding, or the
   pane's real bridge. Deliberately out of v1: the tab label is the host.
2. **Cross-process window raise/focus** — OS-specific (`wmctrl`/accessibility APIs);
   v1 makes the state explicit instead.
3. **Downloads** — needs a shell-level download handler (none exists).
4. **Isolated per-workspace cookie store** — today the window shares the app's store.
5. **Favicons** in the strip.
6. **Download/print/zoom controls** in the injected bar.

---

## Implementation status

**Shipped.** `+` (and `Shift+Alt+T`) opens a blank browser tab; an address or a
search term in it opens the page in a real **Nalar-owned webview window**
(`nalar-desktop --browser <url>`) with an injected address/←/→/↻ bar; the tab is
the launcher and record, the window owns history and cookies. The SPA reaches
the shell through `webview_bind` — no HTTP route, no port, no token.

**PR:** [#489](https://github.com/ginwa123/ginwaaitoolbox/pull/489) (branch
`worktree/task-1789376475404`, base `main` @ `b7c2d39e`).

| Plan task | Status | Notes |
|---|---|---|
| 1 — shell: `--browser`, `runBrowserWindow`, chrome bar, bridge | ✅ | `cli.zig` (`browser_url`, http(s)-only at parse time), `main.zig` (browser branch returns before attach/extraction), `webview_lib.zig` (`runBrowserWindow` + the bridge installed in `runWindow`), NEW `browser_bridge.zig`, NEW `browser_chrome.js` (`@embedFile`) |
| 2 — frontend: the `browser` tab kind | ✅ | `tabTarget.ts` (`browser` kind, `browser:new`/`browser:<url>` keys, `browserTab()`), NEW `browserUrl.ts`, `stores/tabs.ts` (`openBrowserTab`, `navigateBrowserTab`, close→bridge), `TabBar.vue` (🌐, host label, `+`), `AppLayout.vue` (view branch + `Shift+Alt+T`), `useCurrentMainView.ts` |
| 3 — frontend: tab body + bridge client | ✅ | NEW `browserBridge.ts`, NEW `components/browser/BrowserTabView.vue`, NEW `openExternal.ts` (+ the `ChatView`/`NalarSettings` reroutes; `PreviewContentRenderer` deliberately left on `blob:` + documented) |
| 4 — docs | ✅ | `docs/tabs.md` (gestures, shortcuts, identity, labels, "The browser window", turning-it-off, Files, tests), `docs/SPEC.md` §3.7.12 + a §10.1 PR-index row, this section |
| 5 — gates | ✅ | See "Gates" below |

### Deviations from the plan

1. **`open` takes the tab id first: `nalarBrowser.open(tabId, url)`.** §3.2's
   sketch showed `open(url)`, but §1.6 requires the handle to be *stored under
   the tab id* — and `status(tabId)`/`close(tabId)` can only find it if `open`
   was told the id. The TS wrapper mirrors it (`openBrowserWindow(tabId, url)`).
2. **The chrome-bar removal budget is the §5.1 reading, not the §3 wording.**
   §3 said "a hard cap of 5 remounts"; §5.1's test case said "after 5 removals it
   stays gone". Implemented as: **5 removals are tolerated** (each of the first
   four is recovered by the observer) and the **5th is final** — the observer
   disconnects and the bar stays gone. `MAX_REMOVALS = 5` in the asset; asserted
   in `browserChrome.spec.ts`. The off-by-one between the two sentences is
   resolved in favour of the test case, and the property that matters (bounded
   work, no timers, 0% idle CPU, observer disconnect) holds either way.
3. **`helpers/openExternal.ts` did not exist.** Tasks 2–3 assumed it; the three
   call sites were raw `window.open(...)`. It was created, and the two that
   open an `http(s)` URL were rerouted; the `blob:` one was left alone (with a
   comment pointing at the decision table).
4. **The chrome asset is embedded in `webview_lib.zig`, not passed from
   `main.zig`.** §1.3 listed `chrome_js` as a parameter; §1.5 said "embed it in
   the file that needs it" — that file is the one calling `webview_init`, so the
   parameter would only have been threaded through `main.zig` to be handed
   straight back. Same bytes, one less seam. `@embedFile("browser_chrome.js")`.
5. **The tab body re-applies its URL by emitting `navigate`** (wired in
   `AppLayout` to `applyActiveTabToUrl`, exactly like `TabBar`) rather than
   calling the router itself — the store still makes no router call (§2.3).
   `openExternal` is the one exception: it is called from non-component code
   (a click handler in `ChatView`/`NalarSettings`), so it uses the router
   singleton; with tab mode off it uses the fixed bridge id `external`.
6. **Windows `WAIT_0` is a decl, not an enum field** (`NTSTATUS.WAIT_0 =
   .SUCCESS`), so the probe spells the path out. Caught by the new cross-compile
   hook — i.e. by the gate this plan added in 5.3, before any Windows runner saw
   it.
7. **A semicolon-joined template expression is a trap.** The repo's post-edit
   prettier hook split `@click="closeTab(id); closeMenu()"` across three lines,
   which the Vue compiler cannot parse (it rejected four spec files). It is now
   a `closeTabFromMenu(id)` call. Worth knowing for any future edit to a
   template attribute with `;` in it.

### Post-review fix (2026-09-14, from the human's manual check)

**Symptom.** In the running desktop app a browser tab rendered, but
"Open browser window" did nothing at all — no window, no error.

**Cause.** The shell bound `"nalarBrowser.open"` / `".status"` / `".close"`.
The vendored glue (`vendor/webview/webview.h`, `Webview_.prototype.onBind`)
does `window[name] = …` with the name **verbatim** — there is no namespace
walking — so it created `window["nalarBrowser.open"]` and left
`window.nalarBrowser` **undefined**. The shell was wired; the SPA could not see
it, correctly reported "unavailable", and the primary button was a silent no-op.
A live probe in the real engine confirms the shape: `flat_bindings=true
object_shape=undefined`.

**Fix (two parts).**

1. The three bindings are now flat identifiers — `nalarBrowserOpen`,
   `nalarBrowserStatus`, `nalarBrowserClose` — which is the only spelling the
   glue can expose as a property of `window`. `helpers/browserBridge.ts` is the
   single seam and composes the object-shaped API from them (accepting either
   spelling), so the rest of the frontend is unchanged.
2. **No silent no-op.** When there is no bridge at all (a plain-browser dev
   session, an older shell), the primary button says and does "Open in system
   browser", an inline line explains why, and a blank tab's Enter hands the
   address to the system browser instead of navigating and doing nothing.

**Tests that lock it** (all of which fail against the shipped code):
`__tests__/webviewBindGlue.spec.ts` extracts the REAL glue out of
`vendor/webview/webview.h`, executes it, and asserts (a) a flat name becomes
`window.<name>`, (b) a dotted name stays a flat property and leaves
`window.nalarBrowser` undefined, (c) the posted request is
`{id, method, params:[tabId,url]}` — exactly what `parseParams` reads — and
(d) the Zig source binds exactly three flat names. Plus
`browserBridge.spec.ts` (flat globals, and a half-installed shell reads as
absent) and `BrowserTabView.spec.ts` (the fallback + the hint).

**Live end-to-end gate** (new, needs a display — not a CI gate):
`python3 scripts/browser-bridge-probe.py` runs the real engine in connect mode
against a probe page that calls the three globals exactly as the SPA does.
Recorded result:

```
flat_bindings=true object_shape=undefined
open={"ok":true,"alive":1}
status={"alive":1}
close={"ok":true}
status_after_close={"alive":0}
PASS
```

**Lesson worth keeping:** a binding whose name the JS glue cannot expose is not
caught by a signature test, a unit test on either side, or a source grep — only
by executing the glue or the engine. That is why (a) the glue spec exists and (b)
the "bridge absent" path now has a visible, working fallback instead of a
silent one.

### Gates

* `zig build test:desktop-app --summary all` — **62/62 pass** (was 56; the new
  `browser_bridge.zig` suite + `cli_test.zig`'s `--browser`/`isHttpUrl`/`hostOf`
  cases + the two `webview_lib.zig` static contracts).
* `zig build check:desktop-cross --summary all` — **4/4**: the bridge's per-OS
  liveness probe compiles for **x86_64-windows-gnu, aarch64-macos and
  x86_64-linux**. This gate is what caught deviation 6.
* `pnpm --dir src/apps/desktop exec vitest run` — **373 files / 3310 tests:
  4 failed, 3306 passed.** The 4 failures are exactly the pre-existing set
  recorded *before* any edit (4 failed / 3247 passed of 3251): 
  `FilePickerDialog.windows`, `WorkspaceItemHideTasksForDesign`,
  `workspacesStoreNormalizeTaskDates`, `workspacesStoreNormalizeTaskImageUrls`.
  **+59 new passes, 0 regressions.**
* `pnpm --dir src/apps/desktop run build` (vite + `vue-tsc`) — green;
  `run lint:check` (oxlint + eslint) — **0 errors, 0 warnings**.
* `pytest tests/functional/desktop_browser_flag_test.py` — 1 passed (the static
  contract: the `--browser` branch precedes `attach.resolveAttachTarget(`, so
  browser mode cannot start a server) / 4 skipped (no `nalar-desktop` binary in
  that environment; the suite skips by design). No new HTTP route means no new
  wire test — which is itself the assertion.
* **Not verifiable here, left for the human 9-item manual checklist:** the
  three-OS sign-in/session-persistence check, a real Google/GitHub page, a dev
  server, and the OS-driven window close. Everything in §9 that needs a display
  or a second platform.

### Follow-ups (unchanged from §10)

The inline pane (§10.2), agent-driven control (§10.3) and the six small
follow-ups (§10.4) remain their own cards. §10.4's "live URL + title back to the
tab" is the one a reviewer will want next: it needs a reverse channel, and the
tempting shortcut (a binding inside the *browser* window) is exactly what the
§3.2 invariant forbids.

