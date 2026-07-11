// src/apps/desktop_app/shared/webview_c.h
// Shared C ABI for the nalar-desktop webview implementations.
// All three platforms (Linux WebKitGTK, macOS WKWebView, Windows WebView2)
// implement these three functions.
//
// The Zig side declares them as extern "c" and calls them through a single API.

#ifndef NALAR_WEBVIEW_C_H
#define NALAR_WEBVIEW_C_H

#include <stddef.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Opaque handle to a created webview. The Zig side treats this as `*Webview`.
typedef struct nalar_webview nalar_webview;

/// One web asset. The Zig side builds an array of these at startup
/// (sourced from the embedded webapp_assets.zig) and passes the array
/// to nalar_webview_create.
typedef struct {
    const char* path;      // e.g. "/index.html", "/assets/app.js"
    const char* content;   // file bytes (may contain NULs)
    size_t      content_len;
    const char* mime;      // e.g. "text/html; charset=utf-8"
} nalar_webview_asset;

/// Window configuration. Mirrored on the Zig side as `Webview.Config`.
typedef struct {
    const char* title;
    int         width;
    int         height;
    int         min_width;
    int         min_height;
    bool        resizable;
    bool        maximizable;
    bool        minimizable;
    const char* user_agent;     // nullable
    const char* icon_path;      // nullable
    // Asset table — the webview serves these at app://<path> URLs
    // without doing real network I/O.
    const nalar_webview_asset* assets;
    size_t                     asset_count;
    // When true, the platform enables the webview's developer-extras
    // (right-click → Inspect Element → DevTools). Off by default in
    // production; enable with the nalar-desktop `--devtools` flag.
    bool                       enable_developer_extras;
    // When non-null, paths under app://localhost/api/* are proxied to
    // this base URL (e.g. "http://127.0.0.1:8081"). Lets the webapp
    // use relative `/api/...` fetches from a webview served off the
    // app:// scheme — the scheme handler forwards the request to nalar
    // running on its own port, so the webview and the API never share
    // a port. When null, all app:// requests are answered from the
    // asset table (no API proxy; the webapp would need absolute URLs
    // + CORS, or no API access at all).
    const char*                api_proxy_base; // nullable, e.g. "http://127.0.0.1:8081"
} nalar_webview_config;

/// Create a window, load the given URL, and prepare to run the event loop.
/// Returns NULL on failure (with a message logged via std::log / NSLog / g_log).
nalar_webview* nalar_webview_create(
    const nalar_webview_config* cfg,
    const char*                 url
);

/// Run the platform event loop. Blocks until the window is closed.
/// Returns when the user closes the window, clicks an X, etc.
void nalar_webview_run(nalar_webview* wv);

/// Destroy the webview and free all platform resources.
/// After this returns, the handle is invalid.
void nalar_webview_destroy(nalar_webview* wv);

#ifdef __cplusplus
}
#endif

#endif // NALAR_WEBVIEW_C_H
