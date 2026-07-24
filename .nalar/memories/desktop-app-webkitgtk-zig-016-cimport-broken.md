# desktop-app — WebKitGTK via `@cImport` does NOT work in Zig 0.16

## Symptom

Attempting to call GTK / WebKitGTK / libsoup from Zig 0.16 via `@cImport(@cInclude("gtk/gtk.h"))` produces ~7,000 cascading "unknown type name 'diagnostic'" / "use of undeclared identifier 'GCC'" / "unknown type name 'pragma'" errors during `zig build nalar-desktop` or `zig build-obj` against `gtk/gtk.h`. The build is unusable; no usable bindings are produced.

## Root cause

GLib's `<glib/gmacros.h>` defines `G_GNUC_BEGIN_IGNORE_DEPRECATIONS` as a C99 `_Pragma("GCC diagnostic push")`. Zig 0.16's libclang frontend can't parse the `_Pragma` operator inside the macro expansion — it sees the bare token `diagnostic` and reports an unknown type name. The error then cascades through every GLib / GTK / WebKit header that transitively includes `<glib/gmacros.h>` (which is essentially all of them).

This affects every header that includes `<glib.h>` transitively, which means `<gtk/gtk.h>`, `<webkit/webkit.h>`, `<libsoup/soup.h>`, etc. — basically the entire GTK stack.

## Fix

Skip `@cImport` entirely. Use the three-step workaround:

1. **Declare each GTK / WebKit function you call manually as `extern "c"`** at the top of your Zig file. Keep declarations minimal — only what you actually call. Cross-reference the GTK/WebKit headers for the exact C signature.

2. **Write a small C shim file** (e.g. `platform/webview_linux.c`) that does `#include <gtk/gtk.h>` / `#include <webkit/webkit.h>` / `#include <libsoup/soup.h>`. The shim does NOT need a body for the Zig-side functions — it just needs to compile cleanly. Compile the shim with `cc` (real Clang / gcc), not via Zig's libclang.

3. **The shim is also a header-compile smoke test** — if a future GTK header update breaks parseability, the C shim fails to compile under `cc` and you discover it immediately at build time, before linking.

The Zig code links against the system GTK/WebKit shared libraries via `build.zig`'s `linkSystemLibrary` (`gtk-3`, `webkit2gtk-4.1`, `libsoup-3.0`, etc.) — only the function *declarations* in Zig are hand-written.

## Pitfalls

- **Don't try `@cImport` with selective includes** (e.g. only `@cInclude("glib.h")` to avoid GTK) — even the minimal GLib headers pull in `<glib/gmacros.h>` and the cascade still hits you.
- **Don't disable the macro via `-D`** — `G_GNUC_BEGIN_IGNORE_DEPRECATIONS` is set by GLib's own headers, not via build flags.
- **The C shim must actually compile with `cc`** — the whole point is to catch future header regressions at build time. Don't stub out the includes in the shim "to make it build".
- **Module-scope `extern "c"` is required** — Zig 0.16 forbids `extern "c"` declarations inside function bodies. Put them at the top of the `.zig` file.
- **Use `std.posix.SOL.SOCKET` / `std.posix.SO.REUSEADDR`** for socket options (OS-tagged constants), never hardcoded `1, 2`. See `nalar-backend-architecture.md`.
- **The desktop-app build already does this** — `src/apps/desktop_app/platform/webview_linux.c` + matching hand-written `extern "c"` declarations. Use that as the template for new GTK/WebKit call sites.

## Verification

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
timeout 180 zig build nalar-desktop 2>&1 | tail -n 10
# Expect: clean build, ~29 MB binary in zig-out/bin/nalar-desktop

cc -c src/apps/desktop_app/platform/webview_linux.c -o /tmp/webview_shim.o \
    $(pkg-config --cflags gtk4 webkit2gtk-4.1) 2>&1 | tail -n 10
# Expect: clean compile of the shim (catches header regressions early)
```

All 21/21 unit tests pass via `zig build test:desktop-app`. If you add a new GTK/WebKit call, add an `extern "c"` declaration for it AND a smoke-test call inside the C shim's `int main(void)` (or a test function).

## Related

- `zig-0.16-stdlib-changes.md` — broader Zig 0.16 stdlib API removals context.
- `nalar-backend-architecture.md` — `std.posix.SOL.SOCKET` / `std.posix.SO.REUSEADDR` (OS-tagged constants, never hardcoded).
- `src/apps/desktop_app/platform/webview_linux.c` — the live C shim implementing this pattern for WebKitGTK 4.1.
- `src/apps/desktop_app/platform/macos/nalar_webview.mm` — Objective-C++ shim for WKWebView (same idea, different platform).
- `src/apps/desktop_app/platform/windows/nalar_webview.cpp` — C++ shim for WebView2 (same idea, different platform).