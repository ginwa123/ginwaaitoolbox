// src/apps/desktop_app/platform/windows/webview_stub.c
//
// Dev-box fallback for the vendored webview/webview library
// (vendor/webview/webview.{h,cc}, upstream 0.12.0).
//
// Why this stub exists
// ---------------------
// The real webview/webview library is compiled by build.zig's
// `.windows =>` branch via `zig cc vendor/webview/webview.cc`. On
// Windows that compile needs:
//   1. MSVC's C++ STL headers (webview.h's win32 path includes
//      <wrl/client.h> which transitively pulls <cstddef>), AND
//   2. The Microsoft.Web.WebView2 NuGet headers staged next to the
//      .cc (WebView2.h + EventToken.h, both under
//      src/apps/desktop_app/platform/windows/).
//
// A Windows dev box that has NEITHER (the common case before CI's
// `Install vcpkg + MSVC build tools (Windows)` + `Stage WebView2 +
// integrate vcpkg + install ripgrep (Windows)` steps run) used to
// trip `std.process.exit(1)` at build-config time and kill every
// zig build invocation — including `zig build test`, which doesn't
// need pabrik-desktop at all.
//
// This stub replaces that hard-exit with a no-op implementation of
// the 16-symbol webview C ABI declared in src/apps/desktop_app/
// webview_lib.zig. With the stub, `zig build pabrik-desktop` and
// `zig build` (default) succeed on a Windows host WITHOUT MSVC +
// WebView2 — producing a pabrik-desktop.exe that loads + parses CLI +
// extracts the embedded webapp assets (the `--smoke-test` path)
// cleanly, but cannot actually open a webview window because every
// API call returns a no-op. main.zig's `runWindow` calls
// `webview_create` which returns NULL, surfacing
// `error.WebviewCreateFailed` to the user as a clear, actionable
// "Webview error: WebviewCreateFailed" log line.
//
// This is the same honest-but-broken behavior the pre-PR-354
// `platform/windows/pabrik_webview_stub.cpp` provided for the OLD
// pabrik_webview_* C ABI that the webview-lib swap removed. The
// difference: this stub implements the NEW webview/webview 0.12.0
// C API (webview_create / webview_run / webview_destroy / ...),
// not the old pabrik_webview_create / _run / _destroy ABI. The
// signatures below are 1:1 with vendor/webview/webview.h so the
// static-contract test in webview_lib.zig ("binding matches
// vendored webview.h C API signatures") still passes.
//
// The CI runner installs MSVC + WebView2 NuGet and takes the real
// webview.cc compile path; this stub is only for dev boxes without
// those prerequisites.

#include <stddef.h>

// === Type mirror (1:1 with vendor/webview/webview.h) ===
//
// The stub does NOT include vendor/webview/webview.h — that header
// transitively pulls <wrl/client.h> and other MSVC STL machinery
// we want to avoid here. We only need the symbols declared in
// webview_lib.zig, so we redeclare the minimal types inline. ABI
// compatibility with the real lib is checked by webview_lib.zig's
// static-contract test grepping vendor/webview/webview.h.

typedef void *webview_t;

typedef enum {
    WEBVIEW_ERROR_MISSING_DEPENDENCY = -5,
    WEBVIEW_ERROR_CANCELED = -4,
    WEBVIEW_ERROR_INVALID_STATE = -3,
    WEBVIEW_ERROR_INVALID_ARGUMENT = -2,
    WEBVIEW_ERROR_UNSPECIFIED = -1,
    WEBVIEW_ERROR_OK = 0,
    WEBVIEW_ERROR_DUPLICATE = 1,
    WEBVIEW_ERROR_NOT_FOUND = 2,
} webview_error_t;

// === Stub implementations ===
//
// Every function is a no-op: webview_create returns NULL (signals
// "no webview available" to main.zig's runWindow), the rest return
// WEBVIEW_ERROR_OK / NULL without touching any state. This matches
// the original pabrik_webview_stub.cpp contract: the desktop binary
// compiles + links + the --smoke-test path runs cleanly, but
// opening a real webview window returns error.WebviewCreateFailed.

webview_t webview_create(int debug, void *window) {
    (void)debug;
    (void)window;
    return NULL;
}

webview_error_t webview_destroy(webview_t w) {
    (void)w;
    return WEBVIEW_ERROR_OK;
}

webview_error_t webview_run(webview_t w) {
    (void)w;
    return WEBVIEW_ERROR_OK;
}

webview_error_t webview_terminate(webview_t w) {
    (void)w;
    return WEBVIEW_ERROR_OK;
}

webview_error_t webview_dispatch(
    webview_t w,
    void (*fn)(webview_t w, void *arg),
    void *arg
) {
    (void)w;
    (void)fn;
    (void)arg;
    return WEBVIEW_ERROR_OK;
}

void *webview_get_window(webview_t w) {
    (void)w;
    return NULL;
}

void *webview_get_native_handle(webview_t w, int kind) {
    (void)w;
    (void)kind;
    return NULL;
}

webview_error_t webview_set_title(webview_t w, const char *title) {
    (void)w;
    (void)title;
    return WEBVIEW_ERROR_OK;
}

webview_error_t webview_set_size(
    webview_t w,
    int width,
    int height,
    int hints
) {
    (void)w;
    (void)width;
    (void)height;
    (void)hints;
    return WEBVIEW_ERROR_OK;
}

webview_error_t webview_navigate(webview_t w, const char *url) {
    (void)w;
    (void)url;
    return WEBVIEW_ERROR_OK;
}

webview_error_t webview_set_html(webview_t w, const char *html) {
    (void)w;
    (void)html;
    return WEBVIEW_ERROR_OK;
}

webview_error_t webview_init(webview_t w, const char *js) {
    (void)w;
    (void)js;
    return WEBVIEW_ERROR_OK;
}

webview_error_t webview_eval(webview_t w, const char *js) {
    (void)w;
    (void)js;
    return WEBVIEW_ERROR_OK;
}

webview_error_t webview_bind(
    webview_t w,
    const char *name,
    void (*fn)(const char *id, const char *req, void *arg),
    void *arg
) {
    (void)w;
    (void)name;
    (void)fn;
    (void)arg;
    return WEBVIEW_ERROR_OK;
}

webview_error_t webview_unbind(webview_t w, const char *name) {
    (void)w;
    (void)name;
    return WEBVIEW_ERROR_OK;
}

webview_error_t webview_return(
    webview_t w,
    const char *id,
    int status,
    const char *result
) {
    (void)w;
    (void)id;
    (void)status;
    (void)result;
    return WEBVIEW_ERROR_OK;
}