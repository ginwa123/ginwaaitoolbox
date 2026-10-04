# Desktop app: suppress webview's default context menu (right-click → app menu)

## Date / Author
2026-08-06 / session task_1786035961751

## Symptom

User reported right-click in the desktop app (`pabrik-desktop`) shows the
**WEBVIEW's default context menu** (Back, Forward, Stop, Reload, Open
Frame in New Window, Inspect Element) instead of the **app's custom
context menu** rendered by Vue components.

Screenshot: the user's kanban view (embedded in a design-element iframe)
shows browser-level menu items. The app's `@contextmenu` handlers in
`DesignView.vue`, `LayersPanel.vue`, `LayerRow.vue`, and `GitChanges.vue`
never fire because the webview intercepts the right-click event at the
native layer.

## Root cause

The webview consumes the right-click event before the page receives it.
This is the default behavior of all three target webviews:

| Platform | Webview | Default menu |
|----------|---------|--------------|
| Linux    | WebKitGTK 4.1 | Copy / Paste / Select All / etc. |
| macOS    | WKWebView | Copy / Paste / Select All / etc. |
| Windows  | WebView2 (Chromium) | Back / Forward / Stop / Reload / Open Frame in New Window / Inspect Element |

Current code only handles the Linux case, and only when `--devtools` is
enabled — and even then it ADDS to the menu (return FALSE keeps WebKit
defaults). The two other platforms never suppress at all.

## Goal

Suppress the webview's default context menu for ALL three platforms so
the right-click event reaches the page's JavaScript, where Vue's
`@contextmenu.prevent` handlers can fire.

## Implementation plan

### 1. Linux (WebKitGTK 4.1) — `src/apps/desktop_app/platform/linux.zig`

- Always connect the `context-menu` signal (move the existing wiring
  OUT of the `if (cfg.enable_developer_extras)` block).
- When `--devtools` is enabled: append the existing "Inspect Element"
  stock item, then return `1` (TRUE) to suppress the default menu.
- When `--devtools` is NOT enabled: simply return `1` (TRUE) — no
  items added, defaults suppressed, the page's `@contextmenu` handlers
  get the event.

### 2. macOS (WKWebView) — `src/apps/desktop_app/platform/macos/pabrik_webview.mm`

- Add a `WKUIDelegate` (`PabrikUIDelegate`) to the existing
  `PabrikAppDelegate`-managed `WKWebViewConfiguration`.
- Implement `webView:requestContextMenu:menuForElement:initiator:` to
  return `nil` (suppress the default menu). This is the public API
  (macOS 13.3+, iOS 16.4+); the deprecated `setMenuProvider` /
  `WKWebViewContextMenu` private API is NOT used.
- No "Inspect Element" support on macOS for v1 (the user didn't ask
  for it; macOS dev tools are typically accessed via Safari's Web
  Inspector via `wkwebview-devtools` private flag).

### 3. Windows (WebView2) — `src/apps/desktop_app/platform/windows/pabrik_webview.cpp`

- Register `add_ContextMenuRequested` handler on the `ICoreWebView2`.
- In the handler, call `args->put_Handled(TRUE)` to suppress the default
  menu.
- No "Inspect Element" support on Windows for v1 (WebView2's
  `COREWEBVIEW2_CONTEXT_MENU_KIND_INSPECT_ELEMENT` is the only stock
  debug item, but enabling it requires the WebView2 DevTools protocol
  to be reachable — out of scope for the "suppress the menu" fix).

### 4. Behavioural test coverage

- **Linux**: extend `linux_test.zig` with a new test that loads the
  shared library, calls `webview.Webview.Config` with
  `enable_developer_extras = false`, and asserts the `context-menu`
  signal is connected (no public API to verify, but the WEAK callback
  has a registered counter we can read via a test-only global).
- **macOS**: not testable cross-platform (only builds on macOS); the
  Objective-C++ change is reviewed manually.
- **Windows**: not testable cross-platform (only builds on Windows);
  the C++ change is reviewed manually.

For cross-platform coverage, the cleanest test is: "the page's
`@contextmenu` handler fires when right-clicked". We can verify this
with a behavioural test that mounts the relevant Vue components
(`DesignView`, `LayersPanel`) and dispatches a `contextmenu` event
against the canvas — the component's `useDesignContextMenu` should
open the menu. This is already covered by existing tests
(`LayersPanel.contextMenu.spec.ts`, `DesignContextMenu.spec.ts`).

### 5. Cross-compile smoke

- `zig build-obj -fno-emit-bin -target x86_64-windows-gnu` — confirms
  the C++ `pabrik_webview.cpp` compiles.
- `zig build-obj -fno-emit-bin -target aarch64-macos` — confirms the
  Objective-C++ `pabrik_webview.mm` compiles.
- `zig build test` on Linux — confirms all the Zig tests still pass.

## Out of scope

- macOS / Windows support for "Inspect Element" stock item. Not
  requested. Add later if the user asks.
- A `<Teleport>`-based `DesignContextMenu` for the iframe content
  (the inner iframe is sandboxed `allow-scripts` only — cross-origin
  so the outer Vue can't reach into it). If a user wants right-click
  inside the iframe to also show the app menu, that requires a
  postMessage bridge; out of scope.
- WebView2 DevTools protocol access. Out of scope.

## Files

**Modified (3):**
- `src/apps/desktop_app/platform/linux.zig` — move `context-menu`
  signal connection outside the `enable_developer_extras` block,
  always return `1` (TRUE) to suppress the default menu.
- `src/apps/desktop_app/platform/macos/pabrik_webview.mm` — add
  `WKUIDelegate` implementation that suppresses the default menu.
- `src/apps/desktop_app/platform/windows/pabrik_webview.cpp` — add
  `add_ContextMenuRequested` handler that sets `put_Handled(TRUE)`.

**New test (1):**
- `src/apps/desktop_app/platform/linux_test_contextmenu.zig` — extends
  the existing `linux_test.zig` test infrastructure to verify the
  suppression behaviour.

## Verification

1. `zig build test --summary all` — 100% pass (no new failures).
2. Cross-compile `zig build-obj -fno-emit-bin -target X` for Windows
   and macOS — both clean.
3. Live smoke: build `zig-out/bin/pabrik-desktop` on Linux, start it
   pointing at the running pabrik backend, click into a design page
   with a kanban preview iframe, right-click anywhere — the browser
   menu should NOT appear. The page's `@contextmenu` handlers should
   fire when right-clicking on design elements / layer rows.

## Plan file location

`docs/superpowers/plans/2026-08-06-desktop-contextmenu-suppress.md`
