# In-app browser tab (a new tab that is literally a browser)

> **Status: PLAN ONLY — not executed.** Rev 1 (2026-09-14). Awaiting the
> go-ahead at `in_review_planning`. Nothing in this document has been
> implemented; every line number below was verified by reading `main` at
> `b7c2d39e`.
>
> **Plan PR:** #489, branch `worktree/task-1789376475404` (docs only — merging it
> lands this plan, not the feature).

> **For agentic workers:** this is a *planning* artefact. Before implementing, use
> subagent-driven-development / executing-plans. Steps use checkbox (`- [ ]`)
> syntax for tracking.

**Task:** `task_1789376526556_0` — *"in browser app is a feature to open a new tab,
but literally a browser"*.

**Goal:** make a tab in the existing browser-style strip able to hold **a real web
page** — its own address bar, back / forward / reload, and the page rendered
inside the app — so that:

1. `+` (and `Shift+Alt+B`) opens a **blank browser tab** with the address bar
   focused, not the chats list;
2. an `http(s)` URL clicked anywhere in the app (a created PR URL, the "Open web"
   button, "Open in new tab" on an HTML preview) opens **in a new in-app browser
   tab** instead of the OS browser;
3. a deep link like `?view=browser&url=https://example.com/` is a first-class,
   reload-safe, reopen-safe destination — same contract as every other tab kind.

Generated 2026-09-14 against `main` @ `b7c2d39e`.

---

## 1. Decisions (locked)

| Decision | Value | Why |
|---|---|---|
| What "a browser" renders in | **An `<iframe>` inside the one existing native webview** | The desktop shell is a *single* `webview_t` window: `desktop_app/main.zig:300-306` calls `webview_lib.runWindow(...)`, which does `webview_create → webview_navigate → webview_run` and **blocks in `webview_run`** (`webview_lib.zig:119-126`). There is no second-view primitive wired up (no Electron `BrowserView`, no Tauri `WebviewWindow` — neither dependency exists in the repo). A real second browsing context means reworking window lifetime + the blocking event loop across Linux/macOS/Windows (§7, out of scope). |
| Primary render path | **Direct `<iframe src="<url>">`, no proxy** | Full fidelity: relative URLs, the site's own JS, its own origin and storage — it is exactly what a browser does, minus chrome. Also means we do **not** become a mini web-proxy for the common case. |
| Fallback render path | **Server-proxied HTML into `<iframe srcdoc>`** — only when the probe says the site refuses framing | `X-Frame-Options: DENY` / `frame-ancestors` is the single most common reason an in-app browser looks broken (github.com, google.com, most banks). A framing-hostile site is exactly the case where "open a browser tab" must still show *something*. |
| Who decides which path | **The Zig backend, from the real response headers** | The parent page cannot read a cross-origin frame's `contentDocument`, so a block is undetectable client-side. The backend can read `X-Frame-Options` + every `Content-Security-Policy` header on the **final** response and evaluate `frame-ancestors` against our **exact** origin (`http://127.0.0.1:<port>`). Deterministic, testable, no guessing. |
| New tab kind | `'browser'` added to `TabKind` (`helpers/tabTarget.ts:26`) | `TabKind` is the existing closed union; `GLYPHS` in `TabBar.vue:38-45` is an exhaustive `Record<TabKind, string>`, so the compiler forces every switch to be handled. |
| Tab URL shape | `path: '/app'`, `query: { view: 'browser', url: <absolute-url> }`; `url` **absent** = the blank new-tab page | Mirrors the existing query-only views (`view=workspace`, `view=chat`). No router change: `/app` already matches (`router/index.ts:12-15`) and the catch-all stays last (`:47-50`). A path route (`/app/browser`) was rejected — it would need a new `currentView` regex *and* a new router entry for zero benefit, and `tabTarget.ts` already has two path-based special cases (`SETTINGS_PATH`, `KANBAN_SETTINGS_RE`) that are pure debt. |
| Tab identity | `tabKeyOf` returns `browser:<url>` (blank ⇒ `browser:new`) | Key-based dedupe is the strip's contract. Consequence: **opening the same URL twice focuses the existing tab** instead of making a second one — a deliberate deviation from Chrome (§8 #1). A unique-per-tab key would need the tab id inside the key, which breaks the pure-function/adoption design (`tabTarget.ts:160-187`). |
| Page title | `title` from the proxied HTML when we have it, else the **hostname**, else `New tab` | We cannot read `<title>` out of a cross-origin frame. Honest label beats a stale one. Follow-up (§7) fixes this properly with a native webview. |
| Per-tab history | Back / forward stacks in a **separate** localStorage key, not inside `Tab` | `TABS_VERSION` stays `1`. Bumping it makes `parseTabList` (`tabTarget.ts:399-437`) throw every existing user's strip away — unacceptable for an additive feature. Separate key also means old code ignores it. |
| Address-bar input with no scheme | `https://duckduckgo.com/?q=<encoded>` | A browser's omnibox searches; a URL bar that errors on `hello world` feels broken. One constant, trivially swappable. |
| Allowed schemes | `http:` and `https:` **only** | `javascript:`, `data:`, `blob:`, `file:`, `about:` are refused in the address bar *and* in the handler. `file:` in particular would turn a UI field into arbitrary local-file read. |
| Proxy credentials | **None.** No cookies, no `Authorization`, no client certs forwarded | The endpoint is anonymous-fetch only. Logged-in pages therefore do not work through the proxied path — stated in the UI (§4.3), and the escape hatch is "Open in system browser". |
| `+` / `Shift+Alt+T` | **Opens the blank browser tab** (a change to today's behaviour) | The card asks for it: "open a new tab, but literally a browser". A browser's `+` gives a blank page with a focused omnibox, not a bookmarks list. The chats list is not lost: it is still the boot tab and the last-tab-closed fallback (`homeTab()`, `tabTarget.ts:328-342`), still one click away in the sidebar, and linked from the blank page. §11 Q1 is the one-line alternative. |
| Tab mode toggle off | The browser tab **still works as a plain view**; only the strip disappears | `syncFromTarget` already returns the raw target when `enabled === false` (`stores/tabs.ts:437-440`) and `currentView` is independent of the toggle, so `?view=browser&url=…` renders with no strip. `openBrowserTab()` degrades to `window.open(url, '_blank', 'noopener')` so the click-to-open call sites (§4.4) keep working. |
| Toolbar extras | Back, Forward, Reload, **Open in system browser**, and (proxied only) a "Force direct / Force proxied" toggle | Reload alone is not enough when a page renders badly: the user needs one click out. The force toggle is the escape hatch for a wrong `frameable` verdict. |
| Not in v1 | Downloads, form POSTs through the proxied path, `target=_blank` popups from the direct path, login/OAuth, favicons, DevTools, per-tab zoom, tab pinning/muting | Each is a separate feature. §7 records them so they do not need re-research. |

### 1.1 This reverses no prior decision

Unlike the kanban-tab plan, nothing here reverses an earlier commit. Tab mode
shipped frontend-only (`ceb2faa0` / PR #476) and this plan keeps that property
for the *chrome*; the only new server code is one read-only GET handler.

### 1.2 The one behaviour change to an existing contract

`+` today opens the chats list (`TabBar.vue:143-146` → `tabsStore.openHomeTab()`,
`stores/tabs.ts:475-478`). After this plan it opens the blank browser tab. Two
existing tests assert the old behaviour and are flipped deliberately:
`TabBar.spec.ts:260` *"opens a chats tab from the + button"* and the `openHomeTab`
cases in `tabsStore.spec.ts`. `openHomeTab()` itself is **not deleted** — it remains
the boot tab and the last-tab-close fallback. §11 Q1 covers the alternative.

---

## 2. Why the current tab system already accepts a new kind

Verified 2026-09-14 at `b7c2d39e`. The design is unusually ready for this:

* A tab is a **snapshot of a router target** — `{ path, query }` plus a
  client-only `?tab=<tabId>` (`docs/tabs.md:61-73`). Nothing renders from the
  tab; `AppLayout.currentView` decides the body and activation is a
  `router.replace` (`docs/tabs.md:77-101`).
* `kindOf()` / `fallbackTitle()` / `asKind()` / `tabKeyOf()` are the only pure
  rules (`helpers/tabTarget.ts:160-278`, `:353-357`).
* `stores/tabs.ts` never imports the router; it *returns* the navigation
  (`SyncResult`, `stores/tabs.ts:61-67`) and `AppLayout` applies it
  (`AppLayout.vue:2291-2298`).
* Overlays that must **not** become tabs are already excluded by a list
  (`OVERLAY_VIEWS`, `tabTarget.ts:73`); anything not listed is tabbable for free
  (`shouldTabify`, `:240-249`).

So adding `'browser'` is: one union member, four pure functions, one exhaustive
glyph record, one `currentView` branch, one render-chain branch, one store
opener. That is the whole frontend integration surface — no new router route, no
new store, no persistence migration.

---

## 3. Current behaviour (verified 2026-09-14 at `b7c2d39e`)

### 3.1 The strip and the render chain

`AppLayout.vue:2401-2402`:

```html
<main class="flex-1 flex flex-col overflow-hidden relative">
  <TabBar @navigate="applyActiveTabToUrl" />
```

The body chain (`AppLayout.vue:2526-2897`) is one `v-else-if` chain; ordering is
load-bearing (each constraint is commented in place, e.g. kanban-chat **before**
`KanbanView` at `:2535-2541`). A browser branch must be added to that chain, not
as a new standalone `v-if` chain, so it can never stack with a workspace view.

`currentView` (`AppLayout.vue:911-949`) resolves `settings` and
`kanban-settings` by path first, then falls through to
`route.query.view ?? 'chat'` (`:946-948`). `view=browser` therefore already
flows through the fallthrough with **no change to `currentView` at all** — the
only new branch is the template one. (Kept explicit in Task 3 so the intent is
greppable.)

### 3.2 What the shell can and cannot do

| Fact | Evidence |
|---|---|
| One native window, one webview, blocking event loop | `desktop_app/main.zig:300-306`; `webview_lib.zig:119-126` |
| Vendored `webview/webview` 0.12.0, GTK/WebKitGTK-4.1 on Linux, WKWebView / WebView2 elsewhere | `vendor/webview/webview.h:67-79`; `build.zig:1696-1725,1811-1853,1863-1943` |
| `webview_set_html` / `webview_eval` / `webview_bind` are **declared but never called** | `webview_lib.zig:69-73` (declarations), `:125` (only `webview_navigate` is used) |
| **No** CSP, **no** `X-Frame-Options`, **no** `Cross-Origin-*` on our own pages | `modules/static_files.zig:489-494` is the complete 200 header block (5 headers) |
| Our app is same-origin with the API in production, Vite-proxied in dev | `main.zig:342` binds `127.0.0.1:<port>`; `main.zig:352-404` wires `--static-dir`; `vite.config.ts:15,43-45` |
| The engine is a full browser engine and *will* render arbitrary sites | it renders our Vue SPA today |

The single concrete consequence: our loopback pages carry no CSP, so an
`<iframe>` we add is neither blocked nor restricted by our own headers. What
blocks a page is the **target site's** headers.

### 3.3 Existing precedent for embedding untrusted web content

The repo already renders untrusted HTML in sandboxed iframes, twice:

* `PreviewContentRenderer.vue:261-269` — `sandbox="allow-scripts"`,
  `:srcdoc`, NULL origin, with the security note at `:37-42` (no
  `allow-same-origin` ⇒ cannot read parent cookies/localStorage/window; no
  `allow-forms`; no `allow-top-navigation`).
* `ChatView.vue:3587-3592` — the `<html>` wrapper-tag frame, same sandbox,
  theme inlined into the srcdoc shell (`buildHtmlSrcdoc`, `:361-393`) because a
  NULL-origin frame inherits no CSS, plus the shared auto-resize protocol
  (`helpers/iframeAutoResize.ts`, full file) with a per-consumer source tag.

This plan **reuses the pattern** (a third source tag for its postMessage
channel) and **deviates once, deliberately**: the direct path gets
`allow-same-origin`, because there the framed document is a *different* origin
anyway — `allow-same-origin` just lets the remote site keep its own origin,
storage and cookies, which is what makes sites work at all. The dangerous
combination (`allow-scripts` + `allow-same-origin` on *same-origin* `srcdoc`
content that could reach into the parent) never occurs here: the srcdoc path
never sets `allow-same-origin`. This is stated in the component and must be
locked by a test (§6.2).

### 3.4 The funnel (unchanged, listed for orientation)

Sidebar click / deep link / strip click → `syncFromRoute` (`AppLayout.vue:2309-2319`)
→ `tabsStore.syncFromTarget` (`stores/tabs.ts:424-468`) → `withTabParam(path, id)`
→ `router.replace`. `mirrorTargetIntoStores` (`:2269-2288`) mirrors the target
into the stores **first**, because the chain reads stores, not the URL. A
browser target needs neither mirroring (it has no store-backed identity) nor a
new branch in the funnel.

---

## 4. Target behaviour

### 4.1 Rendering flow

```
address bar / deep link / click-to-open
        │  normalize (scheme allowlist, omnibox search)
        ▼
tab query { view: 'browser', url }        ← the tab IS the navigation state
        │
        ▼
BrowserView.vue  ──GET /api/browser/page?url=…&probe=1──►  Zig handler
        │                                                     │ libcurl GET
        │                                                     │ (Range 0-0)
        │                                                     ▼
        │                                               upstream headers
        │◄──── { ok, status, final_url, title, content_type,
        │        frameable, frame_block_reason } ─────────────┘
        │
        ├─ frameable  && !forceProxy ──► <iframe src="<url>"
        │                                   sandbox="allow-scripts allow-same-origin allow-forms">
        │
        └─ !frameable || forceProxy  ──GET …&probe=0──► proxy executes
                                             │ reuses the already-fetched response when
                                             │ the probe ran in the same request
                                             ▼
                                       { html, title, final_url, content_type }
                                             │
                                             ▼
                              <iframe srcdoc="<base href=…> … <nav-post script>"
                                      sandbox="allow-scripts">
```

`probe=0` is a single request that also returns `frameable`, so a proxied page
costs exactly one round trip. `probe=1` never returns a body and therefore never
trips the size cap.

### 4.2 Wire contract — `GET /api/browser/page`

Query: `url` (required, absolute), `probe` (`1` = metadata only, `0`/absent =
include `html`).

`200` (probe=1, a framing-hostile site):

```json
{
  "ok": true,
  "url": "https://github.com/",
  "final_url": "https://github.com/",
  "status": 200,
  "title": "",
  "content_type": "text/html; charset=utf-8",
  "frameable": false,
  "frame_block_reason": "x-frame-options: DENY",
  "html": null
}
```

`200` (probe=0): identical plus `"html": "<!DOCTYPE html>…"`.
`title` is populated only when a body was read (`probe=0`); on the direct path
the tab title falls back to the hostname.

Errors — all JSON `{"error": "…"}` via `http_response.makeErrorResponse`, the
house envelope (`http_handlers/worker_list.zig:103-116` is the template):

| Status | `error` | Trigger |
|---|---|---|
| 400 | `url query param required` | missing / empty |
| 400 | `url must be an absolute http(s) URL` | no scheme, or a scheme outside `http`/`https` |
| 403 | `host is not reachable from the in-app browser (private network)` | SSRF guard, §5 |
| 413 | `upstream body exceeds the 2 MiB cap` | `probe=0` and body > 2 MiB |
| 415 | `unsupported content type: <ct>` | `probe=0` and `content_type` outside `text/html`, `application/xhtml+xml`, `text/plain` |
| 502 | `failed to reach upstream` | libcurl error, or a redirect ending off `http(s)` |
| 504 | `upstream timed out` | `error.Timeout` from the client |
| 500 | `out of memory` | allocator failure |

The **probe path ignores the size cap** (it wants headers, not bytes) — it sends
`Range: bytes=0-0` best-effort; a server that ignores `Range` costs one
discarded download, never an error.

### 4.3 `frameable` — the exact rule

Evaluated on the **final** response (after redirects), against our own origin
`http://127.0.0.1:<port>` (the port comes from
`nalar.getSingleton().server.address.port`, exactly as
`src/http_handlers/web_status.zig:34` reads it):

1. `X-Frame-Options` present with `DENY`, `SAMEORIGIN`, or any value that is not
   literally our origin ⇒ **false**, reason `x-frame-options: <value>`.
2. Any `Content-Security-Policy` header containing `frame-ancestors`:
   frameable iff the source list contains `*`, or `http://127.0.0.1:<port>`, or a
   source that matches it (`http:`, `http://127.0.0.1:*`, `'self'` does **not**
   match — different origin). A second CSP header that forbids ⇒ **false**
   (headers intersect). `'none'` ⇒ **false**.
3. Otherwise ⇒ **true**.
4. A `frameable: true` verdict is a *prediction*: the engine is authoritative.
   The toolbar's force-proxy toggle (§4.5) exists precisely because the
   prediction can be wrong (e.g. a site that checks `Sec-Fetch-Dest` and
   refuses at runtime).

### 4.4 Clicking an `http(s)` URL opens a browser tab

A new helper `helpers/openExternal.ts` becomes the single place the app opens an
external URL:

```ts
// Pseudo-contract; the real file has the full JSDoc.
export function openExternal(url: string): void {
  if (!isHttpUrl(url)) return window.open(url, '_blank', 'noopener')
  const tabs = useTabsStore()
  if (!tabs.enabled) return window.open(url, '_blank', 'noopener')
  tabs.openBrowserTab(url)
  // caller re-applies the URL through the existing applyActiveTabToUrl()
}
```

Call sites to reroute (these are the **only** production `window.open` sites in
`src/apps/desktop/src`):

| File:line | Today | After |
|---|---|---|
| `components/views/ChatView.vue:887` (`onPrCreated`) | `window.open(url, '_blank')` | `openExternal(url)` — a created PR opens in an in-app browser tab |
| `components/NalarSettings.vue:549` (`openWeb`) | `window.open(webUrl.value, '_blank', 'noopener')` | `openExternal(...)` |
| `components/preview/PreviewContentRenderer.vue:210` (`openInNewTab`) | blob URL + `window.open` | **unchanged** — a `blob:` URL is same-origin, cannot be proxied, and framing it with `allow-same-origin` would breach the sandbox boundary. This is a documented non-goal. |

With tab mode off, `openExternal` degrades to today's `window.open` — the call
sites keep working for users who turned the strip off.

### 4.5 The view

`BrowserView.vue` is one component, no store dependency beyond the tabs store:

| Region | Behaviour |
|---|---|
| **Chrome** (`BrowserChrome.vue`) | Back / Forward (disabled at the ends), Reload, a read-only-ish address bar, Open-in-system-browser, and a proxy-mode badge with the force toggle |
| **Address bar** | Enter → normalize (allowlist → omnibox search) → `tabsStore.navigateBrowserTab(tabId, url)` → `applyActiveTabToUrl()`; focus selects all (browser behaviour); a refused scheme shows an inline error **under** the bar and navigates nowhere |
| **Frame** | `<iframe :key="frameKey">` where `frameKey` = `url + ':' + mode + ':' + reloadNonce` so a mode switch or reload genuinely re-navigates |
| **Loading / error** | Cancellable via a monotonic request token: a late response for a URL the user already left must never paint (edge case §8 #13) |
| **Blank tab** (`url` absent) | Small new-tab page: the app name, a "Chats" shortcut (focus the home tab), the recent browser history list, and one hint line — no borrowed content |
| **Proxied badge** | One honest line: *"Proxied — scripts and sign-in may not work"* + the system-browser button. Without it the degraded path looks like a bug (precedent: the `show_preview` white-page exception is documented at `docs/superpowers/plans/2026-09-13-html-frame-theme-and-height.md:141-145`) |
| **Error page** | Status + plain-English reason + "Open in system browser" + "Try the proxied view" when it was a direct-path failure |

The frame is styled `w-full h-full border-0` inside the chain, i.e. it fills the
content area under the strip — not auto-sized like the chat frames, because a
browser page has its own scrollbar. It therefore does **not** use
`iframeAutoResize`; it uses a **new** postMessage channel with its own source tag
for navigation only (§4.6).

### 4.6 In-frame navigation on the proxied path

A NULL-origin srcdoc frame can navigate itself, but that would take it to the
real URL — where the site may refuse framing, leaving a blank frame. Instead the
proxied body gets a small injected script (same shape as
`iframeAutoResize.autoResizeScript`, `helpers/iframeAutoResize.ts:104-145`):

* capture-phase `click` on the nearest `<a href>` with no modifier keys:
  `preventDefault()` then `parent.postMessage({ source: 'browser-frame-nav', url })`.
* `target="_blank"` links: post `{ source: 'browser-frame-nav', url, newTab: true }`
  → the parent calls `openBrowserTab(url)`, i.e. a real new tab, like a browser.
* pure-fragment links (`#x` on the same URL): not intercepted — the frame scrolls.

The parent listens for source tag `browser-frame-nav` only (never the two
existing tags), resolves the sender by `contentWindow === event.source`
(`findSenderFrame`), records history and re-runs the probe+fetch for the new URL.
The listener is registered/unregistered in `onMounted`/`onUnmounted` — the same
paired lifetime as `PreviewContentRenderer.vue:109-119`.

---

## 5. Global constraints

* **Never touch the process on port 8081.** Manual verification uses
  `pnpm --dir src/apps/desktop dev` (5173) with `VITE_API_PROXY_TARGET` pointing at
  a scratch backend on **8080**. Never `nohup` a binary + `curl`
  (`AGENTS.md:2-63`).
* **SSRF is the load-bearing risk of this feature.** `/api/browser/page` makes the
  backend fetch a user-supplied URL, on the same origin as the whole API. The
  guard is mandatory, not optional:
  * scheme allowlist `http`/`https` on the initial URL **and** on
    `url_effective` after redirects;
  * refuse any host whose resolved addresses are loopback (`127.0.0.0/8`, `::1`),
    private (`10/8`, `172.16/12`, `192.168/16`, `fc00::/7`), link-local
    (`169.254/16`, `fe80::/10`) — **including `169.254.169.254`**, unspecified
    (`0.0.0.0`, `::`), multicast and broadcast;
  * refuse the literal hostname `localhost` and names ending `.local`;
  * `follow_redirects = true`, `max_redirects = 5`, and re-validate the final URL;
  * never forward cookies, `Authorization`, or client certificates;
  * body cap 2 MiB, timeout 12 s.
  Without this, an agent-authored URL (or a hostile page that can reach the
  endpoint same-origin) could read the local API — including `GET /api/...` on
  the app's own port. §6.3 pins 403 for the loopback case over the real wire.
* **No CORS.** The proxy route must not gain an `Access-Control-Allow-Origin`
  header. `http_handlers/cors.zig:11` sets `*` but its route is commented out in
  `main.zig:423` and is dead code — leave it dead. Nothing in this plan touches
  `main.zig:423`.
* **Client-only `?tab=` still never leaks.** `tab` is the strip's tab id; it must
  never reach the API, the proxy, or the proxied URL. Existing guards
  (`stripTabParam`, `tabQueryOf`) already do this — Task 6 re-verifies with a
  grep on `helpers/buildTaskUrlQuery.ts` / `helpers/buildItemIdWithChat.ts`
  staying at zero `tab` hits.
* **Do not confuse the two `?tab=`.** `?tab=<tabId>` (the strip, this plan) and
  `?tab=columns|memories|tools|knowledge` (kanban-settings sub-tabs, `docs/SPEC.md`
  §3.7.11a) are unrelated. `migrateLegacySettingsTab` (`tabTarget.ts:297-318`)
  disambiguates by path; do not extend it for the browser kind.
* **Baseline first.** Record `pnpm --dir src/apps/desktop test` output **before the
  first edit**. This repo carries pre-existing failures (the 2026-09-14 plan
  recorded `4 failed / 3233 passed`); a new red test must be new.
* **No `// NEW (plan: …)` comments** (`AGENTS.md:148-165`). Say *why*, never *when*.
* `vue-tsc --build` emits stray `.js` next to `.ts` sources — delete them before
  committing.
* **Cross-platform by construction.** All new frontend code is Vue/TS; the one new
  Zig handler uses the already-cross-platform libcurl client
  (`@import("kabelweb").client`, `http_handlers/llm_test.zig:57-60`). No
  `platform/` code, no new link libraries, no per-OS branch. `zig build` for the
  three targets at the end (Task 10) proves it.
* **Defensive load for every persisted value.** The new history key must survive
  corrupt / older / hand-edited input without throwing, and must tolerate tab ids
  that no longer exist.

---

## 6. Tasks

### Task 1 — Pure URL + framing helpers (frontend)

- [ ] **1.1** NEW `src/apps/desktop/src/helpers/browserUrl.ts` — pure, no
  imports from stores or Vue:
  * `isHttpUrl(value: string): boolean`
  * `normalizeAddressInput(raw: string): { ok: true; url: string } | { ok: false; reason: string }`
    — absolute `http(s)` passes through; a bare host (`example.com`, `example.com:3000/x`)
    gains `https://`; anything else becomes the omnibox search URL
    (`SEARCH_URL_TEMPLATE = 'https://duckduckgo.com/?q='`, exported so a test and a
    future setting can both see it);
    explicit non-http schemes are refused with a reason, never searched.
  * `hostOf(url: string): string`
  * `browserTabTitle(url: string | null | undefined): string` — page title is
    supplied separately; this only covers host / `New tab`.
  * `injectBaseHref(html: string, finalUrl: string): string` — leaves an existing
    `<base href>` alone; otherwise inserts after the first `<head…>`, else prepends.
  * `injectNavigationRelay(html: string): string` — appends
    `navigationRelayScript()` before `</body>` when present, else at the end.
  * `navigationRelayScript(): string` — mirrors
    `autoResizeScript`'s escaping discipline (`</script>` emitted as `<\/script>`).
  * `frameAncestorsAllows(cspHeaderValue: string, appOrigin: string): boolean | null`
    — `null` when the directive is absent, used by tests to pin the matrix.
- [ ] **1.2** NEW `src/apps/desktop/src/__tests__/browserUrl.spec.ts` — table-driven
  specs for every branch above, including: `javascript:`/`data:`/`file:` refused;
  `example.com` → `https://example.com`; `example.com:3000/a?b=c` keeps its port;
  `hello world` → search; `injectBaseHref` leaves an existing base; the relay
  script escapes its own closing tag; `frameAncestorsAllows` matrix (`*`,
  `'none'`, exact origin, other origin, `'self'`, two directives, absent).
- [ ] **1.3** `src/apps/desktop/src/helpers/index.ts` — re-export the module
  (same style as the `iframeAutoResize` block at `:26-36`).

**Acceptance:** `pnpm exec vitest run browserUrl.spec.ts` green; module has zero
Vue/store imports (`rg "stores/|from 'vue'" src/apps/desktop/src/helpers/browserUrl.ts` → 0 hits).

### Task 2 — Backend: `GET /api/browser/page`

- [ ] **2.1** NEW `src/http_handlers/browser_page.zig` following the house
  pattern: a `pub fn browserPageHandler(ctx, req, res) !HttpResponse` that reads
  `req.query.get("url")` / `req.query.get("probe")` (cf.
  `worker_list.zig:95-101`), delegates to a `useCase`, and maps errors to the
  table in §4.2 with `http_response.makeErrorResponse` (cf.
  `worker_list.zig:103-116`).
- [ ] **2.2** The `useCase` takes an **injected fetcher function**, so the happy
  path is unit-testable without a network:
  ```zig
  pub const FetchResult = struct {
      status_code: u16,
      body: []u8,
      headers: []const Header,
      url_effective: []const u8,
  };
  pub const Fetcher = *const fn (allocator, url: []const u8) FetchError!FetchResult;
  pub fn useCase(allocator, url: []const u8, probe: bool, app_origin: []const u8, fetcher: Fetcher) Error!Page;
  ```
  The real fetcher wraps `@import("kabelweb").client`:
  `Client.init` → `client.perform(.{ .method = .GET, .url = url, .headers = &.{UA, Accept, Range} }, .{ .timeout_ms = 12_000, .follow_redirects = true, .max_redirects = 5 })`
  → `defer result.deinit(allocator)`. Note `client.get()` takes **no** headers
  (kabelweb `client/methods.zig:14-24`), hence `perform` directly. Modeled on
  `http_handlers/llm_test.zig:291-302`.
- [ ] **2.3** Implement the SSRF guard exactly as specified in §5, before any
  request. Resolve the host with `std.net.getAddressList` and check every
  returned address; a host that resolves to *any* blocked range is refused.
  Refuse loopback for the app's **own port** explicitly, with a comment saying why
  (self-API read).
- [ ] **2.4** Implement `frameable` per §4.3, taking the app origin as a parameter
  (`http://127.0.0.1:{port}`) so the unit test can pin the matrix without a server.
- [ ] **2.5** Implement the proxied path: `title` extraction (first
  `<title…>…</title>`, whitespace-collapsed, minimal entity decode), `415` on a
  non-HTML content type, `413` on the cap. Return **raw** upstream HTML in the
  JSON envelope (`{f}` via `std.json.fmt`, the house idiom —
  `stream_get.zig:40-48`); do **not** try to return `text/html` from the handler,
  because the frontend needs the metadata in the same response.
- [ ] **2.6** `src/http_handlers/mod.zig` — export `browserPageHandler`.
- [ ] **2.7** `src/main.zig` — register, immediately after the other
  `/api/browser`-free siblings near `web_status` (`main.zig:531`):
  ```zig
  try gs.router.get("/api/browser/page", ai_mod.http_handlers.browserPageHandler);
  ```
  `/api/browser/` is a fresh prefix with no `:param` siblings, so the
  registration-order rule (`matchRoute` walks in order) cannot bite; the static
  contract test in 2.8 pins it anyway.
- [ ] **2.8** NEW `src/http_handlers/browser_page_test.zig` — inline Zig tests
  with a **fake fetcher**: missing/empty url; each rejected scheme; a private IP
  host, a `.local` host, the app's own loopback origin; the size cap; the
  content-type gate; `frameable` matrix (`DENY`, `SAMEORIGIN`, our exact origin,
  another origin, `frame-ancestors 'none'`, `frame-ancestors *`, two CSP headers,
  absent); title extraction; `url_effective` off-scheme ⇒ 502; timeout ⇒ 504.
  Plus a static contract: `rg`-style assertion that the route string
  `/api/browser/page` appears in `main.zig` (house pattern, cf.
  `stream_get.zig:179-215`).

**Acceptance:** `zig build test --summary all` green and the new test count is
strictly greater than the baseline.

### Task 3 — Tab identity: the `browser` kind

- [ ] **3.1** `helpers/tabTarget.ts:26` — add `'browser'` to `TabKind`.
- [ ] **3.2** `tabKeyOf` (`:160-187`) — before the `view:${view}` fallthrough:
  ```ts
  if (view === 'browser') return q.url ? `browser:${q.url}` : 'browser:new'
  ```
- [ ] **3.3** `kindOf` (`:251-260`) — `if (view === 'browser') return 'browser'`.
- [ ] **3.4** `fallbackTitle` (`:262-278`) — `case 'browser': return 'New tab'`.
- [ ] **3.5** `asKind` allowlist (`:353-357`) — add `'browser'`, else a persisted
  browser tab silently re-derives its kind through `kindOf` on every load (which
  works, but the allowlist is the single source of truth and must not lie).
- [ ] **3.6** NEW `browserTab(url?: string): Tab` next to `homeTab()` (`:328-342`)
  — same shape, `key: url ? 'browser:' + url : 'browser:new'`, `title` from
  `browserTabTitle`, `query: { view: 'browser', ...(url ? { url } : {}) }`.
- [ ] **3.7** `tabTarget.spec.ts` — new cases: key with a URL, key when blank,
  `kindOf`/`fallbackTitle`, `asKind` round-trip through `parseTabList`, and that a
  browser tab survives `parseTabList` → `persist` → `parseTabList` unchanged.
  Also pin that `tab` is still stripped from a browser tab's query.

**Acceptance:** `tabKeyOf('/app', { view: 'browser', url: 'https://a.example/x?y=1' })`
=== `'browser:https://a.example/x?y=1'`; two distinct URLs ⇒ two distinct keys.

### Task 4 — Store: open, navigate, history, reload

- [ ] **4.1** `stores/tabs.ts` — NEW `openBrowserTab(url?: string): Tab`:
  `open({ path: '/app', query: { view: 'browser', ...(url ? { url } : {}) }, kind: 'browser', title: browserTabTitle(url) })`.
  Reuses the existing dedupe/insert-after-active/persist machinery verbatim.
- [ ] **4.2** NEW `navigateBrowserTab(tabId: string, url: string): void` — rewrites
  the active tab's `query.url`, recomputes the canonical key via
  `tabKeyOf('/app', query)`, `rekeyTab`s it, records the visit, persists. It must
  **not** call the router: the caller re-applies through
  `applyActiveTabToUrl()`, exactly like `TabBar.vue`'s handlers
  (`TabBar.vue:121-146`).
- [ ] **4.3** NEW per-tab history, **separate storage key**:
  ```ts
  const HISTORY_PREFIX = 'nalar-browser-history:v1:'   // + windowId, mirrors LIST_PREFIX
  interface BrowserHistory { entries: string[]; index: number }
  ```
  `recordBrowserVisit(tabId, url)` truncates forward history when the new URL is
  not the current entry (browser semantics), no-ops on a repeat of
  `entries[index]`, caps at `MAX_BROWSER_HISTORY = 50`.
  `browserHistoryOf(tabId)`, `browserBack(tabId)`, `browserForward(tabId)`,
  `canGoBack(tabId)`, `canGoForward(tabId)`.
  Prune entries whose `tabId` is no longer in `tabs` on every persist — an
  unbounded map keyed by dead ids is a leak.
  Load must be total (corrupt JSON / wrong `v` / non-array ⇒ empty), mirroring
  `parseTabList`'s defensiveness.
- [ ] **4.4** NEW `bumpReloadNonce(tabId)` + `reloadNonceOf(tabId)` — in-memory
  only. A reload of the same URL produces no URL change, so the funnel would
  never re-render; the nonce is what makes Reload real.
- [ ] **4.5** `+` wiring: `newTab()` in `TabBar.vue:143-146` becomes
  `tabsStore.openBrowserTab()` (no url). Keep `openHomeTab()` — it stays the boot
  tab and the last-tab-close fallback (`enforceLimit`/`close` are untouched).
- [ ] **4.6** Add `Shift+Alt+B` → `openBrowserTab()` to
  `composables/useTabShortcuts.ts` (the guaranteed `Shift+Alt` namespace,
  `docs/tabs.md:38-55`) and to the `AppLayout.vue:2337-2366` handler map, with a
  unit test for `resolveTabShortcut`.
- [ ] **4.7** `stores/tabs.spec.ts` — NEW cases: open focuses an existing tab for
  the same URL; two different URLs ⇒ two tabs; navigate re-keys in place;
  history push/back/forward semantics incl. forward-truncation and the 50 cap;
  history survives close → `reopenLastClosed` (same tab id); history for a dead
  tab id is pruned; corrupt history storage ⇒ empty, no throw; `reloadNonce`
  increments without touching the URL; `openBrowserTab` keeps `TABS_VERSION` at 1
  (existing persisted tabs still load).

**Acceptance:** `pnpm exec vitest run tabsStore.spec.ts` green; a store built from
a pre-feature `localStorage` payload keeps its tabs.

### Task 5 — Chrome + view components

- [ ] **5.1** NEW `src/apps/desktop/src/components/browser/BrowserChrome.vue` —
  presentational only (props in, events out; no store, no fetch): address input,
  Back/Forward/Reload, system-browser button, proxy badge + force toggle, inline
  scheme error slot. `data-testid`s: `browser-address`, `browser-back`,
  `browser-forward`, `browser-reload`, `browser-open-system`,
  `browser-force-proxy`, `browser-proxy-badge`, `browser-address-error`.
- [ ] **5.2** NEW `src/apps/desktop/src/components/views/BrowserView.vue` — owns
  the probe/fetch lifecycle, the request token, the `message` listener, history
  calls, and the three bodies (frame / blank page / error page):
  * reads the target from `useTabsStore().activeTab` (it is rendered by the
    chain, so the active tab IS its target — same assumption `TabBar.titleOf`
    makes);
  * probe → `frameable` decides the path; `probe=0` when proxied;
  * `<iframe :key="frameKey">` — direct: `sandbox="allow-scripts allow-same-origin allow-forms"`;
    proxied: `sandbox="allow-scripts"` and `:srcdoc`;
  * a comment block stating the sandbox rule (§3.3) so nobody "fixes" the
    asymmetry later;
  * `frameKey = url + '|' + mode + '|' + reloadNonce`;
  * blank page: app name, "Chats" button (focus the home tab via
    `tabsStore.openHomeTab()` + emit navigate), recent history list, one hint;
  * error page: status, reason, "Open in system browser", "Try the proxied view";
  * a `data-testid="browser-frame"` and `data-browser-mode="direct|proxied"` for tests.
- [ ] **5.3** `components/AppLayout.vue` — add the branch to the **existing**
  `v-else-if` chain, first (browser has no store-backed identity, so nothing can
  shadow it, but first also guarantees it can never stack with a workspace view):
  ```html
  <BrowserView v-else-if="currentView === 'browser'" class="flex-1 flex flex-col overflow-hidden" />
  ```
  Place it directly after `<TabBar>`'s overlay block and **before**
  `KanbanSettingsView` (`AppLayout.vue:2526`), with a comment recording *why*
  (`currentView` needs no new branch — it falls through to
  `route.query.view`, `:946-948`).
- [ ] **5.4** Import `BrowserView` lazily? **No** — the other heavy views are
  static imports; a `defineAsyncComponent` here would be the only one and would
  race the chain. Static import, matching `KanbanView`/`DesignView`.
- [ ] **5.5** `composables/useCurrentMainView.ts:38-52,54-115` — add
  `{ kind: 'browser'; url?: string }` and the `view === 'browser'` branch, so the
  sidebar's active-row logic has an explicit answer instead of `kind: 'none'`.
- [ ] **5.6** NEW `__tests__/BrowserChrome.spec.ts` — emits on Enter with the raw
  text, disabled Back/Forward at the ends, the error slot renders a refused
  scheme, the badge/toggle only render in proxied mode.
- [ ] **5.7** NEW `__tests__/BrowserView.spec.ts` — with `api.getBrowserPage`
  mocked: direct mode for `frameable: true` (assert the `sandbox` attribute
  contains `allow-same-origin`); proxied mode for `false` (assert `srcdoc` and
  that `sandbox` does **not** contain `allow-same-origin`); the 415/413/403/504
  error paths render the error page; a stale response for an abandoned URL does
  not paint (token); the `browser-frame-nav` message navigates the tab; a
  fragment-only message does not; unmount removes the listener (spy on
  `removeEventListener`); Reload bumps the key.

**Acceptance:** `pnpm exec vitest run BrowserChrome.spec.ts BrowserView.spec.ts` green.

### Task 6 — `openExternal` and the call sites

- [ ] **6.1** NEW `src/apps/desktop/src/helpers/openExternal.ts` — the contract in
  §4.4, plus `isHttpUrl` reused from `browserUrl.ts` (one allowlist, not two).
- [ ] **6.2** NEW `__tests__/openExternal.spec.ts` — tab mode on + http(s) ⇒
  `openBrowserTab` called, `window.open` **not** called; tab mode off ⇒
  `window.open(url, '_blank', 'noopener')`; blob/`javascript:` ⇒ `window.open`
  path unchanged (this is what keeps `PreviewContentRenderer` correct).
- [ ] **6.3** `ChatView.vue:887` and `NalarSettings.vue:549` — swap to
  `openExternal(...)`; update the two specs that spy on `window.open`
  (`NalarSettings.spec.ts:446-472` asserts the old call; flip it to a
  tab-mode-off/mocked-store assertion).
- [ ] **6.4** `PreviewContentRenderer.vue:210` — **leave as-is**, with a one-line
  comment saying why (`blob:` is same-origin; the browser tab only takes http(s)).
- [ ] **6.5** `AppLayout.tabs.spec.ts` — add: `+` opens a browser tab and the URL
  carries `view=browser` + `tab=<id>`; a deep link
  `?view=browser&url=…` creates exactly one browser tab beside the boot home tab
  and renders `BrowserView` (stub it like the other views,
  `AppLayout.tabs.spec.ts:92-121`); closing a browser tab lands on the right
  neighbour; a browser tab and a workspace tab do not shadow each other
  (chain-order regression); with tab mode off, `?view=browser&url=…` still renders
  with no strip.
- [ ] **6.6** Re-verify the client-only rule (§5): `?tab=` must not appear in the
  proxied URL or in any API call — grep
  `helpers/buildTaskUrlQuery.ts` / `helpers/buildItemIdWithChat.ts` for `tab`
  (0 hits, unchanged), and add a BrowserView test asserting the `getBrowserPage`
  call URL contains `url=` and no `tab=`.

**Acceptance:** `pnpm exec vitest run openExternal.spec.ts AppLayout.tabs.spec.ts
TabBar.spec.ts` green; `rg "window.open" src/apps/desktop/src` shows exactly two
production hits, both inside `openExternal.ts` and `PreviewContentRenderer.vue`.

### Task 7 — TabBar: glyph and title

- [ ] **7.1** `TabBar.vue:38-45` — `browser: '🌐'` (the `Record<TabKind, string>`
  is exhaustive: this line is what makes the build fail without it).
- [ ] **7.2** `titleOf` (`:73-99`) — for `kind === 'browser'`, prefer a
  store-recorded page title when present, else `hostOf(query.url)`, else
  `New tab`. (The page title is written back by `BrowserView` via the existing
  `setTabTitle` — `stores/tabs.ts:541-560` — the same mechanism the SSE feed and
  the chats list already use.)
- [ ] **7.3** `TabBar.spec.ts` — glyph for a browser tab; title = host; title =
  page title once the view reports one; blank tab labelled `New tab`; `+` opens a
  browser tab (the deliberate flip from §1.2).

**Acceptance:** `TabBar.spec.ts` green; the strip shows 🌐 + host for a browser tab.

### Task 8 — API client

- [ ] **8.1** `src/apps/desktop/src/api/index.ts` — NEW typed call mirroring
  `getWebStatus` (`:3915`):
  ```ts
  export interface BrowserPage {
    ok: boolean; url: string; final_url: string; status: number; title: string;
    content_type: string; frameable: boolean; frame_block_reason: string | null;
    html: string | null;
  }
  export async function getBrowserPage(url: string, opts?: { probe?: boolean }): Promise<BrowserPage>
  ```
  Must use `silent: true` (`api/index.ts:20-24`) — a 403/415 must not fire a
  global error toast; the view renders the error inline. Encode `url` with
  `encodeURIComponent` and append `probe=1|0`.
- [ ] **8.2** NEW `src/apps/desktop/src/api/__tests__/browserPage.spec.ts` — nothing
  there covers `getWebStatus` today (the directory holds
  `backgroundProcesses.spec.ts` + `sseSkills.spec.ts`), so add a small spec:
  the encoded query string (`url` percent-encoded, `probe=1`), the `silent: true`
  flag, and that the parsed body is returned typed.

**Acceptance:** `pnpm exec vitest run` in `src/apps/desktop/src/api/__tests__` green.

### Task 9 — Documentation

- [ ] **9.1** `docs/tabs.md` — extend: the kind table (`:107-134`) with the
  `browser` key shape; the tab-labels section (`:141-163`) with the
  title-source rule; the storage section (`:165-184`) with
  `nalar-browser-history:v1:<windowId>`; the gestures table (`:14-25`) with
  `Shift+Alt+B`; the "Turning it off" paragraph (`:194-205`) with "a browser tab
  still renders as a plain view with the strip off"; the Files table (`:221-235`)
  with the two new components and the three new helpers/tests.
- [ ] **9.2** `docs/SPEC.md` — add `§3.7.12 In-app browser tab` (goal, the two
  render paths, the `GET /api/browser/page` contract incl. the SSRF guard, the
  sandbox asymmetry, the `+` change, files, `**Plan:** docs/superpowers/plans/2026-09-14-in-app-browser-tab.md`)
  and a PR index row (`:919+`). Do **not** rewrite the superseded history — the
  file's own convention is to append and mark superseded.
- [ ] **9.3** Append `## Implementation status` to **this** plan when the work
  lands (house style: `2026-09-13-tab-mode-like-a-browser.md:3-7`).

### Task 10 — Gates and wire verification

- [ ] **10.1** NEW `tests/functional/browser_page_api_test.py` using
  `tests/functional/harness.py` (`FunctionalHarness.boot(...)` + `h.http(...)`,
  cf. `tests/functional/desktop_webapp_404_test.py`). **No external network.** The happy path
  is covered by the injected fetcher in Task 2.8; this file pins the **wire**:
  * `GET /api/browser/page` with no `url` → **400**, JSON `{"error": …}` and
    `Content-Type: application/json` (proves the route is registered and is not
    the SPA fallback — a missing route would return `index.html`/404, the exact
    class of bug the harness exists to catch);
  * `url=ftp://example.com/` → 400; `url=javascript:alert(1)` → 400;
  * `url=http://127.0.0.1:<harness port>/api/ping` → **403** (the SSRF guard, over
    the real wire, against the app's own server);
  * `url=http://169.254.169.254/latest/meta-data/` → 403 (metadata endpoint);
  * `url=http://localhost/` → 403;
  * the response never contains `Access-Control-Allow-Origin` (the CORS posture
    in §5).
  The harness picks a free port in 8080..8199 and never touches 8081.
- [ ] **10.2** Cross-platform build proof (the repo's standing requirement):
  `zig build-obj -fno-emit-bin -target x86_64-windows-gnu -lc …` and
  `… -target aarch64-macos -lc …` for the touched modules, plus
  `zig build test --summary all`.
- [ ] **10.3** `pnpm --dir src/apps/desktop test` — full suite; compare against the
  baseline recorded before Task 1. `pnpm --dir src/apps/desktop run build`
  (vue-tsc + vite) and `pnpm --dir src/apps/desktop run lint:check` clean.

---

## 7. Follow-up (explicitly NOT in this plan)

Fully specified here so it can be picked up without re-research:

1. **Real page titles + full fidelity for every site: a second native webview.**
   The vendored `webview/webview` C API is already bound for `set_html`, `eval`,
   `bind`, `get_window` (`webview_lib.zig:69-73`) but unused, and `runWindow`
   owns `create → navigate → run` in one blocking call (`:119-126`). A second
   browsing context means: a non-blocking event loop, one `webview_t` per browser
   tab, per-OS window parenting (GTK/WKWebView/WebView2), and a Zig↔JS bridge for
   the address bar. That is a multi-week, per-OS project — and it is the only way
   to get real page titles, working logins, downloads and DevTools.
2. **Downloads, uploads, form POST through the proxied path, `target=_blank` from
   the direct path** (needs `allow-popups` + a shell-level "new window" handler,
   which does not exist).
3. **Favicons** in the strip (needs a fetch + cache; the host glyph is honest
   today).
4. **Per-tab proxy mode as a setting** (`always proxy` for privacy) rather than
   the per-tab force toggle.
5. **A downloads/logins story for the proxied path** — a cookie jar + a session
   isolation model. Deliberately absent: forwarding the user's cookies to an
   arbitrary host from a loopback endpoint is a security decision, not a feature.
6. **Tab duplicate / pin / mute** — the strip has no concept of these yet.

---

## 8. Edge cases (each needs a test)

| # | Case | Expected | Covered by |
|---|---|---|---|
| 1 | Same URL opened twice | The existing tab is focused, no duplicate (documented deviation from Chrome, §1) | 4.7 |
| 2 | Blank `+` pressed twice | Second press focuses the one blank browser tab | 4.7 |
| 3 | `javascript:` / `data:` / `file:` typed | Inline error, no navigation, no request | 1.2, 5.6, 10.1 |
| 4 | `http://127.0.0.1:<app port>/api/ping` | 403 error page; the app never frames itself (no self-API read, no recursion) | 10.1 |
| 5 | `http://169.254.169.254/…` | 403 | 10.1 |
| 6 | `localhost`, `*.local` | 403 | 10.1 |
| 7 | Redirect chain ending on `file:` | 502, no frame | 2.8 |
| 8 | Upstream 404/500 with an HTML body | Body **renders** (browsers do); no error page — only transport/scheme/policy failures produce one | 5.7 |
| 9 | Body > 2 MiB | 413 error page + "Open in system browser" | 2.8, 5.7 |
| 10 | `application/pdf` / `image/png`, frameable | **Direct** path renders it (the 415 gate applies to the proxied path only) | 2.8, 5.7 |
| 11 | `X-Frame-Options: DENY` | Proxied path, badge shown, links still navigate via the relay | 2.8, 5.7 |
| 12 | `frame-ancestors 'none'` / another origin | Not frameable | 2.8 |
| 13 | Probe says frameable, engine refuses anyway | The force-proxy toggle recovers; error/blank frame is recoverable in one click | 5.7 |
| 14 | User leaves a URL while the probe is in flight | The stale response never paints (monotonic token) | 5.7 |
| 15 | Reload with an unchanged URL | `frameKey` changes ⇒ a real re-navigation (URL alone would not) | 4.7, 5.7 |
| 16 | URL with a fragment only (`#a` → `#b`) | No re-fetch | 5.7 |
| 17 | URL containing `&` and `#` | The router encodes it; the API receives the exact URL; `?tab=` never leaks into it | 6.6, 8.2 |
| 18 | Close a browser tab, `Shift+Alt+Z` reopen | Same tab id ⇒ history intact | 4.7 |
| 19 | Full app reload with a browser tab active | Tab restored from `localStorage`, probe re-runs, page loads | 4.7, 6.5 |
| 20 | Corrupt `nalar-browser-history:v1:*` | Treated as empty, never throws | 4.7 |
| 21 | Tab mode off | `?view=browser&url=…` still renders; `openExternal` falls back to `window.open` | 6.2, 6.5 |
| 22 | `+` pressed | Blank browser tab, address bar focused | 6.5, 7.3 |
| 23 | Proxied page with an existing `<base href>` | Left untouched | 1.2 |
| 24 | Proxied page with a relative `<img src>` | Resolves against the real origin (base injected) | 1.2 |
| 25 | `target="_blank"` link in a proxied page | Opens a **new in-app browser tab** | 5.7 |
| 26 | 50-tab cap reached with browser tabs open | Oldest non-active evicted; the active browser tab never evicted | 4.7 (existing `enforceLimit`) |

---

## 9. Risks

| Risk | Impact | Mitigation |
|---|---|---|
| The proxy becomes a mini web-proxy that rots as sites change | Broken pages on the fallback path | The proxy is a **fallback**, never the primary path; the direct iframe carries the common case; the badge + system-browser button set expectations |
| SSRF from the new outbound-fetch endpoint | Local API / metadata read from the renderer | Scheme allowlist + private-range blocklist + final-URL revalidation + no credentials + cap + timeout; pinned over the real wire in 10.1 |
| Third-party cookies / storage blocked in WebKitGTK | Logged-in sites stay signed out inside the app | Direct path keeps the site's own origin; document the limit; system-browser escape hatch |
| Proxied pages' JS breaks (NULL origin ⇒ `fetch`/XHR blocked by CORS) | Some sites look partly broken | Badge states it; force-direct toggle; out of scope in §7.5 |
| `frameable` prediction disagrees with the engine | Blank/failed frame with no explanation | Force-proxy toggle + error page with both escape hatches |
| Engine differences (WebKitGTK vs WKWebView vs WebView2) in `sandbox` handling | Inconsistent behaviour across OSes | Capability-independent design (no engine APIs), honest banner, and a documented fallback: "if this page looks wrong, open it in your browser" |
| Proxy returns hostile HTML into our own document | XSS in the app | The proxied body only ever enters a `srcdoc` frame **without** `allow-same-origin` — NULL origin, no parent access (the `PreviewContentRenderer` contract, `:37-42`) |
| A future CSP on the app shell would block our own frames | Feature dies silently | Noted in Task 3's comment; §7 does not add one; if a CSP ever lands it must allow `frame-src http: https:` |
| Buffered bodies + 50 ports of tabs | Memory | 2 MiB cap, `probe` downloads no body, history entries are capped strings |
| Changing `+` surprises existing users | Small UX regression | §11 Q1 (one-line flip); `openHomeTab()` retained and linked from the blank page |

---

## 10. Rollback

* **Feature level:** the whole feature is additive — a new kind, a new view, two
  new components, three new helpers, one new handler, two rerouted call sites.
  `git revert` of the implementation commits restores today's behaviour exactly.
* **Storage level:** `TABS_VERSION` is untouched, so no user's strip is ever
  discarded. The new `nalar-browser-history:v1:<windowId>` key is ignored by old
  code (separate key, never read there) — it just becomes dead bytes, cleared by
  Settings' existing "reset tabs" path or by hand.
* **Stale targets after a revert:** a persisted `?view=browser&url=…` tab would
  render an empty main area (an unknown `view` already renders nothing today —
  pre-existing behaviour, not introduced here). Recovery is one click: Settings →
  General → toggle browser-style tabs off/on, whose `setEnabled` path plus
  `resetToHome` (`stores/tabs.ts:585-593`) rebuilds a clean single-home list.
* **Degraded rollback (be aware):** if only the *backend* handler is reverted and
  the frontend stays, every browser tab shows the error page — no crash, no
  silent breakage, and the system-browser button still works. If only the
  *frontend* is reverted, the endpoint is simply unused.
* **Per-commit boundaries** (so a partial revert is possible): Task 1 helpers,
  Task 2 backend, Tasks 3–4 tab identity + store, Task 5 view, Task 6 reroutes,
  Tasks 7–8 chrome/API, Task 9 docs, Task 10 tests.

---

## 11. Verification (manual, after implementation)

Backend on **8080** (never 8081), UI via `pnpm --dir src/apps/desktop dev` (5173)
with `VITE_API_PROXY_TARGET=http://localhost:8080`. Tab mode on (default):

- [ ] `+` opens a **blank browser tab** with the address bar focused and the tab
  labelled `New tab` / 🌐; the previous tab stays open beside it.
- [ ] Type `example.com` → the page loads **directly** (no proxy badge), the tab
  label becomes `example.com`, Back is enabled.
- [ ] Type `github.com` → proxied badge appears, the page renders with its
  layout/images; click a link inside it → the tab's URL updates and the new page
  loads (relay works); Back returns to the previous one.
- [ ] Type `127.0.0.1:8081` → 403 error page, not the app inside itself.
- [ ] Type `javascript:alert(1)` → inline error under the bar, nothing navigates.
- [ ] Type `hello world` → DuckDuckGo search results.
- [ ] Reload on an unchanged URL genuinely re-fetches (watch the request).
- [ ] Close the browser tab → the right neighbour activates; `Shift+Alt+Z` reopens
  it with Back history intact; the full app reload restores it and reloads the page.
- [ ] Create a PR from a chat → the PR URL opens in a **new in-app browser tab**
  (not the OS browser).
- [ ] Settings → "Open web" → in-app browser tab.
- [ ] Settings → General → turn browser-style tabs **off** → the strip disappears
  but a `?view=browser&url=…` URL still renders and browses; the PR-link click
  falls back to the OS browser.
- [ ] Non-goal sanity: "Open in new tab" on an HTML chat preview still uses the
  system browser (documented).

### Open questions for the reviewer (neither blocks the plan)

**Q1 — `+` opens a blank browser tab (locked default) vs. keeping `+` for the
chats list.** The plan locks the change because the card asks for it. The
alternative is a one-line flip: keep `newTab()` = `openHomeTab()` and add a
separate 🌐 button (or a `Shift+Alt+B`-only affordance) for the browser tab. Say
the word and Task 4.5/Task 7.3 change; nothing else in the plan moves.

**Q2 — the proxied path's honesty.** A proxied page is not a normal browser page:
no sign-in, no `fetch` from the page's own JS. The plan shows a badge. The
stricter alternative is to **refuse** to render framing-hostile sites at all
(error page + "open in your browser"), i.e. drop Tasks 2.5's proxy body and the
relay script. That would roughly halve the backend work and remove the SSRF
surface entirely — at the cost of "the browser tab doesn't open github.com".
Recommendation: keep the proxy (a browser that cannot open github is not a
browser), but this is a genuine product call.

**Q3 — omnibox search provider.** DuckDuckGo is the default; a settings field is
out of scope. Confirm the provider or name a different constant.

---

## Implementation status

**Not started.** This document is the planning artefact only. When the work
lands, append the shipped/deviated/gates sections here (house style).
