// src/apps/desktop_app/platform/windows/nalar_webview.cpp
//
// Chunk 7: Windows implementation of the webview C ABI declared in
// shared/webview_c.h. The three `extern "C"` functions at the bottom of
// this file (nalar_webview_create / _run / _destroy) are linked directly
// into the nalar-desktop executable. The Zig side (webview.zig) declares
// matching `extern "c"` prototypes and calls them through a single API.
//
// Stack
// -----
//   * Win32 (HWND + WndProc + message loop) drives the windowing and event loop.
//   * WebView2 (Microsoft Edge / Chromium) renders the HTML/CSS/JS webapp.
//
// Asset interception
// ------------------
//   WebView2's `ICoreWebView2::add_WebResourceRequested` fires for every
//   network request the webview makes. We register a handler with a `*`
//   filter, then inside the handler check the URL: if it starts with
//   `app://`, look up the path in the asset table and build a custom
//   response via `ICoreWebView2Environment::CreateWebResourceResponse`.
//   Non-`app://` requests return S_OK without calling `put_Response`, so
//   WebView2 handles them normally (CDNs, fonts, etc.).
//
// COM apartment
// -------------
//   WebView2's UI thread is STA (single-threaded apartment). We call
//   `CoInitializeEx(NULL, COINIT_APARTMENTTHREADED)` in create() before
//   any WebView2 API. If COM is already initialized on this thread with
//   a different mode (`RPC_E_CHANGED_MODE`), we proceed anyway — the
//   caller's process is responsible for the threading model.
//
// Async initialization
// --------------------
//   `CreateCoreWebView2EnvironmentWithOptions` is async. The classic
//   WebView2 mistake is to navigate to the URL immediately after this
//   call returns — but at that point the environment doesn't exist yet.
//   We use the callback to chain env → controller → asset handler
//   registration → navigate. Each step waits for the previous to
//   complete. The window is shown synchronously; the webview content
//   populates once the chain finishes (typically <100ms cold, <10ms warm).
//
// Build prerequisites
// -------------------
//   This file references the WebView2 headers, which are NOT vendored
//   in the repo. The build will fail on any host that doesn't have the
//   Microsoft.Web.WebView2 NuGet package extracted into
//   `src/apps/desktop_app/platform/windows/`:
//
//     - WebView2.h         (Microsoft's main WebView2 COM API header)
//     - EventToken.h       (sibling required by WebView2.h — a partial
//                           extraction without it fails deep inside
//                           Microsoft's header: "EventToken.h not found")
//     - WebView2Loader.h   (the static-link helper declarations)
//     - WebView2Loader.dll (runtime — must be next to nalar-desktop.exe)
//
//   Download: https://www.nuget.org/packages/Microsoft.Web.WebView2/
//   Extract:  build/native/include/{WebView2.h, WebView2Loader.h}
//             runtimes/win-x64/native/WebView2Loader.dll
//   Place into: src/apps/desktop_app/platform/windows/
//
//   On a Linux/macOS host this file is never compiled (the .windows
//   branch of build.zig is only active for Windows targets), so the
//   missing headers do not affect cross-platform builds.

#include <windows.h>
#include <wrl.h>
#include <string.h>
#include <wchar.h>     // _wcsdup, wcslen, wcsncmp, wcschr, wcsncpy_s, swprintf_s
#include "WebView2.h"
#include "shared/webview_c.h"

// Linker hints. The Zig build.zig also calls linkSystemLibrary for these,
// but #pragma comment is the canonical C++ way and helps IDEs that don't
// run build.zig (e.g. when opening the file in Visual Studio for review).
#pragma comment(lib, "ole32.lib")
#pragma comment(lib, "user32.lib")
#pragma comment(lib, "WebView2Loader.lib")

using Microsoft::WRL::Callback;
using Microsoft::WRL::ComPtr;

// =============================================================================
// Internal data structures
// =============================================================================

/// Heap-allocated webview state. Mirrors the nalar_webview (C side) / Webview
/// (Zig side) opaque type — the Zig webview.zig just casts `*Webview` to
/// `*NalarWebview` to access the fields.
///
/// Asset memory is borrowed from the Config struct the caller passed in
/// (the caller keeps the Config alive for the webview's lifetime via
/// `defer nalar_webview_destroy` in webview.zig's run()). We never copy
/// the asset bytes — the IStream we hand to WebView2 reads directly from
/// the borrowed memory.
struct NalarWebview {
    HWND hwnd;
    ComPtr<ICoreWebView2Controller> controller;
    ComPtr<ICoreWebView2> webview;
    ComPtr<ICoreWebView2Environment> env;
    const nalar_webview_asset* assets;
    size_t asset_count;
    bool closed;
    /// Non-zero while a resize-coalescing timer is pending (scroll-perf
    /// Task 4). Windows fires WM_SIZE in bursts during drag-resize; each
    /// put_Bounds forces the WebView2 surface to re-layout, so we apply
    /// only the final size one frame (16 ms) after the burst stops.
    UINT_PTR resize_timer_id;
};

// =============================================================================
// Utility: UTF-8 to wide string conversion
// =============================================================================

/// Convert a UTF-8 `char*` to a freshly-allocated, null-terminated wide
/// string. Caller frees with `free()`. Returns NULL on conversion failure
/// or if the input is NULL.
static wchar_t* utf8_to_wide(const char* s) {
    if (s == NULL) return NULL;
    int len = MultiByteToWideChar(CP_UTF8, 0, s, -1, NULL, 0);
    if (len <= 0) return NULL;
    wchar_t* w = (wchar_t*)malloc((size_t)len * sizeof(wchar_t));
    if (w == NULL) return NULL;
    MultiByteToWideChar(CP_UTF8, 0, s, -1, w, len);
    return w;
}

// =============================================================================
// WndProc
// =============================================================================

/// Win32 window procedure. We store a `NalarWebview*` in GWLP_USERDATA
/// so we can reach the struct from the static callback. WndProc must be
/// `static` (file-scope) and `CALLBACK` calling convention.
static LRESULT CALLBACK WndProc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
    NalarWebview* wv = (NalarWebview*)GetWindowLongPtrW(hwnd, GWLP_USERDATA);
    if (wv == NULL) {
        return DefWindowProcW(hwnd, msg, wp, lp);
    }
    switch (msg) {
        case WM_CLOSE:
            // User clicked the X (or Alt+F4, or system "close" menu). Mark
            // closed and break the message loop so nalar_webview_run returns.
            wv->closed = true;
            PostQuitMessage(0);
            return 0;
        case WM_SIZE: {
            // Window resized — keep the WebView2 controller's bounds in
            // sync with the client area or the page won't reflow.
            //
            // scroll-perf Task 4: coalesce instead of applying every
            // message. Drag-resize fires WM_SIZE in bursts (dozens per
            // gesture); each put_Bounds forces a WebView2 surface
            // re-layout. Restart a 16 ms timer on every burst member and
            // apply only the final bounds on WM_TIMER — visually identical
            // (the last size always lands within one frame of release)
            // but without N re-layouts per drag.
            if (wv->controller) {
                if (wv->resize_timer_id == 0) {
                    wv->resize_timer_id = 1;
                    SetTimer(hwnd, wv->resize_timer_id, 16, NULL);
                }
            }
            return 0;
        }
        case WM_TIMER: {
            if (wp == wv->resize_timer_id) {
                KillTimer(hwnd, wv->resize_timer_id);
                wv->resize_timer_id = 0;
                if (wv->controller) {
                    RECT rc;
                    GetClientRect(hwnd, &rc);
                    wv->controller->put_Bounds(rc);
                }
                return 0;
            }
            break;
        }
    }
    return DefWindowProcW(hwnd, msg, wp, lp);
}

// =============================================================================
// Asset request handler
// =============================================================================

/// Handle an `ICoreWebView2WebResourceRequested` event. For `app://` URLs,
/// look up the path in the asset table and build a custom response. For
/// all other URLs, return S_OK without modifying `args` — WebView2 will
/// fetch them normally (CDNs, etc.).
///
/// Asset lookup is a linear scan, which is fine for a few hundred entries
/// (the typical webapp size after bundling). The first matching path wins;
/// if no asset matches, we return a 404 with a "Not Found" plain-text body
/// (matching the Linux and macOS implementations' "don't propagate a
/// platform-specific error" philosophy).
static HRESULT HandleAssetRequest(
    NalarWebview* wv,
    ICoreWebView2WebResourceRequestedEventArgs* args)
{
    ComPtr<ICoreWebView2WebResourceRequest> req;
    HRESULT hr = args->get_Request(&req);
    if (FAILED(hr) || req == NULL) return hr;

    LPWSTR uri_w = NULL;
    hr = req->get_Uri(&uri_w);
    if (FAILED(hr) || uri_w == NULL) {
        if (uri_w) CoTaskMemFree(uri_w);
        return hr;
    }

    // Copy URI to a stack buffer (URLs are short — typically < 1KB).
    // wcsncpy_s is the bounds-checked variant; _TRUNCATE accepts truncation.
    wchar_t uri_buf[2048];
    wcsncpy_s(uri_buf, _countof(uri_buf), uri_w, _TRUNCATE);
    CoTaskMemFree(uri_w);

    // Check for "app://" prefix.
    static const wchar_t* prefix = L"app://";
    size_t prefix_len = wcslen(prefix);
    if (wcsncmp(uri_buf, prefix, prefix_len) != 0) {
        return S_OK;  // not our scheme — let WebView2 handle it
    }

    // Strip scheme and host: "app://localhost/index.html" → "/index.html"
    const wchar_t* after = uri_buf + prefix_len;
    const wchar_t* slash = wcschr(after, L'/');
    const wchar_t* path_w = (slash != NULL) ? slash : L"/";

    // Convert the path to UTF-8 for the asset-table comparison.
    char path_utf8[4096];
    int path_len = WideCharToMultiByte(
        CP_UTF8, 0, path_w, -1, path_utf8, sizeof(path_utf8), NULL, NULL);
    if (path_len <= 0) return E_FAIL;
    path_len -= 1;  // exclude null terminator from length

    // Linear search the asset table.
    const char* content = NULL;
    size_t content_len = 0;
    const char* mime = NULL;
    int status = 200;
    for (size_t i = 0; i < wv->asset_count; i++) {
        if (strcmp(wv->assets[i].path, path_utf8) == 0) {
            content = wv->assets[i].content;
            content_len = wv->assets[i].content_len;
            mime = wv->assets[i].mime;
            break;
        }
    }
    if (content == NULL) {
        // Not found — synthesize a 404 with a plain-text body.
        static const char not_found[] = "Not Found";
        content = not_found;
        content_len = sizeof(not_found) - 1;
        mime = "text/plain";
        status = 404;
    }

    // Build an IStream over a memory copy of the content. CreateStreamOnHGlobal
    // with fDeleteOnRelease=TRUE means WebView2 will GlobalFree the buffer
    // when it releases the stream — no manual cleanup needed.
    ComPtr<IStream> stream;
    HGLOBAL hglobal = NULL;
    if (content_len > 0) {
        hglobal = GlobalAlloc(GMEM_MOVEABLE, content_len);
        if (hglobal == NULL) return E_OUTOFMEMORY;
        void* p = GlobalLock(hglobal);
        if (p == NULL) {
            GlobalFree(hglobal);
            return E_OUTOFMEMORY;
        }
        memcpy(p, content, content_len);
        GlobalUnlock(hglobal);
    }
    hr = CreateStreamOnHGlobal(hglobal, TRUE, &stream);
    if (FAILED(hr)) {
        if (hglobal) GlobalFree(hglobal);
        return hr;
    }

    // Build the "Content-Type: <mime>\r\n" headers string.
    wchar_t* mime_w = utf8_to_wide(mime);
    if (mime_w == NULL) return E_OUTOFMEMORY;
    size_t header_buf_size = wcslen(mime_w) + 32;
    wchar_t* headers_buf = (wchar_t*)malloc(header_buf_size * sizeof(wchar_t));
    if (headers_buf == NULL) {
        free(mime_w);
        return E_OUTOFMEMORY;
    }
    swprintf_s(headers_buf, header_buf_size, L"Content-Type: %s\r\n", mime_w);
    free(mime_w);

    // Build the response. Status 200/404 + reason phrase + headers.
    ComPtr<ICoreWebView2WebResourceResponse> response;
    LPCWSTR reason = (status == 200) ? L"OK" : L"Not Found";
    hr = wv->env->CreateWebResourceResponse(
        stream.Get(),
        status,
        reason,
        headers_buf,
        &response);
    free(headers_buf);

    if (FAILED(hr)) return hr;

    // Hand the response to WebView2. The IStream is held by the response
    // (via the global), which WebView2 holds until the response is
    // delivered to the renderer, at which point the IStream is released
    // and the global is freed.
    return args->put_Response(response.Get());
}

// =============================================================================
// C ABI implementations
// =============================================================================

/// Create a Win32 window, asynchronously initialize WebView2, register the
/// `app://` scheme handler, and navigate to the given URL. The returned
/// handle stays valid until `nalar_webview_destroy()` is called.
///
/// `cfg` must remain valid for the webview's lifetime (the C ABI contract —
/// see the C ABI header).
extern "C" nalar_webview* nalar_webview_create(
    const nalar_webview_config* cfg,
    const char* url)
{
    if (cfg == NULL || url == NULL) {
        OutputDebugStringA("nalar_webview_create: cfg or url is NULL\n");
        return NULL;
    }

    // 1. COM init. WebView2 requires STA. RPC_E_CHANGED_MODE means COM is
    //    already initialized on this thread with a different mode — we
    //    proceed; the caller's threading model wins.
    HRESULT hr = CoInitializeEx(NULL, COINIT_APARTMENTTHREADED);
    if (FAILED(hr) && hr != RPC_E_CHANGED_MODE) {
        OutputDebugStringA("nalar_webview_create: CoInitializeEx failed\n");
        return NULL;
    }

    // 2. Register the window class. RegisterClassW returns 0 with
    //    ERROR_CLASS_ALREADY_EXISTS if the class was registered by a prior
    //    call (e.g. on a second nalar-desktop instance in the same process)
    //    — we tolerate that. Any other error is fatal.
    WNDCLASSW wc = {};
    wc.lpfnWndProc = WndProc;
    wc.hInstance = GetModuleHandleW(NULL);
    wc.lpszClassName = L"NalarWebviewClass";
    wc.hbrBackground = (HBRUSH)(COLOR_WINDOW + 1);
    if (!RegisterClassW(&wc)) {
        DWORD err = GetLastError();
        if (err != ERROR_CLASS_ALREADY_EXISTS) {
            OutputDebugStringA("nalar_webview_create: RegisterClassW failed\n");
            return NULL;
        }
    }

    // 3. Build window style from config.
    DWORD style = WS_OVERLAPPEDWINDOW | WS_CLIPCHILDREN;
    if (!cfg->resizable) {
        style &= ~(WS_THICKFRAME | WS_MAXIMIZEBOX);
    }
    if (!cfg->minimizable) {
        style &= ~WS_MINIMIZEBOX;
    }
    // `maximizable` is enabled by WS_MAXIMIZEBOX, which is part of
    // WS_OVERLAPPEDWINDOW. If !maximizable, strip it.
    if (!cfg->maximizable) {
        style &= ~WS_MAXIMIZEBOX;
    }

    // 4. Convert title and url to wide strings.
    wchar_t* title_w = utf8_to_wide(cfg->title);
    wchar_t* url_w = utf8_to_wide(url);
    if (title_w == NULL || url_w == NULL) {
        free(title_w);
        free(url_w);
        return NULL;
    }

    // 5. Adjust window rect to account for non-client area (title bar,
    //    borders). CreateWindowExW's width/height include the chrome.
    RECT rc = { 0, 0, cfg->width, cfg->height };
    AdjustWindowRect(&rc, style, FALSE);
    int win_w = rc.right - rc.left;
    int win_h = rc.bottom - rc.top;

    // 6. Create the window. NULL parent, NULL menu, NULL create param —
    //    we pass our NalarWebview pointer in via SetWindowLongPtrW after
    //    creation.
    HWND hwnd = CreateWindowExW(
        0,
        L"NalarWebviewClass",
        title_w,
        style,
        CW_USEDEFAULT,
        CW_USEDEFAULT,
        win_w,
        win_h,
        NULL,
        NULL,
        GetModuleHandleW(NULL),
        NULL);

    free(title_w);

    if (hwnd == NULL) {
        free(url_w);
        OutputDebugStringA("nalar_webview_create: CreateWindowExW failed\n");
        return NULL;
    }

    // 7. Allocate the NalarWebview struct and stash it in GWLP_USERDATA
    //    so WndProc can find it. ComPtr default-constructs to nullptr.
    NalarWebview* wv = new NalarWebview();
    wv->hwnd = hwnd;
    wv->controller = nullptr;
    wv->webview = nullptr;
    wv->env = nullptr;
    wv->assets = cfg->assets;
    wv->asset_count = cfg->asset_count;
    wv->closed = false;
    wv->resize_timer_id = 0;
    SetWindowLongPtrW(hwnd, GWLP_USERDATA, (LONG_PTR)wv);

    // 8. Async: create the WebView2 environment. The callback chain is:
    //    env ready → create controller → register asset handler → navigate.
    //    Each step is async; the callbacks nest.
    //
    //    The WRL `Callback<>` template creates a refcounted COM object
    //    whose lifetime is managed by the WebView2 APIs (AddRef on
    //    registration, Release on shutdown). The lambda captures `wv` and
    //    `url_w_shared` by value (pointer copy): `wv` lives until
    //    `nalar_webview_destroy`, and `url_w_shared` is freed exactly
    //    once per code path (success or failure) by the callback that
    //    last needs it.
    //
    //    We make a fresh copy of url_w (`url_w_shared`) so we can free
    //    our local `url_w` immediately — the async chain has its own copy.
    wchar_t* url_w_shared = _wcsdup(url_w);
    free(url_w);

    NalarWebview* wv_for_callback = wv;
    const nalar_webview_config* cfg_for_callback = cfg;

    // scroll-perf Task 4: pass a real environment options object so we
    // can tune the embedded Edge browser process. Conservative arg set —
    // aggressive flag lists rot as Edge updates:
    //   --disable-features=msSmartScreenProtection  SmartScreen phones
    //     home per navigation; irrelevant for app:// assets we serve
    //     ourselves, and one less synchronous check on the network thread.
    // GPU compositing is deliberately NOT disabled — hardware
    // acceleration is what makes scrolling smooth (the whole point of
    // this plan).
    ComPtr<ICoreWebView2EnvironmentOptions> env_options;
    hr = CoCreateInstance(
        __uuidof(CoreWebView2EnvironmentOptions),
        NULL,
        CLSCTX_ALL,
        IID_PPV_ARGS(&env_options));
    if (FAILED(hr)) {
        free(url_w);
        fwprintf(stderr, L"nalar_webview: CoCreateInstance(EnvironmentOptions) failed (0x%08X)\n", hr);
        return NULL;
    }
    HRESULT hr_args = env_options->put_AdditionalBrowserArguments(
        L"--disable-features=msSmartScreenProtection");
    if (FAILED(hr_args)) {
        fwprintf(stderr, L"nalar_webview: put_AdditionalBrowserArguments failed (0x%08X)\n", hr_args);
        // Non-fatal: proceed with default options rather than failing init.
        env_options = NULL;
    }

    hr = CreateCoreWebView2EnvironmentWithOptions(
        NULL,
        NULL,
        env_options.Get(),
        Callback<ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler>(
            [wv_for_callback, cfg_for_callback, url_w_shared](
                HRESULT result, ICoreWebView2Environment* env) -> HRESULT
            {
                if (FAILED(result) || env == NULL) {
                    free(url_w_shared);  // inner won't run; free here
                    return result;
                }
                wv_for_callback->env = env;

                // Async step 2: create the controller bound to our HWND.
                return env->CreateCoreWebView2Controller(
                    wv_for_callback->hwnd,
                    Callback<ICoreWebView2CreateCoreWebView2ControllerCompletedHandler>(
                        [wv_for_callback, cfg_for_callback, url_w_shared](
                            HRESULT result2, ICoreWebView2Controller* controller) -> HRESULT
                        {
                            if (FAILED(result2) || controller == NULL) {
                                free(url_w_shared);
                                return result2;
                            }

                            wv_for_callback->controller = controller;
                            HRESULT hr3 = controller->get_CoreWebView2(&wv_for_callback->webview);
                            if (FAILED(hr3) || wv_for_callback->webview == NULL) {
                                free(url_w_shared);
                                return hr3;
                            }

                            // Size the controller to fill the window client area.
                            RECT bounds;
                            GetClientRect(wv_for_callback->hwnd, &bounds);
                            wv_for_callback->controller->put_Bounds(bounds);
                            wv_for_callback->controller->put_IsVisible(TRUE);

                            // scroll-perf Task 4: dark default background.
                            // WebView2 paints opaque white until the first
                            // CSS paint; the webapp is dark-themed, so set
                            // the controller's background to match and kill
                            // the cold-start flash. ICoreWebView2Controller2
                            // is the interface that carries the property.
                            {
                                ComPtr<ICoreWebView2Controller2> controller2;
                                if (SUCCEEDED(wv_for_callback->controller.As(&controller2))
                                    && controller2 != NULL) {
                                    COREWEBVIEW2_COLOR bg;
                                    bg.A = 255;
                                    bg.R = 24;
                                    bg.G = 22;
                                    bg.B = 22;  // #181616 — app dark background
                                    controller2->put_DefaultBackgroundColor(bg);
                                }
                                // Controller2 unavailable (older runtime):
                                // fall back to stock white flash, non-fatal.
                            }

                            // Apply user-agent override (if set). Settings
                            // is owned by the webview; ComPtr scope cleans
                            // up automatically.
                            if (cfg_for_callback->user_agent != NULL) {
                                wchar_t* ua_w = utf8_to_wide(cfg_for_callback->user_agent);
                                if (ua_w != NULL) {
                                    ComPtr<ICoreWebView2Settings> settings;
                                    if (SUCCEEDED(wv_for_callback->webview->get_Settings(&settings))
                                        && settings != NULL) {
                                        settings->put_UserAgent(ua_w);
                                    }
                                    free(ua_w);
                                }
                            }

                            // Register the asset request handler. The
                            // `*` filter matches every URL; the handler
                            // itself only responds to `app://` schemes.
                            // The WRL Callback<> is AddRef'd by
                            // add_WebResourceRequested and held by the
                            // webview; we pass NULL for the token because
                            // we never remove this handler (it dies with
                            // the webview).
                            wv_for_callback->webview->add_WebResourceRequested(
                                L"*",
                                Callback<ICoreWebView2WebResourceRequestedEventHandler>(
                                    [wv_for_callback](
                                        ICoreWebView2* sender,
                                        ICoreWebView2WebResourceRequestedEventArgs* args) -> HRESULT
                                    {
                                        return HandleAssetRequest(wv_for_callback, args);
                                    }
                                ).Get(),
                                NULL);

                            // Suppress WebView2's default right-click
                            // context menu (Back / Forward / Stop /
                            // Reload / Open Frame in New Window /
                            // Inspect Element / etc.). The
                            // `add_ContextMenuRequested` event fires
                            // before WebView2 shows the menu; setting
                            // `args->put_Handled(TRUE)` suppresses it.
                            // The page's JavaScript `contextmenu` DOM
                            // event still fires, so the Vue app's
                            // @contextmenu.prevent handlers run as
                            // intended (DesignView, LayersPanel,
                            // GitChanges, etc.).
                            //
                            // WebView2's "Inspect Element" stock debug
                            // item is intentionally NOT exposed via the
                            // context menu — it's a noise item in
                            // production. Developers who need DevTools
                            // can launch with --devtools flag and use
                            // the existing developer extras path; this
                            // is a deliberate trade-off.
                            wv_for_callback->webview->add_ContextMenuRequested(
                                Callback<ICoreWebView2ContextMenuRequestedEventHandler>(
                                    [](
                                        ICoreWebView2* sender,
                                        ICoreWebView2ContextMenuRequestedEventArgs* args) -> HRESULT
                                    {
                                        (void)sender;
                                        // Mark the menu as handled —
                                        // WebView2 will NOT show its
                                        // default context menu. The
                                        // page's `contextmenu` DOM
                                        // event still fires inside the
                                        // webview (unchanged).
                                        return args->put_Handled(TRUE);
                                    }
                                ).Get(),
                                NULL);

                            // Navigate to the initial URL. Navigate copies
                            // the URL synchronously into WebView2's
                            // internal state, so freeing the caller's
                            // buffer immediately after the call is safe.
                            wv_for_callback->webview->Navigate(url_w_shared);
                            free(url_w_shared);

                            return S_OK;
                        }).Get());
            }).Get());

    if (FAILED(hr)) {
        OutputDebugStringA("nalar_webview_create: CreateCoreWebView2EnvironmentWithOptions failed\n");
        DestroyWindow(hwnd);
        delete wv;
        return NULL;
    }

    // 9. Show the window. The WebView2 env/controller is being created
    //    async; the window populates with content once that chain
    //    finishes (typically <100ms cold, <10ms warm).
    ShowWindow(hwnd, SW_SHOW);
    UpdateWindow(hwnd);

    return (nalar_webview*)wv;
}

/// Run the Win32 message loop. Blocks until `PostQuitMessage` is called
/// (which our WndProc does on WM_CLOSE — user clicked the X, Alt+F4, etc.).
extern "C" void nalar_webview_run(nalar_webview* wv_ptr) {
    NalarWebview* wv = (NalarWebview*)wv_ptr;
    if (wv == NULL) return;

    // Standard Win32 message loop. GetMessage returns 0 when
    // PostQuitMessage was called (signaling app exit), -1 on error.
    MSG msg;
    while (GetMessageW(&msg, NULL, 0, 0) > 0) {
        TranslateMessage(&msg);
        DispatchMessageW(&msg);
    }
}

/// Tear down the window and release all COM resources. After this
/// returns the handle is invalid; the caller must not use it again.
extern "C" void nalar_webview_destroy(nalar_webview* wv_ptr) {
    NalarWebview* wv = (NalarWebview*)wv_ptr;
    if (wv == NULL) return;

    // Close the WebView2 controller first. This initiates a graceful
    // shutdown of the webview process and the BrowserExtension. The
    // ComPtrs are released explicitly below to make the order
    // deterministic (ComPtr destructors would do the same, but the
    // explicit form is easier to reason about during code review).
    if (wv->controller != nullptr) {
        wv->controller->Close();
    }

    // Destroy the window. WM_DESTROY fires on WndProc but we don't
    // handle it (PostQuitMessage is on WM_CLOSE).
    if (wv->hwnd != NULL) {
        DestroyWindow(wv->hwnd);
    }

    // Release COM pointers in dependency order: controller, then webview,
    // then env. The WRL Callback<> objects that the webview holds for the
    // asset request handler and the env/controller creation callbacks
    // are released automatically as their owning IUnknowns are released.
    wv->controller = nullptr;
    wv->webview = nullptr;
    wv->env = nullptr;

    delete wv;
}
