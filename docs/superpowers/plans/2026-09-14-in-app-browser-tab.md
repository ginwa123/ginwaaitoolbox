# In-app browser tab — simplified (Cursor-shaped)

> **Status: PLAN ONLY — not executed.** Rev 5 (2026-09-14). Rev 4 simplified the
> design to Cursor's model at the reviewer's request — *"i think we need to
> simplify the in app browser, maybe we can mirror this"*,
> <https://cursor.com/docs/agent/tools/browser> — and rev 5 locks the reviewer's
> final answer (**Q6 → separate-window mode**). Every question in this plan is now
> answered; it is implementation-ready and awaiting the go-ahead at
> `in_review_planning`.
>
> **Plan PR:** #489, branch `worktree/task-1789376475404` (revs 1–3 are kept in the
> branch history; §10 records what rev 4 removed and why).
>
> **For agentic workers:** this is a *planning* artefact. Before implementing, use
> subagent-driven-development / executing-plans. Steps use checkbox (`- [ ]`)
> syntax for tracking.

**Task:** `task_1789376526556_0` — *"in browser app is a feature to open a new tab,
but literally a browser"*.

**Goal:** `+` opens a browser tab; type `github.com` or a Google search; the page
opens **in a real webview — a Nalar-owned window, Q6 locked** — where links, sign-in
and dev servers work, with a new Zig work path that is one CLI flag and one injected
chrome bar, and **no proxy, no iframe, no SSRF surface, no frame-policy matrix.**

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
| Navigate anywhere (any site, links, back/forward, refresh) | The page is a **real top-level webview inside Electron** — no `X-Frame-Options` problem exists | ✔ A real webview in a Nalar-owned window | in-window pane (§10) |
| Session persistence (cookies / localStorage / IndexedDB) | A real browser context with a persistent store | ✔ the engine's default store, already persistent (`webview.h:1870` uses `webkit_web_view_new()` → the default context) | isolated per-workspace store |
| "separate window **or** inline pane" | Electron can parent a `WebContentsView` anywhere | ✔ **separate window** — **locked by the reviewer (Q6)** | inline pane (the expensive half — §10.2) |
| Screenshot / console / network / click / type — agent-driven | An MCP server + approval modes + allow/deny lists | ✖ not in v1: the tab is *user*-driven | §10 — our `agent-browser` CLI and the in-tree `nalar_browser` Bun service already do snapshot/click/fill/press |
| Security: approval per action, allow/block lists, origin allowlist | Agent actions need gating | ✖ nothing to gate: no agent control in v1 | §10 |
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
   (§10), not a v1 thing.
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
| Window chrome (address bar, back, forward, reload) | **An injected overlay bar** via `webview_init` (`webview_lib.zig:71`) + plain JS/CSS: `location.href` to navigate, `history.back/forward()`, `location.reload()`, `location.href` to display the URL | One code path for Linux/macOS/Windows, ~120 lines, no vendor patch, no per-OS widget code. Deliberate wart: the bar lives in the page document, so a page can cover or hide it (documented in §6/§7); a *native* bar is the inline-pane card's job |
| Renderer alternatives | **Deleted from this plan**: iframe, `X-Frame-Options` preflight, Zig proxy, SSRF guard, srcdoc base injection, `postMessage` nav relay, GET-form relay, per-tab history storage, sandbox asymmetry | All of it existed only to work around being inside an iframe (§10 keeps the measured evidence) |
| Proxy / new backend routes | **None.** No new HTTP route, no fetch-from-a-URL endpoint, no SSRF surface, no `kabelweb` use | The browser window fetches the page itself, like any browser |
| Schemes | `http:` / `https:` only, validated **twice** — in the frontend (`normalizeAddressInput`) and in the CLI flag | A `javascript:`/`data:`/`file:` URL must never reach the shell or the window |
| Search provider | **Google** — `SEARCH_URL_TEMPLATE = 'https://www.google.com/search?q='` | Reviewer's answer (Q3). Now trivially safe: the *real* Google loads in a real view (no proxy, no cookie-less fetch, no consent-interstitial risk) |
| `+` / `Shift+Alt+T` | **Blank browser tab** (address bar focused) | Reviewer's answer (Q1); unchanged from rev 2 |
| Clicking an `http(s)` URL in the app | `openExternal()` → open/focus a browser tab → window. Works **independently of tab mode** | Reroutes `ChatView.onPrCreated` (`ChatView.vue:887`) and `NalarSettings.openWeb` (`NalarSettings.vue:549`). With the strip off it just opens the window — simpler than rev 2, where it had to degrade to `window.open` |
| Tab mode off | A browser tab still works; `?view=browser&url=…` renders (the window is unaffected by the strip) | `syncFromTarget` returns early when disabled (`stores/tabs.ts:437-440`) and `currentView` is independent of the toggle |
| Window lifetime | One window per browser tab; closing the tab closes its window. Activating a tab whose window is gone re-opens it; no windows are re-opened on app start | Predictable, no zombie windows on boot. Focusing an already-open window from another process is **not** attempted (OS-specific); the tab body says the window is open and offers "Open another" |
| Session/cookie isolation | **None in v1** — the window shares the app's default WebKit data store | One user, one app: sign-in persists, which is the point. An isolated per-workspace store is a follow-up |
| Not in v1 | Agent driving (screenshot/click/console), approval/allowlist UI, inline pane, downloads, favicons, per-tab zoom | §10 — each is its own card, and the agent half already has infrastructure in-tree |

### 3.1 What this removes from the repo's risk profile

No new inbound surface (no route), no outbound fetcher, no cookie forwarding, no
HTML rewriting, no untrusted HTML entering our document. The only new attack
surface is "the user opened a website" — the same as any browser — plus the
injected bar, which runs in the *page's* world and therefore can be tampered with
by the page (worst case: the user loses the bar and closes the window).

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
tabsStore.navigateBrowserTab(tab.id, url)      desktop shell: spawn
        │                                       nalar-desktop --browser <url>
        ▼                                                 │
  tab target = ?view=browser&url=…              webview_create(0, NULL)
  tab label = host                              + webview_init(chrome JS)
                                                + webview_navigate(url)
                                                          │
                                                          ▼
                                        Nalar browser window: the page, with an
                                        injected bar (URL, ←, →, ↻)
                                        links/back/forward/sign-in all native
```

Cross-process control is deliberately absent in v1: the app records the URL, the
window browses. The pane card (§10) adds the bridge that lets the tab drive it.

## 5. Tasks

**Order matters:** Task 1 first — it is independently useful and testable straight
from the CLI (`nalar-desktop --browser https://example.com`) before any frontend work
exists, and it is the only shell-touching part. Then Tasks 2–3 (tab kind, then tab
body + spawning), then 4–5 (docs, gates).

### Task 1 — Shell: `--browser <url>` mode

- [ ] **1.1** `src/apps/desktop_app/cli.zig` — add `--browser <url>` to the existing
  flag chain (`:129-195` is a flat `else if` list; add one arm) and a
  `browser_url: ?[]const u8` field to `Config`. Validate `http(s)` at parse time and
  return a CLI error otherwise (the shell must never open a `javascript:` URL).
- [ ] **1.2** `src/apps/desktop_app/main.zig` — before the attach block (`:220-310`):
  if `cfg.browser_url` is set, **skip attach/auto-spawn entirely** and call
  `webview_lib.runWindow(title, url_z, w, h, devtools, x11)` with that URL, then
  return. Reuse the existing `title`/window-size flags; default title = the URL's
  host so the OS window list is readable.
- [ ] **1.3** `src/apps/desktop_app/webview_lib.zig` — add a `runBrowserWindow`
  wrapper that, in order, does `webview_create(0, null)` → `webview_init(chrome_js)`
  (from 1.4) → `webview_navigate(url)` → `webview_run`. `webview_init` is already
  declared (`:71`); nothing new is linked (`runWindow`, `:89-126`, is the shape to
  mirror).
- [ ] **1.4** NEW `src/apps/desktop_app/browser_chrome.zig` — holds the chrome script
  as a Zig string constant (so one code path serves all three OSes): builds a
  `position:fixed` bar (`top:0`, max `z-index`, own inline styles) with a URL input,
  ←, →, ↻, and a "▤ Nalar" label; wires Enter → `location.href = <normalized>`,
  `history.back()`, `history.forward()`, `location.reload()`, and fills the input
  from `location.href` on every load; injected at document-start and mounted on
  `DOMContentLoaded`. Inline styles + a data attribute only — **no inline
  `<script>` tag**, so it is not subject to a page's `script-src`.
- [ ] **1.5** Inline Zig tests (`browser_chrome_test.zig`): the script contains no
  literal `</script>` sequence, the URL field is normalized before assignment
  (rejecting a scheme that is not http/https), and the script is stable across calls.
- [ ] **1.6** `cli_test.zig` — `--browser` with no value → error; a non-http scheme →
  error; a valid URL parses into `browser_url` alongside the existing flags.

**Acceptance:** `./zig-out/bin/nalar-desktop --browser https://example.com` opens a
window showing example.com with a working bar (Enter, ←, →, ↻); `--browser
javascript:alert(1)` exits with a CLI error and opens nothing.

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
  (`open({ path: '/app', query: { view: 'browser', …(url ? { url } : {}) }, kind: 'browser', … })`),
  `navigateBrowserTab(tabId, url)` (rewrite `query.url`, `rekeyTab`, persist — no
  router call; the caller re-applies via `applyActiveTabToUrl`), and an
  in-memory `browserWindows: Record<tabId, number /*pid*/>` (+ `setBrowserPid`,
  `browserPidOf`, cleared on tab close). **No history storage** — the engine owns
  history now, so the separate localStorage key from rev 2/3 is gone.
- [ ] **2.4** `components/shell/TabBar.vue` — `GLYPHS.browser = '🌐'` (the exhaustive
  `Record<TabKind, string>` at `:38-45`); `titleOf` (`:73-99`) → page title if the
  view reports one, else `hostOf(url)`, else `New tab`; `newTab()` (`:143-146`) →
  `openBrowserTab()`.
- [ ] **2.5** `components/AppLayout.vue` — `v-else-if="currentView === 'browser'"`
  branch for `BrowserTabView` in the existing chain, first (before
  `KanbanSettingsView`, `:2526`); `currentView` needs **no** new branch (it falls
  through to `route.query.view`, `:946-948`); import statically like
  `KanbanView`/`DesignView`.
- [ ] **2.6** `composables/useCurrentMainView.ts:38-52` — `{ kind: 'browser'; url?: string }`
  + the `view === 'browser'` branch (sidebar active-state).
- [ ] **2.7** Tests — `tabTarget.spec.ts` (key/kind/title/`asKind` round-trip
  through `parseTabList`), `tabsStore.spec.ts` (open/dedupe by URL/navigate re-keys
  in place/pid map/`TABS_VERSION` stays `1`), `TabBar.spec.ts` (glyph, host title,
  blank label, `+` opens a browser tab — the deliberate flip of
  `TabBar.spec.ts:260`), `AppLayout.tabs.spec.ts` (deep link creates one browser tab
  beside the boot home tab and renders the view; two tabs do not shadow each other;
  tabs-off still renders).

**Acceptance:** `pnpm exec vitest run tabTarget.spec.ts tabsStore.spec.ts
TabBar.spec.ts AppLayout.tabs.spec.ts` green; a pre-feature `localStorage` payload
still loads its tabs.

### Task 3 — Frontend: the tab body and window spawning

- [ ] **3.1** NEW `components/browser/BrowserTabView.vue`:
  * **blank** (`url` absent): address bar (`data-testid="browser-address"`) +
    "Search or enter address" hint + Open; Enter → `normalizeAddressInput` →
    `navigateBrowserTab` → spawn (3.2). A refused scheme shows an inline error under
    the bar and nothing opens.
  * **with a url**: read-only URL row + Copy, "Open browser window"
    (`data-testid="browser-open-window"`), "Open in system browser", and a one-line
    status: *"Open in a Nalar window"* / *"window closed — open again"* (liveness via
    the pid). Recent browser history is **not** stored (the engine owns it).
- [ ] **3.2** NEW `helpers/browserWindow.ts` — `openBrowserWindow(url): Promise<number|null>`
  posts to a spawn helper (3.3) and records the pid via `setBrowserPid`;
  `isWindowAlive(pid)`; `schemeOk` guard. All spawning is user-gesture-initiated
  only (no window on mount, no window on restore).
- [ ] **3.3** Spawn channel: the SPA needs the shell to start a process. Options, in
  preference order — pick at implementation time and record the choice:
  (a) a tiny `POST /api/desktop/browser-window` **loopback-only** handler in the Zig
  server that runs the same binary in `--browser` mode detached (reuses
  `attach.zig:195-206`'s existing detached-spawn pattern; adds one route to our own
  server, no fetch-from-URL, no SSRF — the URL is validated http(s) and passed as
  argv, and the handler accepts only `127.0.0.1`);
  (b) OS-level opener calls from the shell instead of a route.
  Whichever ships, the URL is passed **as an argument, never as a shell string**.
- [ ] **3.4** `helpers/openExternal.ts` — `http(s)` → `openBrowserTab(url)` (and open
  the window when the strip is off); anything else → `window.open(url, '_blank',
  'noopener')` unchanged. Reroute `ChatView.vue:887` and `NalarSettings.vue:549`;
  leave `PreviewContentRenderer.vue:210` on the `blob:` path (documented).
- [ ] **3.5** Tests — `BrowserTabView.spec.ts` (blank Enter opens; scheme refusal;
  the url state's buttons; no window on mount), `openExternal.spec.ts` (http(s) vs
  `blob:`/`javascript:`, strip on/off), `browserWindow.spec.ts` (spawn payload
  carries the URL as an argument; pid recorded; liveness).

**Acceptance:** `pnpm exec vitest run BrowserTabView.spec.ts openExternal.spec.ts browserWindow.spec.ts` green.

### Task 4 — Documentation

- [ ] **4.1** `docs/tabs.md` — the `browser` kind and its key shape (`:107-134`); the
  label rule (`:141-163`); the gestures table (`:14-25`) with the new `+` meaning;
  "Turning it off" (`:194-205`) → a browser tab still opens its window; the Files
  table (`:221-235`).
- [ ] **4.2** `docs/SPEC.md` — `§3.7.12 In-app browser tab`: the window architecture,
  the one-view-per-window constraint from §2 (with the `webview.h` line numbers), the
  injected bar and its wart, the `--browser` flag, the spawn channel, and
  `**Plan:** docs/superpowers/plans/2026-09-14-in-app-browser-tab.md`; plus a PR index
  row (`:919+`). Append, never rewrite history.
- [ ] **4.3** Append `## Implementation status` to this plan when it lands.

### Task 5 — Gates

- [ ] **5.1** `zig build test --summary all` (new inline tests included);
  `pnpm --dir src/apps/desktop test` compared against the baseline recorded **before**
  Task 1 (this repo carries pre-existing failures; a new red test must be new);
  `pnpm --dir src/apps/desktop run build` and `run lint:check` clean.
- [ ] **5.2** Cross-platform build proof: `zig build-obj -fno-emit-bin -target
  x86_64-windows-gnu -lc …` and `… -target aarch64-macos -lc …` on the touched shell
  modules. The chrome script is a string constant precisely so no ObjC/C++/Win32 code
  is needed for it.
- [ ] **5.3** `tests/functional/`: extend the desktop-app coverage with a
  `--browser` case that must **not** start a server (`harness` boots a server; use the
  existing desktop smoke scripts instead — `scripts/desktop-autospawn-smoke.sh` is the
  precedent) and assert the CLI rejects a non-http scheme. No new HTTP route means no
  new wire test is required; if 3.3(a) ships, add a harness test asserting the route is
  loopback-only and rejects a non-http URL.

---

## 6. Edge cases (each needs a test)

| # | Case | Expected | Covered by |
|---|---|---|---|
| 1 | Same URL twice | The existing tab is focused (key dedupe — documented deviation from Chrome) | 2.7 |
| 2 | Blank `+` twice | The one blank browser tab is focused | 2.7 |
| 3 | `javascript:` / `data:` / `file:` typed | Inline error, nothing opens, nothing spawns | 2.2, 3.5, 5.3 |
| 4 | App restart with browser tabs | Tabs restored, **no** windows opened until the user asks | 3.2, 3.5 |
| 5 | Window closed from the OS, tab still open | Tab shows "window closed — open again"; one click re-opens on the same URL | 3.1, 3.5 |
| 6 | Closing the tab | Its window is closed too (1:1 lifetime) | 2.3, 3.5 |
| 7 | Activating a browser tab whose window is alive | No second window; the tab says the window is open | 3.1 |
| 8 | Google search from the omnibox | A **real** Google page in the window (no consent-interstitial risk: a real engine, real cookies) | manual §9 |
| 9 | GitHub: repo, sign-in | Works — real top-level view, no `X-Frame-Options` involvement, cookies persist | manual §9 |
| 10 | A site that refuses framing (`x-frame-options: deny`) | Irrelevant now — it is not in a frame | manual §9 |
| 11 | `localhost:<port>` dev server | Works, and sends no framing headers anyway | manual §9 |
| 12 | A page with a full-screen overlay | May cover the injected bar; documented, page can always be closed; native bar is the pane card | manual §9 |
| 13 | A page whose CSP is strict | The bar still works (injected styles + DOM APIs, no inline `<script>` tag) | 1.5 |
| 14 | Two browser tabs, two windows | Independent histories and cookies (same store, different windows) | manual §9 |
| 15 | Very long URL | Bar input scrolls; the tab shows the host | 3.1 |
| 16 | Tab mode off | `openExternal` opens the window directly; a `?view=browser` URL still renders the tab body | 3.4, 2.7 |
| 17 | 50-tab cap | Oldest non-active evicted; the active browser tab never evicted (existing `enforceLimit`) | 2.7 |
| 18 | `?tab=` (strip) vs `?tab=` (kanban settings) | Unchanged: `migrateLegacySettingsTab` (`tabTarget.ts:297-318`) disambiguates by path | 2.7 |

---

## 7. Risks

| Risk | Impact | Mitigation |
|---|---|---|
| The injected bar is in the page's document | A page can cover or remove it | Documented; the OS window controls (close) always work; a native bar is the pane card's job; the bar is re-injected on every navigation |
| Spawning a process from the SPA | Command-injection surface | The URL is passed **as an argv element**, never a shell string; validated `http(s)` on both sides; if a route is used it is loopback-only |
| The window shares the app's cookie store | A hostile page could see cookies for our loopback origin | The window is a normal browser view on a user-chosen site; loopback cookies are not credentials for anything outside the machine; an isolated store is a follow-up (§10) |
| WebView2 / WebKitGTK / WKWebView differences in init-script timing | Bar missing on one platform | The bar mounts on `DOMContentLoaded` **and** on a 250 ms retry (mirrors the `useKanbanColumnScrollRestore` polling precedent); manual check per OS in §9 |
| Sandboxing/entitlements | macOS may need an entitlement for outbound network | The app already loads `http://127.0.0.1`; outbound networking is a follow-up check in §9, not a code change |
| Two address bars (tab body + window bar) feels redundant | Mild UX wart | The tab body is a launcher/record; the window owns browsing. The pane card deletes the redundancy by making them one |
| Users expect the page *inside* the tab | Disappointment | §10 records the pane as the next card with the exact constraint; the plan is explicit that v1 is Cursor's "separate window" mode |

---

## 8. Rollback

* Feature-additive: a CLI flag + a Zig file + a tab kind + one component. `git
  revert` restores today's behaviour; nothing else reads the new flag.
* No storage migration: `TABS_VERSION` stays `1`; a restored `?view=browser` tab
  renders nothing after a revert (an unknown `view` already renders empty today) and
  Settings → General → tabs off/on rebuilds a clean list (`resetToHome`,
  `stores/tabs.ts:585-593`).
* The window is a separate process: a reverted frontend leaves the flag unused; a
  reverted flag leaves a tab body whose Open button fails visibly (not silently).

---

## 9. Verification (manual, after implementation)

Backend on **8080** (never 8081); UI via `pnpm --dir src/apps/desktop dev` (5173)
with `VITE_API_PROXY_TARGET=http://localhost:8080`:

- [ ] `+` → blank browser tab, address bar focused, tab labelled `New tab` / 🌐.
- [ ] Type `github.com` → a **Nalar window** opens on GitHub; the window's bar shows
  the URL; a link inside works; ← returns; ↻ reloads; **sign in to GitHub** and
  confirm the session survives closing and re-opening the window.
- [ ] Type `zig lang` → Google results in the window; search again from the window's
  own bar; confirm a second search works.
- [ ] Type `localhost:5173` (or any dev server) → renders — the dev/verify workflow
  Cursor's browser exists for.
- [ ] Type `example.com`, then a page with a full-screen overlay; confirm the bar's
  worst case is documented behaviour, not a crash.
- [ ] `javascript:alert(1)` in the tab body → inline error, no window.
- [ ] Close the window from the OS → the tab says "window closed — open again";
  one click re-opens the same URL. Close the tab → its window closes.
- [ ] Restart the app → the browser tab is restored, **no window pops up**.
- [ ] Create a PR from a chat → the PR URL opens in a browser tab + Nalar window.
- [ ] Settings → "Open web" → same.
- [ ] Tabs off → `openExternal` still opens the window; a `?view=browser&url=…` URL
  still renders the tab body.
- [ ] Repeat the window checks on macOS and Windows (the chrome script is the only
  platform-sensitive part).

### Reviewer answers (all locked 2026-09-14)

| # | Question | Answer |
|---|---|---|
| Q1 | `+` = blank browser tab, or keep it for the chats list? | **Blank browser tab** |
| Q2 | Drop the framing-hostile fallback, or keep it so GitHub/Google open? | **Keep real browsing power** — and rev 4 delivers it the *right* way (a real webview, so no proxy is needed at all) |
| Q3 | Search provider? | **Google** |
| Q6 | Cursor's "separate window" mode, or jump straight to the inline pane? | **Separate window** |

**Q6 is the shape of v1:** `nalar-desktop --browser <url>` opens the page in a
Nalar-owned webview window, and the browser tab is its launcher and record. The
**inline pane** — the page inside the app window, which "open a new tab, but
literally a browser" arguably means most literally — is **not** a v1 option; it is
the next card (§10.2), because it needs the vendored container patched per OS. The
tab-kind and tab-body work (Tasks 2–3) is unchanged by that future step.

---

## 10. What rev 4 deleted, and the two follow-up cards

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
instead of `setContentView:` (`:2632`); Windows: parent the second
`WebView2` controller to a child HWND (`:3617`). Then a JS↔Zig bridge
(`webview_bind`, `:384`) for create/close/activate/geometry/title-and-URL events, a
non-blocking shell loop, and a decision about the Vue strip becoming shell-drawn.
Multi-week, per-OS — its own card.

### 10.3 Follow-up card 2 — agent driving (Cursor's actual headline)

Cursor's browser is *agent*-controlled; ours would be too, and we already have both
halves: the `agent-browser` CLI (used by the repo's web tool today) and the in-tree
`src/modules/nalar_browser/` Bun service (`/launch`, `/page`, `/snapshot`, `/click`,
`/fill`, `/press`). A card would wire snapshot/click/screenshot/console into the
browser view plus Cursor's approval + allow/deny-list gating. Note that the Bun
service is optional, out of CI, and unwired (`rg nalar_browser` → 6 hits, all docs),
so this is real integration work, not a lookup.

---

## Implementation status

**Not started.** Planning artefact only. When the work lands, append the
shipped/deviated/gates sections here (house style).
