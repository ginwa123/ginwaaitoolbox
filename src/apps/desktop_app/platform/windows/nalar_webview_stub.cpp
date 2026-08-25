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
// This stub has no MSVC / WRL / WebView2 dependencies — just the shared
// header (<stddef.h> is its only transitive need) — so it compiles on
// any host that has zig cc.
//
// Implements the exact ABI declared in shared/webview_c.h (single-copy
// header dedup — the stub includes the real header so signature drift
// is a compile error, not a silent link bug):
//     nalar_webview* nalar_webview_create(const nalar_webview_config*, const char*);
//     void           nalar_webview_run(nalar_webview*);
//     void           nalar_webview_destroy(nalar_webview*);
//
// The real nalar_webview.cpp uses HWND + WRL::ComPtr + CreateCoreWebView2
// etc.; this stub returns NULL from create and treats NULL as the "no
// webview available" signal that webview.zig already handles.

#include "shared/webview_c.h"

extern "C" nalar_webview* nalar_webview_create(
    const nalar_webview_config* /*cfg*/,
    const char* /*url*/
) {
    // No webview on this dev box. webview.zig treats a NULL return as
    // a "WebView2 not available" signal and prints a clear error to the
    // user (not a crash). See webview.zig's run() path.
    return NULL;
}

extern "C" void nalar_webview_run(nalar_webview* /*wv*/) {
    // Stub: no-op (handle is always NULL from the stubbed create()).
}

extern "C" void nalar_webview_destroy(nalar_webview* /*wv*/) {
    // Stub: nothing to free (handle is always NULL).
}
