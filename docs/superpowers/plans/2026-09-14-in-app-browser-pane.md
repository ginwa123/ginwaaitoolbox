# In-app browser **pane** — the page inside the app window (rev 1)

> **Status: PLAN ONLY — not executed.** Rev 1 (2026-09-14). Written in response
> to the human's report on the shipped window mode: *"okay its work, but open a
> new window… cannot integrate with existing system tab desktop nalar? so no need
> open new window."*
>
> **Relationship to the previous plan.** `2026-09-14-in-app-browser-tab.md`
> (rev 7, executed, PR #489) shipped Cursor's **separate-window** mode and
> deferred this pane to its own card (§10.2) because the plan-review answer **Q6**
> locked v1 to a window. The human's instruction supersedes Q6 for the pane: this
> plan is that card. Everything the window mode built — the flat
> `nalarBrowserOpen/Status/Close` bridge, `browser_chrome.js`, the address
> normalization, the tab kind — is reused unchanged; nothing here removes it.
>
> **For agentic workers:** this is a *planning* artefact. Use
> subagent-driven-development / executing-plans to implement it. Steps use
> checkbox (`- [ ]`) syntax for tracking.

**Task:** follow-up to `task_1789376526556_0` — *"in browser app is a feature to
open a new tab, but literally a browser"*.

**Goal:** a browser tab renders its page **inside the app window**, below the tab
strip, in the same window and the same process — no second OS window, no extra
`nalar-desktop` child. Tab switching keeps working; the page is a real top-level
webview (so YouTube, GitHub, Google and dev servers all work).

**Non-goals (v1):** the shell drawing the tab strip (the SPA keeps it); a
draggable divider (proposed off, see Q4); per-tab pane geometry persistence;
agent-driven control (§10.3 of the previous plan); more than one pane per window.

---

## 1. Why v1 was a window, and what changes now

Two measured facts forced the window design, and **neither can be solved in the
frontend** — re-measured 2026-09-14:

| Site | Framing headers | In an `<iframe>`? |
|---|---|---|
| `https://www.youtube.com/` | `x-frame-options: SAMEORIGIN` | ✖ blank |
| `https://github.com/` | `x-frame-options: deny` | ✖ blank |
| `https://www.google.com/` | CSP (no `x-frame-options`) | ✖ for search |
| `http://localhost:5173/` | (none) | ✔ |
| `https://docs.python.org/3/` | (none) | ✔ |

So an iframe pane would be blank for exactly the sites that prompted the request
(YouTube in the screenshot). And the app window holds **exactly one engine view**:

```cpp
// vendor/webview/webview.h:1885 (GTK), :2634 (Cocoa), :3617 (Win32)
gtk_compat::window_set_child(GTK_WINDOW(m_window), GTK_WIDGET(m_webview));
```

⇒ a second view needs a **container** inside the window, i.e. work in the
vendored shell. The previous plan priced that as "multi-week, per OS" without
measuring it. **Section 2 is what actually happens when you try.**

## 2. What was measured (spike, 2026-09-14, this machine)

A throwaway C++ spike (kept out of the repo) against the vendored library on
**Linux/GTK3** (`build.zig:1718,1764` link `webkit2gtk-4.1` + `gtk-3.0`) tried the
naive version: create the SPA view, move it into a `GtkBox`, then
`webview_create(0, box)` for the pane.

```
[probe] req=["spa_inner_height=1398"]
GLib-GObject-CRITICAL: invalid cast from 'GtkBox' to 'GtkWindow'
[layout] window=0x29bafa60 spa_view=0x29849bc0
[layout] pane=0x2a0fcbd0
Gtk-CRITICAL: gtk_widget_get_allocated_height: assertion 'GTK_IS_WIDGET (widget)' failed
[alloc] window=1398 spa=1398 pane=0
SPIKE FAIL: spa slot 1398px, pane 0px, spa page innerHeight 1398 -> -1
```

Three findings, all load-bearing:

1. **On GTK3 the parent call is already container-generic.** `window_set_child`
   (`:1721-1726`) is `gtk_window_set_child` on GTK4 and
   `gtk_container_add(GTK_CONTAINER(window), widget)` on GTK3 — the *only*
   blocker is the `GTK_WINDOW()` cast around it, which fails for a `GtkBox`
   (GLib-CRITICAL) and leaves the widget **unparented** (`pane=0`).
   **A ~5-line vendored change unlocks the pane on Linux** — not a multi-week
   patch.
2. **A `WebKitWebView` has a huge natural height** (the probe page reported
   `innerHeight=1398` in a 600px window). It therefore cannot be squeezed into a
   36px strip with a plain box child (`spa=1398`): each view needs a
   **scrolled-window wrapper** (or a `GtkPaned` slot with an explicit position),
   whose own minimum is small.
3. **The other two platforms differ** (read, not run):
   * **macOS** — the Cocoa ctor calls `setContentView:` **unconditionally**
     (`:2632`), even when it does not own the window: passing a container NSView
     would *replace* the SPA's view with the pane. Needs the non-owning path to
     `addSubview:` instead (~3 lines) — the line the previous plan predicted
     (`:2632`). Its destructor already guards the cleanup correctly (`:2255` only
     clears the content view when the webview *is* the content view), so the
     patch only has to `removeFromSuperview` before releasing.
   * **Windows** — `env->CreateCoreWebView2Controller(m_window, this)` (`:3617`)
     takes any `HWND`, and the window-only work is gated on `m_owns_window`
     (`:3794`, `:4025`). A **child HWND** created inside the app window should
     therefore work **with no vendored change** — but Windows has no layout
     containers, so the shell must place the two children itself and handle
     `WM_SIZE`. Unverifiable from this machine.

Also already available and unused: `webview_get_native_handle(w,
WEBVIEW_NATIVE_HANDLE_KIND_UI_WINDOW | UI_WIDGET)` (`:146-153`, impl `:4443-4461`)
— the shell can reach both the window and the webview widget, which is what the
reparent needs. `webview_set_title`/`set_size` are **not** gated on ownership
(`:1973-1986`), so they must never be called on a container-hosted view.

## 3. Proposed decisions (for the reviewer — see §10 for the questions)

| Decision | Proposed | Why | Alternative |
|---|---|---|---|
| Layout | Vertical split: the SPA view pinned to the strip height, the pane filling the rest | The strip must stay interactive (it is drawn by the SPA) | Shell draws the strip (much bigger) |
| Container | `GtkPaned` (Linux, divider draggable for free) — see Q4 | Its slot sizes are explicit px, immune to finding 2; a box needs scrolled-window wrappers | `GtkBox` + two `GtkScrolledWindow`s |
| Vendored change | **Additive**: a container-aware parent path, plus the cast fix on GTK3 and `addSubview:` on the non-owning Cocoa path. The existing window/server/`--browser` paths stay byte-identical | The app's own window is the foundation everything uses | Copy the library / fork it |
| Pane lifetime | One pane view per app **window**, created lazily on the first browser tab, **hidden** when you leave a browser tab, re-navigated when you enter one, destroyed at app exit | Hiding avoids a WebKit cold start on every tab switch; one view keeps the process/memory bounded | Destroy per tab (slow) or one view per tab (unbounded) |
| Who drives it | The **SPA** holds the intent (which tab is a browser tab, which URL); the **shell** owns the widget. New flat bindings: `nalarBrowserPaneShow(tabId, url)`, `nalarBrowserPaneHide()`, `nalarBrowserPaneStatus()` | Matches the existing seam (`browserBridge.ts`) and the app-window-only invariant | Shell guesses from the URL |
| The pane's own chrome | The **existing injected bar** (`browser_chrome.js`) — address, ←, →, ↻, and a `▤ Nalar` button that hides the pane | Already shipped, tested in jsdom, and the pane is a real page | Build a second bar |
| Tab body | `BrowserTabView` becomes a record/controls card (URL, status, "Open in a separate window", "Open in system browser"); it is only visible if the pane is hidden | The pane covers the content area | Delete it (loses the escape hatches) |
| Keep the window mode? | **Yes** — the tab's "Open in a separate window" keeps `nalarBrowserOpen` working | Multi-monitor use, a broken pane's fallback, and the existing tests stay meaningful | Remove it (breaks the delivered feature) |
| Platform order | **Linux first** (verifiable here), then macOS, then Windows — each its own PR | Finding 3 | All three at once (unverifiable) |

## 4. Flow

```
tab strip click (SPA)                     app window (one process)
      │
      ▼
browser tab becomes active
      │  nalarBrowserPaneShow(tabId, url)
      ▼
shell: pane hidden? → show; url changed? → navigate
      ├──────────────► SPA view: 36px slot (the strip stays live)
      └──────────────► pane view: the rest — a real top-level page
                       (its injected bar = address / ← / → / ↻ / ▤ Nalar)

switch to a chat tab
      │  nalarBrowserPaneHide()
      ▼
shell: pane hidden (NOT destroyed) → SPA view expands back to full height

close the browser tab  → SPA calls no show/hide; pane stays hidden until the
                         next browser tab (explicit destroy is a follow-up)
app quits              → both views destroyed with the window
```

## 5. Tasks

**Order matters:** the vendored change is first (it is the only thing that can
invalidate the whole design), then the shell pane, then the SPA wiring, then
docs/gates. Task 1 must not alter the behaviour of the current paths — a
regression there breaks the app itself, not just the feature.

### Task 1 — Vendored shell: container parenting (Linux first)

- [ ] **1.1** `vendor/webview/webview.h` — make the parent call container-aware
  **without changing the window path**: replace the `GTK_WINDOW(...)` cast in
  `gtk_compat::window_set_child`/`window_remove_child` (`:1721-1735`) with a
  `GtkContainer*`-typed helper that is used by the GTK3 branch
  (`gtk_container_add`/`gtk_container_remove`, which already work for a box) while
  the GTK4 branch keeps `gtk_window_set_child` for real windows and uses
  `gtk_box_append`-equivalent for containers. No new public API needed if the
  "window" argument may be any container — document that in the header.
- [ ] **1.2** Cocoa: in the non-owning path, `addSubview:` the webview into the
  passed container instead of `setContentView:` (`:2632`); keep the owning path
  exactly as today, and `removeFromSuperview` in the destructor (whose own
  `setContentView: nullptr` at `:2255` is correctly guarded and needs no change).
- [ ] **1.3** Windows: no change expected (`:3617` accepts a child HWND) — add a
  compile-only assertion that the non-owning path never calls the top-level
  window APIs (they are already gated at `:3794`, `:4025`).
- [ ] **1.4** Zig static-contract tests (the house pattern in
  `webview_lib.zig`): grep the header for the three parent calls so a future
  vendored upgrade that reintroduces a window-only cast fails a test.
- [ ] **1.5** Cross-compile proof: `check:desktop-cross` must stay green for
  windows + macOS + linux (the Cocoa branch is analysed, not run).

**Acceptance:** `zig build test:desktop-app` and `check:desktop-cross` green; the
existing window/`--browser` modes unchanged (the live probe in
`scripts/browser-bridge-probe.py` still passes).

### Task 2 — Shell: the pane

- [ ] **2.1** NEW `src/apps/desktop_app/browser_pane.zig` — the container, the
  two views' slots, and the pane view's lifecycle:
  * build the container at startup (after the SPA view exists, from the app's
    `runWindow`): fetch the window + SPA widget via `webview_get_native_handle`,
    create the paned/box, move the SPA view into slot 0, pin the slot to the strip
    height, keep the pane slot empty;
  * lazily create the pane view with `webview_create(0, slot_widget)` on the
    first `show` (never `webview_set_title`/`set_size` on it — see §2);
  * `show(tabId, url)`: create-if-needed, `webview_navigate` when the URL
    changed, slot visible + the SPA slot pinned to 36px;
  * `hide()`: slot hidden, SPA slot back to filling the window;
  * `status()`: `{ visible: bool, url_len: number }` — the SPA's status line
    needs to know whether the pane really took over.
- [ ] **2.2** Install the three bindings on the **app** window only, flat names
  (`nalarBrowserPaneShow` / `Hide` / `Status`), in the same
  `bridge.installBindings` call site — the existing invariant (no bindings in a
  page-rendering window) must hold for the pane too: **the pane view gets no
  bindings**, so the injected bar keeps navigating with `location.href`.
- [ ] **2.3** Wire it in `webview_lib.runWindow`: create the pane container
  before `webview_run`, free it after. Keep `runBrowserWindow` (the separate
  window) untouched.
- [ ] **2.4** Zig tests: container built before `run`; `show` creates the pane
  once and re-navigates on a URL change; `hide` without a pane is a no-op;
  `status` for an unknown state answers `{visible:false}`; binding names flat and
  exactly three (reuse the `webviewBindGlue` contract idea on the Zig side).

### Task 3 — SPA: drive the pane

- [ ] **3.1** `helpers/browserBridge.ts` — add the pane functions to the same
  seam (`showBrowserPane(tabId, url)`, `hideBrowserPane()`, `browserPaneStatus()`)
  with the same absent-bridge degradation (an older shell ⇒ `{available:false}`;
  the UI then keeps the current behaviour instead of a silent no-op — the lesson
  from the flat-name bug).
- [ ] **3.2** A watcher that owns the intent: a new composable
  (`composables/useBrowserPane.ts`) that watches the active tab and calls
  `show(tabId, url)` when it is a `browser` tab with a URL, `hide()` otherwise —
  including when the strip is disabled, when the active tab is closed, and on
  `beforeunload`. One place, so no component owns the lifecycle.
- [ ] **3.3** `BrowserTabView.vue` — becomes a record/controls card (URL + Copy,
  pane status line, "Open in a separate window", "Open in system browser"), shown
  only while the pane is unavailable/hidden; the blank state keeps its address bar
  (entering an address navigates the pane rather than spawning a window).
- [ ] **3.4** `AppLayout.vue` — mount the composable once (like the tab
  shortcuts), so it survives view switches.

### Task 4 — Tests

- [ ] **4.1** `useBrowserPane.spec.ts` — show on browser-tab activation, hide on
  every other tab, no call when the URL is unchanged, and nothing at all when the
  bridge is absent.
- [ ] **4.2** `BrowserTabView.spec.ts` / `browserBridge.spec.ts` — the record
  card, the separate-window escape hatch, the pane-status line, and the
  absent-bridge path (all in jsdom, no engine needed).
- [ ] **4.3** EXTEND `scripts/browser-bridge-probe.py` (or add
  `scripts/browser-pane-probe.py`): the live gate. It must assert, in the real
  engine: (a) the SPA page's `window.innerHeight` **shrinks to the strip** when
  the pane shows and **returns** after `hide`, (b) the pane view loaded the page
  (its own bar reports the URL), (c) `status()` agrees, (d) the app window's
  title/size never change, and (e) no second OS window exists (count the
  process's children before/after — the same assertion the window probe uses).
  This is the test that would have caught the spike's failure.
- [ ] **4.4** Keep `browserChrome.spec.ts` green — the bar is unchanged and now
  runs in the pane (its `▤ Nalar` button gains a `nalarBrowserPaneHide` path that
  must degrade to nothing when absent).

### Task 5 — Documentation

- [ ] **5.1** `docs/SPEC.md` — new `§3.7.13 In-app browser pane (2026-09-14)`:
  the single-view constraint with the vendored lines, the measured spike
  findings, the layout, the bindings, the pane lifetime, and
  `**Plan:** docs/superpowers/plans/2026-09-14-in-app-browser-pane.md`. Keep
  §3.7.12 (the window mode) and cross-link: the pane **supersedes Q6** for the
  default experience while the window mode stays.
- [ ] **5.2** `docs/tabs.md` — "The browser pane": the page is inside the app
  window now; what the strip shows while browsing; the escape hatches; the
  fallback when the pane cannot be created (the window mode) and when the site
  refuses to be framed *inside the pane* (it does not — the pane is a real view).
- [ ] **5.3** The previous plan: add a one-line banner to its Q6 row / §10.2
  pointing at this plan, and note it in its Implementation status (do not rewrite
  its history).

### Task 6 — Gates

- [ ] **6.1** `zig build test --summary all`, `zig build test:desktop-app`,
  `zig build check:desktop-cross` (windows + macOS + linux) — the vendored change
  is the risky part, so the cross-compile gate matters more than usual.
- [ ] **6.2** `vitest` full suite vs the recorded baseline (4 pre-existing
  failures); `pnpm run build`; `pnpm run lint:check`.
- [ ] **6.3** `python3 scripts/browser-bridge-probe.py` (the delivered window
  mode must still work) **and** the new pane probe, both green.
- [ ] **6.4** Manual, per platform (§9): Linux here; macOS and Windows need a
  human with the machine.

## 6. Edge cases (each needs a test)

| # | Case | Expected | Covered by |
|---|---|---|---|
| 1 | First browser tab opened | Pane created, page loads, strip still clickable | 2.1, 4.3 |
| 2 | Switch to a chat tab and back | Pane hidden then shown **without re-creating** the view; the page keeps its state (scroll, session) | 2.1, 4.1, 4.3 |
| 3 | Same tab, same URL (re-activate) | No navigation, no flicker | 4.1 |
| 4 | Same tab, new URL (address bar → Enter) | Pane navigates; the tab record updates | 3.3, 4.3 |
| 5 | Two browser tabs, switch between them | One pane view, two URLs; no second view, no second process | 2.1, 4.1 |
| 6 | Last browser tab closed | Pane hidden, SPA back to full height | 3.2, 4.3 |
| 7 | Strip switched off (Settings) while a browser tab is active | Pane still works; the SPA view is still the 36px slot (the strip is simply empty) — **or** the pane hides: decide in Q2 | 3.2, 4.1 |
| 8 | A page that covers the pane's injected bar | Existing behaviour: recovered up to the budget, then gone; the pane still browses | 4.4 |
| 9 | The pane cannot be created (no container, an old vendored lib, another platform before its patch) | `nalarBrowserPaneShow` answers `{available:false}`; the tab body offers the window/system browser; **never a silent no-op** | 2.4, 3.1, 4.2 |
| 10 | App quit with the pane visible | Both views destroyed in order (pane first, then the owner) with no GTK criticals | 2.1, 4.3 |
| 11 | Window resized while the pane is visible | The SPA slot stays at the strip height; the pane takes the delta | 4.3 |
| 12 | Full-screen / maximised | Same as 11 (the container does the layout, not JS) | 4.3 |
| 13 | The user drags the divider (if Q4 says yes) | The SPA slot clamps to ≥ 36px; the strip never collapses to 0 | Q4 |
| 14 | A page that opens a `target="_blank"` link | Unchanged (native engine behaviour — it navigates/opens per the engine) | manual |
| 15 | The pane's page tries to reach the shell | No bindings in the pane view (invariant) — `window.nalarBrowserOpen` is `undefined` there | 2.2, 4.3 |
| 16 | `--browser <url>` (separate window) after all this | Still works, still no bindings | 6.3 |

## 7. Risks

| Risk | Impact | Mitigation |
|---|---|---|
| The vendored change regresses the **app's own window** | The whole app breaks, not just the feature | The change is additive (a container-typed helper); the window path is unchanged; `browser-bridge-probe.py` + the full zig/vitest suites run before/after; `git revert` is one file |
| Reparenting the SPA view destabilises WebKit | Blank/crashing SPA after the move | The move happens once, before the first navigation, in the same thread as the GTK loop; the probe asserts the SPA still renders and reports its viewport |
| GTK3 vs GTK4 divergence | A Linux-only fix that breaks the future GTK4 build | Both branches handled in 1.1; the build pins GTK3 today (`build.zig:1764`), documented |
| The huge natural height of a `WebKitWebView` (measured: 1398px) | The strip slot grows to fill the window — the spike's second failure | A `GtkPaned` slot / scrolled-window wrapper with an explicit size (finding 2) |
| macOS `setContentView:` semantics | The pane would *replace* the SPA's view | Patch the non-owning path to `addSubview:` (1.2) and verify on a Mac before shipping that platform |
| Windows has no layout containers | The two children overlap / do not resize | The shell places them and handles `WM_SIZE`; its own PR, verified on Windows |
| Two WebKit views in one process | Memory/CPU growth | One pane view per window, created lazily and hidden (not destroyed/created per tab); measure RSS in the probe |
| Bindings in the pane | Untrusted page content could drive the shell | The invariant is explicit in 2.2 and asserted (4.3, edge 15) |
| The strip is a 36px webview while browsing | A page that grabs focus/keys could confuse the strip | The strip keeps the top slot; `▤ Nalar` hides the pane; document it; Q3 asks whether to add a thin second row |

## 8. Rollback

* Feature-additive: one vendored helper change (no API change), one new Zig file,
  three flat bindings, one composable, edits to `BrowserTabView`/`AppLayout`.
* The window mode is untouched, so `git revert` restores today's behaviour exactly:
  a browser tab launches a Nalar window again. Nothing else reads the new
  bindings, and an older shell answers `{available:false}` so the SPA degrades to
  the current UI.
* No storage migration, no new HTTP route, no schema change.

## 9. Verification (manual, after implementation)

**Linux (here, now).** `zig build nalar-desktop` from the branch, then run it
against the running backend, and:

- [ ] `+` → type `github.com` → Enter → the page renders **inside the app
  window**, below the strip, with the injected bar. No second window appears.
- [ ] YouTube in the same tab → plays/renders (a real view, so framing is
  irrelevant).
- [ ] Switch to a chat tab → the app is back, full height; switch back → the page
  is still where it was (same view, no reload).
- [ ] Two browser tabs → one pane, two URLs; the strip switches between them.
- [ ] Close the browser tab → the pane disappears, the app is full height.
- [ ] Resize the window and maximise → the strip stays 36px, the pane takes the
  rest.
- [ ] `--devtools`: evaluate `window.nalarBrowserOpen` in the **pane** → `undefined`
  (invariant); in the **app** window → the three functions exist.
- [ ] Quit with the pane open → no GTK criticals, no leftover child process.
- [ ] `python3 scripts/browser-bridge-probe.py` still PASSes (the window mode).

**macOS / Windows (a human, after their patch):** repeat the first eight items;
the only platform-specific parts are the parent call (1.1/1.2) and the layout.

## 10. Reviewer questions (please answer before implementation)

| # | Question | Why it matters |
|---|---|---|
| Q1 | Is the strip + page split the right shape (page fills everything below the strip), or do you want a **thin second row** for the tab's URL/status? | Decides the SPA slot height (36px vs ~72px) and how much of `BrowserTabView` stays visible |
| Q2 | When you leave a browser tab, should the pane be **hidden and kept** (fast, page keeps state, one view per window) or **destroyed** (memory released, slower, page state lost)? And what should happen to the pane if the strip is switched off while a browser tab is active? | Pane lifetime; memory vs switch latency |
| Q3 | Keep the **separate-window** mode as "Open in a separate window"? | It is shipped and tested; removing it is easy, keeping it is free |
| Q4 | Should the divider between the strip and the page be **draggable** (GTK gives it for free on Linux) or fixed at 36px? | Small extra SPA/pane coordination (clamping, persistence) vs a nicer UX |
| Q5 | Scope now: **Linux only**, then macOS/Windows as separate PRs — or wait until all three are patched? | I can only verify Linux here; shipping macOS untested is a real risk |
| Q6 | Where should an `http(s)` link clicked in chat/Settings land when the pane exists — the browser tab with the pane (current `openExternal` intent), or a window? | One-line change either way; affects the "no new window" promise |

---

## 11. What the window mode keeps (and why this is additive)

`2026-09-14-in-app-browser-tab.md` is not superseded: the pane reuses its
`webview_bind` bridge (flat names), its injected chrome bar, its address
normalization, its tab kind and its store actions. The only thing this plan
changes about the delivered experience is **where the page renders by default** —
and `Open in system browser` stays as the escape hatch. The window mode is now an
**automatic** fallback (no UI affordance — the human's Q3), used only where the
pane cannot be built (macOS/Windows until their patch, an older shell).

---

## Implementation status (executed 2026-09-14)

**Shipped (Linux/GTK3).** A browser tab renders the page **inside the app
window**, below the 36px strip: one window, one process, no `nalar-desktop` child.
The pane is created on the first browser tab, hidden (never destroyed) when you
leave it, so coming back keeps the page's state; `show` with an unchanged URL does
not reload. On macOS/Windows the pane bindings are absent and the SPA falls back to
the window mode — automatically, with no separate-window affordance in the UI.

**PR:** [#489](https://github.com/ginwa123/ginwaaitoolbox/pull/489) (same branch as
the window mode it supersedes; base `main`).

### Reviewer answers that shaped this

| # | Answer | Effect |
|---|---|---|
| Q1 | **Yes** — strip + page filling everything below it | No second row; the SPA slot is exactly the strip height |
| Q3 | **No separate window** | The window button is gone; the window mode survives only as an invisible fallback |
| Q5 | **Linux first** | macOS/Windows are follow-ups (different parent call: `addSubview:` / child HWND) |
| Q2, Q4, Q6 | not answered → the §3 recommendations were taken | pane hidden-not-destroyed; fixed 36px slot (not draggable); chat/Settings links land in the pane |

### Deviations from the plan

1. **The estimate was corrected by measurement, twice over.** §2 of the previous
   plan expected "multi-week, per-OS". The first spike showed the GTK3 blocker is a
   single `GTK_WINDOW()` cast — the parent call was *already*
   `gtk_container_add(GTK_CONTAINER(window), widget)`, which is generic for a box.
   The fix is `widget_set_parent`/`widget_unset_parent` (`GTK_IS_WINDOW` picks the
   old call, so the app's own window path is unchanged), with the removal path
   guarded because a moved view is no longer the window's child.
2. **The scrolled-window wrappers are not cosmetic.** The first spike FAILED with
   `spa slot 1398px, pane 0px`: a `WebKitWebView` reports a ~1398px natural height,
   so a bare box slot cannot be 36px. `GtkPaned(position=36)` plus a
   `GtkScrolledWindow` per view (policy NEVER/NEVER) fixes it — measured
   `spa_slot=36 / pane_slot=1361`.
3. **The strip slot reports ~46px, not 36**, because a `GtkPaned` allocates its
   ~10px handle even with one child hidden. Harmless; asserted as a range.
4. **`nalarBrowserPaneStatus` also reports `supported`**, so the SPA can tell "this
   shell has no pane" from "the pane exists but is hidden" — the difference between
   falling back and doing nothing.
5. **macOS/Windows are compile-gated out, not half-built.**
   `browser_pane.supported` is `builtin.os.tag == .linux` and `installBindings` is a
   no-op elsewhere, so an untested Cocoa path (where `setContentView:` would replace
   the SPA's view) never ships.
6. **The SPA hides its own chrome while the pane is visible** (`data-pane-mode` on
   the AppLayout root hides every child except the tab strip). Without it the 36px
   slot would show the sidebar's top band next to the strip.

### Gates

* `zig build test:desktop-app --summary all` — **67/67** (62 + 5 pane contract
  tests: scheme refusal, malformed request, hide/status before any show, the
  platform gate, flat binding names).
* `zig build check:desktop-cross --summary all` — windows + macOS + linux compile.
* **Live engine gate:** `python3 scripts/browser-pane-probe.py` — **PASS**:

```
inner_before=1398   show={"ok":true,"visible":true}
inner_shown=46      status_shown={"supported":true,"visible":true}
hide={"ok":true,"visible":false}   inner_hidden=1398
PASS: pane inside the app window — SPA viewport 1398 -> 46 (strip) -> 1398
      (restored), no window, no child process.
```

  It also asserts no `--browser` child, so a regression that turned the pane into a
  spawn would fail it.
* `scripts/browser-bridge-probe.py` — the window mode still passes (the bridge is
  untouched; the pane is additive).
* `vitest` full suite: **374 files / 3326 tests, 4 failed** — the same pre-existing
  four (`FilePickerDialog.windows`, `WorkspaceItemHideTasksForDesign`,
  `workspacesStoreNormalizeTaskDates`, `workspacesStoreNormalizeTaskImageUrls`),
  **+16 new passes, 0 regressions**; `vue-tsc` and `lint:check` clean.

### Not verified here

The §9 manual checklist on Linux (the look of the strip + a real page in one
window, tab switching without a reload, resize/maximise, `window.nalarBrowserOpen`
absent in the pane's devtools, no GTK criticals on quit) — the live probe covers the
mechanism, not the look. macOS and Windows need their parent-call work first.

### Follow-ups

macOS (`addSubview:` in the non-owning Cocoa path — `webview.h:2632`) and Windows
(child HWND + `WM_SIZE` placement); a draggable divider (Q4, still open); a live
URL/title back to the tab (previous plan §10.4); agent-driven control (§10.3).

