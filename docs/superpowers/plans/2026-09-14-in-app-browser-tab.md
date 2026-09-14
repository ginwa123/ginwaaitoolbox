# In-app browser tab (a new tab that is literally a browser)

> **Status: PLAN ONLY — not executed.** Rev 2 (2026-09-14) — the reviewer's
> answers are locked in §1.3. Awaiting the final go-ahead at
> `in_review_planning`. Nothing in this document has been implemented; every line
> number below was verified by reading `main` at `b7c2d39e`.
>
> **Plan PR:** #489, branch `worktree/task-1789376475404` (docs only — merging it
> lands this plan, not the feature).
>
> **Reviewer answers, locked 2026-09-14 (task owner):**
> * **Q1 → a blank browser tab.** `+` / `Shift+Alt+T` opens the browser new-tab
>   page (§1.2 is therefore the intended change, not a pending question).
> * **Q2 → keep the fallback path.** "I want the in-app browser to browse like a
>   regular browser — search Google, open GitHub." That is exactly what the two
>   render paths deliver for *reading* the web; §1.3 states plainly what a regular
>   browser does that this cannot (sign-in), and §7.1 is the route that closes it.
> * **Q3 → Google.** The omnibox search provider is Google.

> **For agentic workers:** this is a *planning* artefact. Before implementing, use
> subagent-driven-development / executing-plans. Steps use checkbox (`- [ ]`)
> syntax for tracking.

**Task:** `task_1789376526556_0` — *"in browser app is a feature to open a new tab,
but literally a browser"*.

**Goal:** make a tab in the existing browser-style strip able to hold **a real web
page** — its own address bar, back / forward / reload, and the page rendered
inside the app — so that:

1. `+` (and the existing `Shift+Alt+T`) opens a **blank browser tab** with the
   address bar focused, not the chats list;
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
| Fallback render path | **Server-proxied HTML into `<iframe srcdoc>`** — used when the probe says the site refuses framing. **Confirmed by the reviewer** | `X-Frame-Options: DENY` / `frame-ancestors` is the single most common reason an in-app browser looks broken — google.com, github.com and most banks all send it. Without this fallback those sites do not open at all; with it they open as readable pages. **A plain-language answer to Q2 is in §1.3** — the reviewer asked what the question even meant, and it is the difference between "GitHub opens" and "GitHub is an error page". |
| Who decides which path | **The Zig backend, from the real response headers** | The parent page cannot read a cross-origin frame's `contentDocument`, so a block is undetectable client-side. The backend can read `X-Frame-Options` + every `Content-Security-Policy` header on the **final** response and evaluate `frame-ancestors` against our **exact** origin (`http://127.0.0.1:<port>`). Deterministic, testable, no guessing. |
| New tab kind | `'browser'` added to `TabKind` (`helpers/tabTarget.ts:26`) | `TabKind` is the existing closed union; `GLYPHS` in `TabBar.vue:38-45` is an exhaustive `Record<TabKind, string>`, so the compiler forces every switch to be handled. |
| Tab URL shape | `path: '/app'`, `query: { view: 'browser', url: <absolute-url> }`; `url` **absent** = the blank new-tab page | Mirrors the existing query-only views (`view=workspace`, `view=chat`). No router change: `/app` already matches (`router/index.ts:12-15`) and the catch-all stays last (`:47-50`). A path route (`/app/browser`) was rejected — it would need a new `currentView` regex *and* a new router entry for zero benefit, and `tabTarget.ts` already has two path-based special cases (`SETTINGS_PATH`, `KANBAN_SETTINGS_RE`) that are pure debt. |
| Tab identity | `tabKeyOf` returns `browser:<url>` (blank ⇒ `browser:new`) | Key-based dedupe is the strip's contract. Consequence: **opening the same URL twice focuses the existing tab** instead of making a second one — a deliberate deviation from Chrome (§8 #1). A unique-per-tab key would need the tab id inside the key, which breaks the pure-function/adoption design (`tabTarget.ts:160-187`). |
| Page title | `title` from the proxied HTML when we have it, else the **hostname**, else `New tab` | We cannot read `<title>` out of a cross-origin frame. Honest label beats a stale one. §7.1 is what fixes this properly, with a shell-owned browser view. |
| Per-tab history | Back / forward stacks in a **separate** localStorage key, not inside `Tab` | `TABS_VERSION` stays `1`. Bumping it makes `parseTabList` (`tabTarget.ts:399-437`) throw every existing user's strip away — unacceptable for an additive feature. Separate key also means old code ignores it. |
| Address-bar input with no scheme | **`https://www.google.com/search?q=<encoded>`** (Q3) | A browser's omnibox searches — the reviewer confirmed Google. One exported constant, so a region where Google serves its cookie-consent interstitial can be swapped in one line (§9). |
| Search-box Enter inside a **proxied** page | The relay intercepts `method="GET"` form submits and navigates the tab to the resolved URL | Without it, pressing Enter in the site's own search box does nothing (the frame's own submit cannot reach the network under a NULL origin). This is what makes "search Google" work whether the query is typed in our omnibox or in the page's box. `method="POST"` forms are refused with a visible banner instead of failing silently. |
| Allowed schemes | `http:` and `https:` **only** | `javascript:`, `data:`, `blob:`, `file:`, `about:` are refused in the address bar *and* in the handler. `file:` in particular would turn a UI field into arbitrary local-file read. |
| Proxy credentials | **None.** No cookies, no `Authorization`, no client certs forwarded | The endpoint is anonymous-fetch only. **This is the one ceiling of the whole feature:** signing in to Google/GitHub inside the proxied path does not work. Stated in the UI (§4.5), in the expectations table (§1.3), and closed properly only by §7.1. |
| `+` / `Shift+Alt+T` | **Opens the blank browser tab** (a change to today's behaviour) — **confirmed by the reviewer (Q1)** | The card asks for it: "open a new tab, but literally a browser". A browser's `+` gives a blank page with a focused omnibox, not a bookmarks list. The chats list is not lost: it is still the boot tab and the last-tab-closed fallback (`homeTab()`, `tabTarget.ts:328-342`), still one click away in the sidebar, and linked from the blank page. |
| Tab mode toggle off | The browser tab **still works as a plain view**; only the strip disappears | `syncFromTarget` already returns the raw target when `enabled === false` (`stores/tabs.ts:437-440`) and `currentView` is independent of the toggle, so `?view=browser&url=…` renders with no strip. `openBrowserTab()` degrades to `window.open(url, '_blank', 'noopener')` so the click-to-open call sites (§4.4) keep working. |
| Toolbar extras | Back, Forward, Reload, **Open in system browser**, and (proxied only) a "Force direct / Force proxied" toggle | Reload alone is not enough when a page renders badly: the user needs one click out. The force toggle is the escape hatch for a wrong `frameable` verdict. |
| Not in v1 | Downloads, **`method="POST"` forms** (GET forms are relayed — see above), `target=_blank` popups from the direct path, sign-in/OAuth, favicons, DevTools, per-tab zoom, tab pinning/muting | Each is a separate feature. §7 records them so they do not need re-research; §7.1 is the one that turns this into a *fully* regular browser. |

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
the boot tab and the last-tab-close fallback.

### 1.3 "Like a regular browser" — what works, and where it stops

Q2 in rev 1 was poorly worded, so here it is without jargon. **A web page can end
up inside our tab in one of two ways, and the *site itself* decides which:**

* **Way A — we hand the URL straight to the browser engine.** The page is a real,
  normal page: its own cookies, its own scripts, its own logins. We are allowed to
  do this only for sites that do not forbid being embedded. Many sites do forbid
  it (Google and GitHub both do — that is a header they send, not our limitation).
* **Way B — our backend downloads the page and we show it.** This is the fallback
  that makes Google and GitHub open at all. The page's text, images, styles and
  its own JavaScript still load; what does not work is anything that needs to be
  *signed in* or that calls the site's private API, because for security we send
  no cookies and store nothing.

Concretely, for the two sites the reviewer named:

| What you do | Result |
|---|---|
| `github.com` → a repo page | **Works** (way B): it renders with its layout and images, links work, Back/Forward work, opening a link in a new tab works |
| `github.com` → sign in, open a PR, comment | **Does not work** (way B): no cookies, and the sign-in form is a POST |
| `github.com` → the dynamic bits (notifications dropdown, live file tree actions) | Partly works: the scripts load, but their background requests are blocked |
| `google.com/search?q=…` from our omnibox | **Works** (way B) in most regions — Google sometimes answers a cookie-less request with its consent interstitial instead of results (§9) |
| Pressing Enter in Google's own search box | **Works** (way B): the relay forwards GET form submits (Task 1/5) |
| Opening a site that *allows* embedding (docs sites, blogs, wikis, most `*.github.io`, example.com) | **Works fully** (way A): real cookies, real scripts, real sign-in where the site offers it |
| Downloading a file, uploading a file | **Does not work** in either way (v1) |
| Logging in anywhere on a way-B page | **Does not work** — the single hard ceiling of this design |

So: **reading the web, searching, following links, multiple tabs, history and
restore — yes.** Being signed in everywhere — **no**, and no amount of frontend
work changes it, because the limit is the engine's own iframe policy. The only
thing that removes that ceiling is a browser view owned by the desktop shell
itself instead of by the page (§7.1, a multi-week per-OS project, deliberately not
part of this plan).

### 1.4 Why an in-page browser hits a wall — the mechanism, measured

Asked directly by the reviewer: *"why we cannot act like a browser?"* Here is the
whole answer, with headers fetched over the wire on 2026-09-14:

```
$ curl -sI https://github.com/          → x-frame-options: deny
                                          content-security-policy: … frame-ancestors 'none' …
$ curl -sI https://www.google.com/      → x-frame-options: SAMEORIGIN
$ curl -sI https://example.com/         → (no framing headers)
$ curl -sI https://docs.python.org/3/   → (no framing headers)
```

1. **The app already *is* a browser engine.** The desktop shell is WebKitGTK /
   WKWebView / WebView2 rendering our Vue SPA. There is no missing engine, no
   missing network stack, no missing HTML/CSS/JS support.
2. **What it is missing is a second *top-level* browsing context.** Our engine view
   is occupied by the app itself. Showing a site *and* keeping the app on screen at
   the same time needs a second context, and there are only two places to put one:
   **(a) nested inside our document** — that is an `iframe`, and **(b) a sibling
   native view in the window** — that is what §7.1/§7.2 are, and it is native
   shell code, not HTML.
3. **The `iframe` route is where GitHub and Google say no — and it is enforced by
   our own engine.** `X-Frame-Options` / `frame-ancestors` are **anti-clickjacking
   policies for nested browsing contexts**; the engine checks them inside the
   browser process, before layout, and there is deliberately no JS API, no config
   flag and no setting to bypass them. The sender for both sites is measured above.
   This is not a Nalar limitation — **a real Chrome fails the same way**, which is
   why "open github.com in an iframe" is refused in any ordinary browser too.
4. **So a page either gets a top-level context (real browser, needs native views)
   or it gets `way B` (our backend fetches it, and we are then a *substitute* for
   the browser's network layer — no cookies, no page origin, no POST, no
   downloads).** There is no third option that is both safe and richer; the
   tempting one (serve the proxied page from our own origin so the frame is not
   third-party) is analysed and rejected in §7.3 — it hands a hostile page our
   app's origin and API.
5. **The `way B` claims were checked, not assumed.** A cookie-less fetch of
   `https://www.google.com/search?q=zig+lang&num=10` returned 91 KB of
   server-rendered HTML containing result markup and **no** consent/CAPTCHA/
   "enable JavaScript" interstitial — so the reviewer's "search Google" case really
   does render through the fallback path (in this region; §9 keeps the caveat).

The short version: **browsers are allowed to show anything because a tab *is* a
top-level view. A page inside a page is not, and that rule is the web's, not
ours.** We can be that top-level view — that is §7.1 (in the strip, multi-week) or
§7.2 (its own window, small). What we cannot do is make an `iframe` behave like a
tab.

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
| **Blank tab** (`url` absent) | Small new-tab page: the app name, a **"Search Google" box** (the omnibox's sibling, same code path — typing here and pressing Enter runs a Google search), a "Chats" shortcut (focus the home tab), the recent browser history list, and one hint line — no borrowed content |
| **Proxied badge** | One honest line: *"Limited view — sign-in and some actions are unavailable"* + the system-browser button. Without it the degraded path looks like a bug (precedent: the `show_preview` white-page exception is documented at `docs/superpowers/plans/2026-09-13-html-frame-theme-and-height.md:141-145`) |
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
* **`submit` on a `method="GET"` form** (capture phase): resolve the form's action
  against the document base, append the serialized fields as a query string, then
  `preventDefault()` + post `{ source: 'browser-frame-nav', url }`. This is what
  makes the site's *own* search box work — including Google's, which is a plain
  `GET /search?q=…` form — instead of silently doing nothing under a NULL origin.
* **`submit` on a `method="POST"` form**: `preventDefault()` + post
  `{ source: 'browser-frame-nav', blocked: 'post' }` → the parent shows a one-line
  banner ("This form cannot be submitted in the in-app browser") plus the
  system-browser button. Failing loudly beats failing silently.
* `GET` submits work because a query-string navigation is an ordinary page load we
  can re-probe and re-fetch; a `POST` body cannot be replayed by the parent.

The parent listens for source tag `browser-frame-nav` only (never the two
existing tags), resolves the sender by `contentWindow === event.source`
(`findSenderFrame`), records history and re-runs the probe+fetch for the new URL.
The listener is registered/unregistered in `onMounted`/`onUnmounted` — the same
paired lifetime as `PreviewContentRenderer.vue:109-119`.

On the **direct** path none of this runs: the frame is a normal document with its
own origin, so links, forms, cookies and logins are the engine's business, exactly
as in a browser.

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
    (`SEARCH_URL_TEMPLATE = 'https://www.google.com/search?q='`, exported so a test
    and a future setting can both see it — Q3);
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
    Intercepts (a) link clicks, (b) `method="GET"` form submits (resolve action
    against the base, append `URLSearchParams` of the fields → post the URL),
    (c) `method="POST"` form submits (post `blocked: 'post'`, no navigation).
  * `resolveGetFormTarget(action: string, base: string, fields: Array<[string, string]>): string`
    — the pure half of (b), so the form logic is unit-testable without a DOM.
  * `frameAncestorsAllows(cspHeaderValue: string, appOrigin: string): boolean | null`
    — `null` when the directive is absent, used by tests to pin the matrix.
- [ ] **1.2** NEW `src/apps/desktop/src/__tests__/browserUrl.spec.ts` — table-driven
  specs for every branch above, including: `javascript:`/`data:`/`file:` refused;
  `example.com` → `https://example.com`; `example.com:3000/a?b=c` keeps its port;
  `hello world` → the **Google** search URL; `injectBaseHref` leaves an existing
  base; the relay script escapes its own closing tag; `resolveGetFormTarget`
  (relative action, absolute action, empty action, special chars in a field, an
  existing query on the action); `frameAncestorsAllows` matrix (`*`, `'none'`,
  exact origin, other origin, `'self'`, two directives, absent).
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
- [ ] **4.6** **No new shortcut.** `Shift+Alt+T` already maps to `newTab`
  (`composables/useTabShortcuts.ts`, the guaranteed `Shift+Alt` namespace —
  `docs/tabs.md:38-55`) and the handler map lives at `AppLayout.vue:2337-2366`;
  once Task 4.5 lands, that shortcut opens the browser tab with no change at all.
  Add a `resolveTabShortcut` test asserting `Shift+Alt+T` still resolves to
  `newTab` (so a future refactor cannot silently repoint it).
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
  * blank page: app name, a **"Search Google" input** (same
    `normalizeAddressInput` + `navigateBrowserTab` path as the omnibox, so there is
    one search implementation), a "Chats" button (focus the home tab via
    `tabsStore.openHomeTab()` + emit navigate), recent history list, one hint;
  * the proxied banner hosts the `blocked: 'post'` message ("This form cannot be
    submitted in the in-app browser" + system-browser button) — a DOM banner,
    not an `alert`;
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
  fragment-only message does not; a `blocked: 'post'` message renders the banner
  and does not navigate; the blank page's Search Google box navigates a Google
  search URL; unmount removes the listener (spy on `removeEventListener`); Reload
  bumps the key.

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
  `nalar-browser-history:v1:<windowId>`; the gestures table (`:14-25`) with the
  new meaning of `+` / `Shift+Alt+T` and the blank tab's Search Google box; the
  "Turning it off" paragraph (`:194-205`) with "a browser tab
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

Fully specified here so it can be picked up without re-research.

### 7.1 The full fix: a browser view **in the window**, so the tab really is a tab

This is the honest answer to "browse like a regular browser" in the strong sense
(Google/GitHub **signed in**, downloads, any site, no proxy). It is not a
frontend change — it moves browser-tab ownership out of the SPA and into the
desktop shell:

* **What blocks it today.** The shell opens exactly one `webview_t` and blocks in
  `webview_run` (`desktop_app/main.zig:300-306`, `webview_lib.zig:119-126`). The
  engine *can* host more views, and the C API is already bound
  (`webview_set_html`, `webview_eval`, `webview_bind`, `webview_get_window` —
  `webview_lib.zig:69-73`, all unused), but the shell never creates a second one
  and cannot position a native widget inside DOM content — the strip is HTML, so
  the page view has to be a *sibling* of the app's own webview in the window, not
  a child of the document (§1.4).
* **The shape of the work.** A shell-owned container (GTK `GtkBox`/`GtkNotebook`
  around the existing `GtkWindow` child — `webview_get_window` already returns the
  native handle; macOS `WKWebView` as an `NSWindow` subview; Windows `WebView2` in
  a child HWND) holding one engine view per browser tab, with the SPA as just
  another view. That implies (a) a non-blocking event loop in the Zig shell,
  (b) per-OS view parenting, focus/z-order and teardown, (c) a JS↔Zig bridge
  (`webview_bind`) so the SPA can ask the shell to create/close/activate a page
  view, tell it its rectangle, and receive title/URL/loading back, (d) a decision
  about the *existing* Vue strip — two strips (native browser tabs + app tabs)
  would be incoherent, so the strip most likely becomes shell-drawn, which retires
  `helpers/tabTarget.ts`, `stores/tabs.ts`, `TabBar.vue` and their tests as the
  source of truth.
* **Effort and risk.** Multi-week, cross-platform, and it touches the shell every
  release ships. Its own plan and its own card — it should **not** be folded into
  this one, because it is a rewrite of the tab model rather than a new tab kind.
* **Recommendation.** Ship this plan first (it delivers search + GitHub + tabs +
  history in days, and none of the probe/guard/relay work is wasted — it stays as
  the "open a link" path and as the fallback for way-B pages). Then decide on 7.1
  as a separate card if sign-in matters.

### 7.2 The cheap real browser: a native **window** (sign-in works today)

Halfway between this plan and 7.1, and worth naming because it is small:

* `desktop_app/cli.zig` already builds a window from a URL
  (`webview_navigate` at `webview_lib.zig:125`); a `--browser <url>` mode skips
  attach/auto-spawn and just opens a native window on the given address.
* Spawned as its **own process** from the SPA (the shell already spawns a detached
  nalar — `attach.zig:195-206` is the pattern), it needs **no** refactor of the
  blocking loop, no bridge, no geometry sync. It is a real engine view on a real
  top-level address, so `X-Frame-Options` does not apply, cookies and sign-in work,
  downloads work, JS-heavy sites work.
* Cost: it is a **separate OS window**, not a tab in the strip, and it should get
  its own persistent website-data directory or logins are lost per launch.
* This is the option to reach for if "signed in everywhere" matters more than
  "inside the strip". It could also ship as the toolbar's "Open in system browser"
  target, replacing the OS browser with a Nalar-owned one.

### 7.3 Rejected alternative: serve the proxied page from our own origin

Worth recording so it is not re-proposed: point the iframe at
`http://127.0.0.1:<port>/browse/<encoded-url>` and have the backend reverse-proxy
the site. That *does* defeat `X-Frame-Options` (we are the server, so the frame is
not third-party), and the frame would be same-origin with the app — which is
exactly why it is rejected. Same-origin means the proxied page's JavaScript could
read `localStorage`, call `POST /api/...` as the user and drive the whole app.
Sandboxing it (`sandbox="allow-scripts"`, no `allow-same-origin`) makes it an
opaque origin again — which is precisely the way-B downgrade we already have
(no cookies, no same-origin `fetch`) — but now with a second, worse proxy in the
path. There is no version of this that is both safe and more capable than §4's two
render paths.

### 7.4 Everything else

1. **Downloads, uploads, `method="POST"` forms through the proxied path,
   `target=_blank` from the direct path** (the last two need `allow-popups` + a
   shell-level "new window" handler, which does not exist).
2. **Favicons** in the strip (needs a fetch + cache; the host glyph is honest
   today).
3. **Per-tab proxy mode as a setting** (`always proxy` for privacy) rather than
   the per-tab force toggle.
4. **A cookie/session model for the proxied path** — the reviewer did not ask for
   sign-in, and forwarding the user's cookies to an arbitrary host from a loopback
   endpoint is a security decision, not a feature. If it is ever wanted it must be
   an isolated jar with an explicit UI warning, not the app's own session — or, far
   better, §7.2/§7.1 which give a real engine view instead.
5. **Tab duplicate / pin / mute** — the strip has no concept of these yet.

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
| 27 | Enter in a site's own **GET** search box (Google's) | The relay resolves the form against the base and navigates the tab to `…/search?q=…`; results render | 1.2, 5.7 |
| 28 | Submit a **POST** form (GitHub sign-in) | Nothing navigates; a banner explains it and offers the system browser (no silent no-op) | 5.7 |
| 29 | Google answers a cookie-less proxied request with its consent interstitial | The page renders as-is (it is just a page); the user can click through it via the relay; §9 records the one-line provider swap | manual (§11) |
| 30 | A site that needs its own API calls to render at all (Google's JS-only paths) | Layout/scripts load, data calls fail ⇒ visibly partial page + the badge; system browser is the escape hatch | manual (§11) |
| 31 | Upstream ignores our `Range: bytes=0-0` probe header | One discarded download; the probe still returns metadata and the client picks the path | 2.8 |

---

## 9. Risks

| Risk | Impact | Mitigation |
|---|---|---|
| The proxy becomes a mini web-proxy that rots as sites change | Broken pages on the fallback path | The proxy is a **fallback**, never the primary path; the direct iframe carries the common case; the badge + system-browser button set expectations |
| SSRF from the new outbound-fetch endpoint | Local API / metadata read from the renderer | Scheme allowlist + private-range blocklist + final-URL revalidation + no credentials + cap + timeout; pinned over the real wire in 10.1 |
| Third-party cookies / storage blocked in WebKitGTK | Logged-in sites stay signed out inside the app | Direct path keeps the site's own origin; document the limit; system-browser escape hatch |
| Proxied pages' JS breaks (NULL origin ⇒ `fetch`/XHR blocked by CORS) | Some sites look partly broken | Badge states it; force-direct toggle; §7.4 item 1 / §7.1 |
| `frameable` prediction disagrees with the engine | Blank/failed frame with no explanation | Force-proxy toggle + error page with both escape hatches |
| Engine differences (WebKitGTK vs WKWebView vs WebView2) in `sandbox` handling | Inconsistent behaviour across OSes | Capability-independent design (no engine APIs), honest banner, and a documented fallback: "if this page looks wrong, open it in your browser" |
| Proxy returns hostile HTML into our own document | XSS in the app | The proxied body only ever enters a `srcdoc` frame **without** `allow-same-origin` — NULL origin, no parent access (the `PreviewContentRenderer` contract, `:37-42`) |
| A future CSP on the app shell would block our own frames | Feature dies silently | Noted in Task 3's comment; §7 does not add one; if a CSP ever lands it must allow `frame-src http: https:` |
| Buffered bodies + 50 ports of tabs | Memory | 2 MiB cap, `probe` downloads no body, history entries are capped strings |
| Changing `+` surprises existing users | Small UX regression | **Confirmed by the reviewer (Q1)**; `openHomeTab()` retained and linked from the blank page |
| **User-expectation gap: "regular browser" vs. no sign-in on the proxied path** | The reviewer's words were "browse like a regular browser" — a way-B page cannot sign in, and that is not fixable in the frontend | §1.3 states it in plain language up front; the badge says "Limited view"; the system-browser button is one click; §7.1 is the only real fix and is called out as its own project |
| Google serves its cookie-consent / "enable JS" page to a proxy request in some regions | "Search Google" looks broken for those users | Google is a one-line constant (`SEARCH_URL_TEMPLATE`); §11's manual checklist verifies the region you are in and the fallback is DuckDuckGo/Bing; the omnibox itself is not affected — only the *proxied* Google page is |
| Sites whose UI depends on authenticated API calls (GitHub notifications, Google account chrome) | Partially-rendered pages on the proxied path | Badge + banner; way A sites (the majority of docs/blogs/wikis) are unaffected |

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
- [ ] **GitHub (the reviewer's case):** type `github.com` → the limited-view badge
  appears, the page renders with its layout/images; open a repo (e.g.
  `github.com/ginwa123/ginwaaitoolbox`) and confirm the README + file list render;
  click a link inside the page → the tab URL updates and the next page loads;
  Back returns.
- [ ] **Google (the reviewer's case):** type `hello world` and `q=zig lang` into the
  omnibox → Google results render; then do the same from the **blank tab's Search
  Google box**; then press Enter in Google's *own* search box inside the page →
  the relay navigates the tab and results render.
- [ ] Confirm the known ceiling is *visible, not silent*: on a proxied page, a
  sign-in or POST form shows the banner and offers the system browser; nothing
  silently does nothing.
- [ ] Type `127.0.0.1:8081` → 403 error page, not the app inside itself.
- [ ] Type `javascript:alert(1)` → inline error under the bar, nothing navigates.
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

### Reviewer answers (locked 2026-09-14)

**A1 — `+` opens the blank browser tab.** Confirmed. No change to the plan.

**A2 — keep the fallback path / browsing must feel like a browser.** Confirmed, and
rev 2 of the plan does more than rev 1 did to earn that: the omnibox *and* the
blank tab search with Google, and the relay now forwards the site's own **GET**
form submits, so searching from inside a proxied page works too. The one thing
that cannot be delivered inside an iframe is **sign-in**, because the site itself
forbids being embedded and we refuse to forward your cookies to a third party from
a local endpoint. §1.3 is the plain-language statement of exactly what works and
what does not, **§1.4 explains the mechanism with the measured response headers**,
and §7.1/§7.2 are the (separate) projects that remove the ceiling. **If "signed in
everywhere" is a requirement, say so and I will write that plan as its own
card before implementation starts** — it changes who owns the tab strip, so it
should not be smuggled into this one.

**A3 — Google.** Locked as `SEARCH_URL_TEMPLATE`. §9 records the one region caveat
(Google's consent/JS-only page for cookie-less requests) and the one-line fallback.

### Still open (non-blocking)

**Q4 — do you want the §7.1 shell-owned browser planned as its own card now?** It
is the only route to sign-in/downloads/any-site fidelity *inside the strip*, and it
is a rewrite of the tab model rather than a new tab kind. Default if unanswered:
**no** — this plan ships first, and 7.1 is picked up only if the limited view proves
insufficient in daily use.

**Q5 — should §7.2 (a Nalar-owned browser *window*, `--browser <url>`) be folded
into this plan instead of being a follow-up?** It is the small option that makes
sign-in, downloads and JS-heavy sites work today, at the cost of being its own OS
window rather than a tab. Folding it in would add roughly one task here (a CLI flag
+ a spawn path + a persistent website-data dir + "Open in Nalar browser" on the
toolbar and the error page) and would give the feature a working answer for
"signed in everywhere" without waiting for 7.1. Default if unanswered: **follow-up**
(§7.2 as written).

---

## Implementation status

**Not started.** This document is the planning artefact only. When the work
lands, append the shipped/deviated/gates sections here (house style).
