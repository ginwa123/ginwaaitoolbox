// src/apps/desktop_app/platform/windows/nalar_webview_stub.cpp
//
// Dev-box stub for nalar_webview.cpp.
//
// The real implementation (nalar_webview.cpp) uses Win32 + WRL + WebView2
// and requires MSVC's C++ standard-library headers (cstddef, etc.) which
// ship with Visual Studio Build Tools. On a dev box that hasn't installed
// MSVC, that .cpp fails to compile with `fatal error: 'cstddef' file not
// found` (the WRL header chain pulls in cstddef as its first include).
//
// build.zig gates the compile on `hasMsvcCppStllib()`. When MSVC is
// absent, it falls back to this stub which exports the same 3 C ABI
// symbols (nalar_webview_create / _run / _destroy) as no-ops. nalar-desktop
// then builds + links, but won't actually display a webview on these
// dev boxes — the webview.zig Zig layer already treats these functions'
// return values as fallback paths (`run()` returns an error from
// `nalar_webview_create`'s null handle, nalar-desktop prints the error
// and exits 1). The CI runner, which installs MSVC, takes the real
// .cpp path.
//
// This stub has no MSVC / WRL / WebView2 dependencies — just plain C99
// — so it compiles on any host that has zig cc.
//
// Implements the same `webview_c.h` ABI as nalar_webview.cpp:
//     void* nalar_webview_create(...);
//     int   nalar_webview_run(void* handle);
//     void  nalar_webview_destroy(void* handle);
//
// The real nalar_webview.cpp uses HWND + WRL::ComPtr + CreateCoreWebView2
// etc.; this stub returns NULL from create and treats NULL as the "no
// webview available" signal that webview.zig already handles.

#include <stddef.h>

#include "../shared/webview_c.h"

// `Config` and `Asset` are forward-declared structurally in webview_c.h
// as opaque pointers to keep this stub free of <wrl.h> / <webview2.h>.
// We don't dereference them — nalar_webview_create just returns NULL,
// webview.zig checks for NULL and surfaces a "WebView2 unavailable"
// error to the user.
//
// Signature: `void* nalar_webview_create(const void* config, size_t asset_count, const void* assets, int parent_hwnd)`
extern "C" void* nalar_webview_create(
    const void* /*config*/,
    size_t /*asset_count*/,
    const void* /*assets*/,
    int /*parent_hwnd*/
) {
    // No webview on this dev box. webview.zig treats a NULL return as
    // a "WebView2 not available" signal and prints a clear error to the
    // user (not a crash). See webview.zig's run() path.
    return NULL;
}

// Signature: `int nalar_webview_run(void* handle)`
extern "C" int nalar_webview_run(void* /*handle*/) {
    // Stub: no-op (handle is always NULL from the stubbed create()).
    return -1;
}

// Signature: `void nalar_webview_destroy(void* handle)`
extern "C" void nalar_webview_destroy(void* /*handle*/) {
    // Stub: nothing to free (handle is always NULL).
}
