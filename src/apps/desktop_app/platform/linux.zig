// src/apps/desktop_app/platform/linux.zig
//
// Chunk 5: Linux implementation of the webview C ABI declared in
// shared/webview_c.h. The Zig side (webview.zig) calls the three
// `extern "c"` functions defined here:
//
//   * nalar_webview_create  — opens a window, registers the `app://`
//                             scheme handler, returns an opaque handle.
//   * nalar_webview_run     — blocks on the GTK main loop.
//   * nalar_webview_destroy — tears down the window and frees the handle.
//
// GTK and WebKitGTK use the C main-loop model: g_main_loop_run() blocks
// the calling thread until g_main_loop_quit() is called. We wire the
// window's "destroy" signal to call g_main_loop_quit(), so closing the
// window unblocks the thread and nalar_webview_run() returns.
//
// The asset table is exposed to the webview via a custom "app://" URI
// scheme registered on the WebKitWebContext. The scheme callback runs
// on the GTK main thread for every request, looks up the requested
// path in the asset table (linear scan — fine for a few hundred entries),
// and returns the bytes via webkit_uri_scheme_request_finish().
//
// Asset memory is borrowed from the Config struct that the caller
// passed in — the caller is responsible for keeping the Config alive
// for the webview's lifetime (the webview.zig wrapper does this via
// `defer nalar_webview_destroy(wv)`).
//
// Why manual `extern "c"` declarations instead of `@cImport`
// ------------------------------------------------------------
// Zig's `@cImport` (a libclang-based tool) mis-tokenizes the C99
// `_Pragma` operator when it appears inside a macro body. GLib's
// `G_GNUC_BEGIN_IGNORE_DEPRECATIONS` macro expands to `_Pragma ("GCC
// diagnostic push")` and is used inside `G_DECLARE_FINAL_TYPE` for
// nearly every GObject type in glib / gtk / libsoup / webkit — so
// `@cImport` chokes with ~7,000 cascading "unknown type name
// 'diagnostic'" errors.
//
// The workaround is to skip `@cImport` entirely. Each GTK / WebKit
// symbol used here is declared manually as `extern "c"`. The .so
// libraries (libgtk-3, libwebkit2gtk-4.1, libsoup-3.0, libglib-2.0)
// are linked via build.zig's `linkSystemLibrary` calls, so the linker
// resolves the extern symbols at link time. The C shim
// `webview_linux.c` (in the same directory) is compiled with cc and
// pulls in the GTK headers, providing a "header compile test" — if
// the system headers ever break in a way that fails C compilation,
// the build fails there.
//
// Zig 0.16 notes:
//   * `*c_void` is renamed to `*anyopaque` in 0.16. The `gpointer`
//     typedef from GLib maps to `*anyopaque` in this file.
//   * Opaque types (`opaque {}`) are the cleanest way to model the
//     forward-declared GLib/WebKit structs (GtkWidget, GMainLoop,
//     etc.) — pointers to opaque types are ABI-compatible with the
//     C struct pointers, and the Zig type system enforces that you
//     don't accidentally dereference them.

const std = @import("std");
const builtin = @import("builtin");
const webview = @import("../webview.zig");

// linux.zig is only valid on Linux. Chunks 6-7 (macos.zig, windows.zig)
// will provide the corresponding implementations for those targets. The
// build.zig adds the platform-specific system libraries in the matching
// switch arm; on a non-Linux target, the headers and .so libraries won't
// be available, so we guard with a comptime error to give a clear
// diagnostic instead of a cryptic link failure.
comptime {
    if (builtin.os.tag != .linux) {
        @compileError("platform/linux.zig is only valid on Linux targets — use platform/macos.zig or platform/windows.zig instead");
    }
}

// =============================================================================
// Forward-declared C types (opaque in Zig, ABI-compatible with C struct ptrs)
// =============================================================================

const GtkWidget = opaque {};
const GtkWindow = opaque {};
const GMainLoop = opaque {};
const GMainContext = opaque {};
const GBytes = opaque {};
const GObject = opaque {};
const GMemoryInputStream = opaque {};
const GInputStream = opaque {};
const GdkEvent = opaque {};
const WebKitURISchemeRequest = opaque {};
const WebKitWebContext = opaque {};
const WebKitWebView = opaque {};
const WebKitSettings = opaque {};
const WebKitContextMenu = opaque {};
const WebKitContextMenuItem = opaque {};
const WebKitWebInspector = opaque {};

// GLib typedefs that the C headers use. We don't pull in glib.h's
// type definitions, so we mirror the canonical types here.
const gboolean = c_int;
const gint = c_int;
const guint = c_uint;
const gint64 = i64;
const gsize = usize;
const gpointer = *anyopaque;
const GConnectFlags = c_int;

// GtkWindowType — `GTK_WINDOW_TOPLEVEL = 0` is the standard normal-window
// type (the alternative is `GTK_WINDOW_POPUP = 1` for menu/tooltip windows).
const GTK_WINDOW_TOPLEVEL: c_int = 0;

// WebKitURISchemeRequestCallback — the function-pointer type that
// webkit_web_context_register_uri_scheme expects. C typedef is
// `void (*)(WebKitURISchemeRequest *request, gpointer user_data)`.
const WebKitURISchemeRequestCallback = *const fn (
    *WebKitURISchemeRequest,
    gpointer,
) callconv(.c) void;

// =============================================================================
// extern "c" declarations — every GTK / WebKit function this file calls
// =============================================================================
//
// These are deliberate copies of the C signatures. They trust the user
// (Zig doesn't verify the signatures against the C headers), but the
// webview_linux.c shim ensures the headers compile and the .so libs
// provide the symbols.

// --- GTK core ---
extern "c" fn gtk_init(argc: [*c]c_int, argv: [*c][*c][*c]u8) void;

extern "c" fn gtk_window_new(type: c_int) *GtkWidget;

extern "c" fn gtk_window_set_title(window: *GtkWindow, title: [*:0]const u8) void;
extern "c" fn gtk_window_set_default_size(window: *GtkWindow, width: c_int, height: c_int) void;
extern "c" fn gtk_window_set_resizable(window: *GtkWindow, resizable: gboolean) void;

extern "c" fn gtk_widget_set_size_request(widget: *GtkWidget, width: c_int, height: c_int) void;
extern "c" fn gtk_widget_show_all(widget: *GtkWidget) void;
extern "c" fn gtk_widget_destroy(widget: *GtkWidget) void;

extern "c" fn gtk_container_add(container: *GtkWidget, widget: *GtkWidget) void;

// --- GLib main loop ---
extern "c" fn g_main_loop_new(context: ?*GMainContext, is_running: gboolean) *GMainLoop;
extern "c" fn g_main_loop_run(loop: *GMainLoop) void;
extern "c" fn g_main_loop_quit(loop: *GMainLoop) void;
extern "c" fn g_main_loop_unref(loop: *GMainLoop) void;

// --- GLib signal system ---
// GCallback is `void (*)(void)`, the universal function-pointer type
// used by g_signal_connect_data. The actual handler may have any
// signature (the GObject system marshals arguments at call time).
// We declare the parameter as `*const fn () callconv(.c) void` and
// `@ptrCast` our specific function pointer at the call site.
extern "c" fn g_signal_connect_data(
    instance: *GtkWidget,
    detailed_signal: [*:0]const u8,
    c_handler: *const fn () callconv(.c) void,
    data: gpointer,
    destroy_data: ?*const fn () callconv(.c) void,
    connect_flags: GConnectFlags,
) c_ulong;

// --- GLib byte / object refcounting ---
extern "c" fn g_bytes_new(data: [*]const u8, size: gsize) *GBytes;
extern "c" fn g_object_unref(object: *GObject) void;
extern "c" fn g_memory_input_stream_new_from_bytes(bytes: *GBytes) *GInputStream;

// --- WebKitGTK web context / scheme registration ---
extern "c" fn webkit_web_context_get_default() *WebKitWebContext;
extern "c" fn webkit_web_context_register_uri_scheme(
    context: *WebKitWebContext,
    scheme: [*:0]const u8,
    callback: WebKitURISchemeRequestCallback,
    user_data: gpointer,
    user_data_destroy_func: ?*const fn () callconv(.c) void,
) void;

// --- WebKitGTK web view ---
extern "c" fn webkit_web_view_new_with_context(context: *WebKitWebContext) *GtkWidget;
extern "c" fn webkit_web_view_load_uri(web_view: *GtkWidget, uri: [*:0]const u8) void;
extern "c" fn webkit_web_view_get_settings(web_view: *GtkWidget) *WebKitSettings;

extern "c" fn webkit_settings_set_user_agent(settings: *WebKitSettings, user_agent: [*:0]const u8) void;
extern "c" fn webkit_settings_set_enable_developer_extras(settings: *WebKitSettings, enabled: gboolean) void;
extern "c" fn webkit_settings_get_enable_developer_extras(settings: *WebKitSettings) gboolean;
extern "c" fn webkit_settings_set_javascript_can_access_clipboard(settings: *WebKitSettings, enabled: gboolean) void;

// --- WebKitGTK inspector (DevTools) ---
extern "c" fn webkit_web_view_get_inspector(web_view: *GtkWidget) *WebKitWebInspector;
extern "c" fn webkit_web_inspector_show(inspector: *WebKitWebInspector) void;

// --- WebKitGTK context menu (right-click → stock items) ---
// We use the stock INSPECT_ELEMENT action rather than a custom GAction
// because WebKitGTK ships a built-in implementation that automatically
// calls webkit_web_inspector_show() when activated. This is much simpler
// than rolling our own GAction + signal handler chain.
extern "c" fn webkit_context_menu_item_new_from_stock_action(action: c_int) *WebKitContextMenuItem;
extern "c" fn webkit_context_menu_append(context_menu: *WebKitContextMenu, item: *WebKitContextMenuItem) void;

/// `WEBKIT_CONTEXT_MENU_ACTION_INSPECT_ELEMENT` from
/// `<webkit/WebKitContextMenuActions.h>`. The enum is stable in
/// WebKitGTK 4.x — value 31 is the inspect-element action. We hardcode
/// it instead of pulling in the header (which would mean another 3
/// typedefs we'd need to mirror) since it's a public API constant.
const WEBKIT_CONTEXT_MENU_ACTION_INSPECT_ELEMENT: c_int = 31;

// --- WebKitGTK URI scheme request handling ---
extern "c" fn webkit_uri_scheme_request_get_path(request: *WebKitURISchemeRequest) [*:0]const u8;
extern "c" fn webkit_uri_scheme_request_finish(
    request: *WebKitURISchemeRequest,
    stream: *GInputStream,
    stream_length: gint64,
    content_type: [*:0]const u8,
) void;

// =============================================================================
// Internal data structures
// =============================================================================

/// Heap-allocated context passed to the URI scheme callback. We need
/// the asset table pointer to be available on every request, and the
/// callback is a C function pointer that can only carry one gpointer
/// of user data, so we box the table reference in this struct.
const SchemeContext = struct {
    assets: [*]const webview.CAsset,
    count: usize,
    /// O(1) path -> asset-index lookup, built once in
    /// nalar_webview_create (see buildAssetIndex). Replaces the old
    /// per-request linear scan over `assets` — the callback runs on the
    /// GTK main thread, so every saved cycle is a saved scroll frame.
    asset_index: std.StringHashMapUnmanaged(u32) = .empty,
};

/// Build the path -> index map for the scheme callback. Keys point into
/// the C asset table's path strings (static lifetime per the C ABI
/// contract), so no key duplication is needed.
fn buildAssetIndex(
    allocator: std.mem.Allocator,
    ctx: *SchemeContext,
) !void {
    try ctx.asset_index.ensureTotalCapacity(allocator, @intCast(ctx.count));
    for (ctx.assets[0..ctx.count], 0..) |asset, i| {
        const asset_path = std.mem.span(asset.path);
        // First occurrence wins on duplicate paths (same semantics as
        // the old linear scan, which returned the first match).
        if (!ctx.asset_index.contains(asset_path)) {
            try ctx.asset_index.put(allocator, asset_path, @intCast(i));
        }
    }
}

/// Opaque handle returned by nalar_webview_create. Mirrors the
/// nalar_webview (C side) / Webview (Zig side) opaque type — the
/// Zig webview.zig just casts `*Webview` to `*NalarWebview` to
/// access the fields.
const NalarWebview = struct {
    window: *GtkWidget,
    web_view: *GtkWidget,
    main_loop: *GMainLoop,
    scheme_ctx: *SchemeContext,
};

// =============================================================================
// C ABI exports
// =============================================================================

/// Create a GTK window with a WebKit web view, register the `app://` scheme
/// handler, load the given URL, and return an opaque handle. The handle
/// stays valid until nalar_webview_destroy() is called.
///
/// `pub export` (instead of just `export`) makes the symbol reachable from
/// other files in the module — see the force-link pub consts at the end
/// of the file. Without those, the Zig linker would dead-code-eliminate
/// the implementation and drop the GTK/WebKit system library dependencies.
/// Graphics environment presets for WebKitGTK, applied BEFORE gtk_init.
///
/// WebKitGTK reads its renderer-selection env vars during GLib/WebKit
/// initialization. When they are unset (the previous state of this file —
/// zero env configuration), many Linux drivers silently fall back to
/// software rendering: every scroll frame is CPU-painted instead of
/// GPU-composited. That is the main reason the desktop app "feels slower
/// than Chrome" on Linux.
///
/// Presets (mirrors webview.GfxPreset):
///   .auto   — pin acceleration-friendly defaults; any var already present
///             in the process environ wins (user override respected)
///   .compat — force-disable the DMABUF renderer; escape hatch for
///             machines that render black/glitched windows with DMABUF
///             (older NVIDIA, some virtualized GPUs)
///   .debug  — auto behavior plus WEBKIT_DEBUG=Compositing on stderr
///   .x11    — auto behavior plus force GDK_BACKEND=x11 so GDK uses
///             XWayland instead of Wayland. Workaround for the
///             NVIDIA + Wayland stack where WebKitGPUProcess silently
///             fails to start (the wl_drm / linux-dmabuf-feedback
///             protocol path is broken on Hyprland + GeForce today),
///             which leaves the web-process to rasterize every frame
///             in software on its JS main thread — pinning one CPU
///             core at ~99%. XWayland uses NVIDIA's mature X11 GL
///             path and lets WebKitGPUProcess spawn normally. Opt-in
///             via `--x11` on the CLI; default path stays unchanged
///             for users on the working AMD/Intel+Wayland stack.
fn applyLinuxGfxEnv(preset: webview.GfxPreset) void {
    // setenv(3)/getenv(3) via libc. overwrite=true is safe because we only
    // reach each setenv call after confirming the var is absent from
    // environ (std.c.getenv). Zig 0.16 removed std.posix.getenv.
    const c = struct {
        extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
    };

    switch (preset) {
        .auto, .debug, .x11 => {
            // Acceleration-friendly defaults. WEBKIT_DISABLE_DMABUF_RENDERER=1
            // sounds backwards but is the community-verified fix for janky
            // scrolling on NVIDIA + mixed-GPU setups (the DMABUF path has
            // had long-standing frame-pacing bugs there); FORCE_COMPOSITING
            // keeps WebKit on the accelerated compositor instead of the
            // legacy non-composited blit path. .x11 also includes these
            // — the DMABUF-disable + force-compositing combo is just as
            // useful under XWayland as under native Wayland.
            if (std.c.getenv("WEBKIT_DISABLE_DMABUF_RENDERER") == null) {
                _ = c.setenv("WEBKIT_DISABLE_DMABUF_RENDERER", "1", 1);
            }
            if (std.c.getenv("WEBKIT_FORCE_COMPOSITING_MODE") == null) {
                _ = c.setenv("WEBKIT_FORCE_COMPOSITING_MODE", "1", 1);
            }
        },
        .compat => {
            // Conservative path: no DMABUF at all, compositing still forced
            // so resize/scroll go through the compositor rather than blits.
            if (std.c.getenv("WEBKIT_DISABLE_DMABUF_RENDERER") == null) {
                _ = c.setenv("WEBKIT_DISABLE_DMABUF_RENDERER", "1", 1);
            }
            if (std.c.getenv("WEBKIT_FORCE_COMPOSITING_MODE") == null) {
                _ = c.setenv("WEBKIT_FORCE_COMPOSITING_MODE", "1", 1);
            }
        },
    }

    if (preset == .debug) {
        if (std.c.getenv("WEBKIT_DEBUG") == null) {
            _ = c.setenv("WEBKIT_DEBUG", "Compositing", 1);
        }
    }

    // .x11: pin GDK_BACKEND=x11 so GTK/XWayland backs the window
    // instead of GDK/Wayland. MUST run before gtk_init — GDK reads
    // GDK_BACKEND exactly once at init and ignores subsequent
    // changes. Honor any value already in environ (the user can
    // still force .wayland by exporting GDK_BACKEND=wayland before
    // launch; this branch only fires when no value is set).
    if (preset == .x11) {
        if (std.c.getenv("GDK_BACKEND") == null) {
            _ = c.setenv("GDK_BACKEND", "x11", 1);
        }
    }
}

pub export fn nalar_webview_create(
    cfg: *const webview.Config,
    url: [*:0]const u8,
) ?*webview.Webview {
    // Pin the WebKitGTK gfx env BEFORE gtk_init — GLib/GDK and WebKit read
    // these vars during init; setting them afterwards has no effect.
    applyLinuxGfxEnv(cfg.gfx_preset);

    // gtk_init — null/null is fine; we don't have a CLI to parse.
    gtk_init(null, null);

    // Window
    const window = gtk_window_new(GTK_WINDOW_TOPLEVEL);
    gtk_window_set_title(@ptrCast(window), cfg.title);
    gtk_window_set_default_size(@ptrCast(window), cfg.width, cfg.height);
    gtk_window_set_resizable(@ptrCast(window), if (cfg.resizable) 1 else 0);
    if (cfg.min_width > 0 and cfg.min_height > 0) {
        gtk_widget_set_size_request(window, cfg.min_width, cfg.min_height);
    }

    // WebKit context + custom app:// scheme
    const context = webkit_web_context_get_default();

    const scheme_ctx = std.heap.page_allocator.create(SchemeContext) catch {
        gtk_widget_destroy(window);
        std.log.err("linux.zig: failed to allocate SchemeContext", .{});
        return null;
    };
    scheme_ctx.* = .{
        .assets = cfg.assets,
        .count = cfg.asset_count,
    };

    // O(1) asset lookup: build the path -> index map once, here, so the
    // per-request callback never linear-scans the table on the GTK main
    // thread. On failure we fall back to count=0 (all requests 404)
    // rather than aborting window creation.
    buildAssetIndex(std.heap.page_allocator, scheme_ctx) catch |err| {
        std.log.warn("linux.zig: asset index build failed ({any}); app:// lookups disabled", .{err});
        scheme_ctx.count = 0;
    };

    webkit_web_context_register_uri_scheme(
        context,
        "app",
        uriSchemeCallback,
        @ptrCast(scheme_ctx),
        null, // destroy_notify — we manage scheme_ctx ourselves in destroy()
    );

    // Web view
    const web_view = webkit_web_view_new_with_context(context);
    {
        // Get the settings once and apply every non-user-agent setting here.
        // Settings like enable_javascript, javascript_can_access_clipboard,
        // and enable_developer_extras must be applied BEFORE the first
        // webkit_web_view_load_uri() call — once a page is loaded, some
        // settings cannot be changed until the next load.
        const settings = webkit_web_view_get_settings(web_view);

        // Allow the webapp's JS `paste` event handler to read image bytes
        // from the system clipboard. WebKitGTK's default is FALSE, which
        // silently filters file/image items out of ClipboardEvent.items
        // — so pasting a screenshot does nothing (text pastes still work
        // because those items bypass the filter). Chrome's default is
        // permissive; matching that behavior so the same webapp code
        // works in nalar-desktop without #ifdef'ing the frontend.
        webkit_settings_set_javascript_can_access_clipboard(settings, 1);

        if (cfg.user_agent) |ua| {
            webkit_settings_set_user_agent(settings, ua);
        }
    }
    gtk_container_add(@ptrCast(window), web_view);

    // Context menu: ALWAYS suppress WebKit's default right-click menu
    // (copy / paste / select-all / etc.) so the page's JavaScript
    // `@contextmenu` handlers fire. Without this, WebKit eats the
    // right-click and shows its own menu — the user gets the webview's
    // browser-like menu instead of the app's custom Vue menu.
    //
    // WebKitGTK's "context-menu" signal fires before the menu is shown.
    // Returning 1 (TRUE) suppresses the default menu entirely; the page's
    // DOM `contextmenu` event still fires, so Vue's @contextmenu.prevent
    // handlers run as intended.
    //
    // When --devtools is passed, we ALSO enable developer extras AND
    // append the stock "Inspect Element" item to the (suppressed) menu
    // — but the menu is still suppressed, so this just gives the WebKit
    // inspector a way to be invoked via keyboard (Ctrl+Shift+I). The
    // right-click menu stays clean.
    //
    // user_data is unused by contextMenuCallback (it just uses the
    // web_view parameter), so pass the web_view as a placeholder
    // (gpointer is `*anyopaque`, not nullable, so we need a real
    // pointer). The signal connection lives for the lifetime of the
    // web_view — when the web_view is destroyed, the signal is
    // disconnected automatically.
    _ = g_signal_connect_data(
        @ptrCast(web_view),
        "context-menu",
        @ptrCast(&contextMenuCallback),
        @ptrCast(web_view),
        null,
        0,
    );
    if (cfg.enable_developer_extras) {
        const settings = webkit_web_view_get_settings(web_view);
        webkit_settings_set_enable_developer_extras(settings, 1);
    }

    // Main loop
    const main_loop = g_main_loop_new(null, 0);

    // Allocate the handle. If this fails, undo all the partial setup
    // above so we don't leak GObjects.
    const handle = std.heap.page_allocator.create(NalarWebview) catch {
        g_main_loop_unref(main_loop);
        gtk_widget_destroy(window); // also unrefs web_view (child of window)
        std.heap.page_allocator.destroy(scheme_ctx);
        std.log.err("linux.zig: failed to allocate NalarWebview handle", .{});
        return null;
    };
    handle.* = .{
        .window = window,
        .web_view = web_view,
        .main_loop = main_loop,
        .scheme_ctx = scheme_ctx,
    };

    // Wire the window's "destroy" signal to break the main loop. When the
    // user closes the window (X button, Alt+F4, etc.), GTK emits "destroy"
    // and our callback calls g_main_loop_quit() which makes the
    // g_main_loop_run() in nalar_webview_run() return.
    _ = g_signal_connect_data(
        @ptrCast(window),
        "destroy",
        @ptrCast(&destroyCallback),
        @ptrCast(handle),
        null,
        0,
    );

    // Show the window and kick off loading the URL.
    gtk_widget_show_all(window);
    webkit_web_view_load_uri(web_view, url);

    return @ptrCast(handle);
}

/// Block on the GTK main loop until the window is destroyed.
pub export fn nalar_webview_run(wv: *webview.Webview) void {
    const handle: *NalarWebview = @ptrCast(@alignCast(wv));
    g_main_loop_run(handle.main_loop);
}

/// Tear down the window, free the main loop, and release the handle.
/// The caller must not use `wv` after this returns.
pub export fn nalar_webview_destroy(wv: *webview.Webview) void {
    const handle: *NalarWebview = @ptrCast(@alignCast(wv));

    // g_main_loop_unref — balanced with g_main_loop_new in create().
    g_main_loop_unref(handle.main_loop);

    // gtk_widget_destroy — drops our ref to the window, which transitively
    // drops the ref to the web_view (its child). The GObject system
    // takes care of freeing the GTK widgets once their refcount hits 0.
    gtk_widget_destroy(handle.window);

    // SchemeContext was heap-allocated in create() and never ref'd
    // (GObject side), so we own the only reference and must free it.
    std.heap.page_allocator.destroy(handle.scheme_ctx);

    // Free the handle itself.
    std.heap.page_allocator.destroy(handle);
}

// =============================================================================
// Internal callbacks
// =============================================================================

/// "destroy" signal handler for the GtkWindow. Calls g_main_loop_quit()
/// to unblock nalar_webview_run(). Per the GLib signal contract, the
/// handler signature is (instance, user_data) — instance is the widget
/// emitting the signal, user_data is what we passed to g_signal_connect_data.
fn destroyCallback(widget: *GtkWidget, user_data: gpointer) callconv(.c) void {
    _ = widget;
    const handle: *NalarWebview = @ptrCast(@alignCast(user_data));
    g_main_loop_quit(handle.main_loop);
}

/// "context-menu" signal handler for the WebKit web view. Fires on
/// right-click in the page (or via the keyboard). We ALWAYS return
/// 1 (TRUE) to suppress WebKit's default context menu — the page's
/// JavaScript `@contextmenu` event still fires, so the Vue app's
/// custom context menus (DesignView, LayersPanel, GitChanges, etc.)
/// handle the right-click.
///
/// When `enable_developer_extras` was set on the Config, we ALSO append
/// the stock "Inspect Element" item — but the menu is still suppressed
/// (return 1), so the inspector is reachable via Ctrl+Shift+I only, not
/// via right-click. This keeps the right-click menu clean (always
/// the app's custom menu) while still giving developers a way to open
/// DevTools.
///
/// C signature (from webkit2/webkit2.h):
///   gboolean user_function(WebKitWebView *web_view,
///                         WebKitContextMenu *context_menu,
///                         GdkEvent *event,
///                         gpointer user_data)
///
/// We declare the first arg as `*GtkWidget` (rather than the more specific
/// `*WebKitWebView`) to match the rest of this file's style — at the C ABI
/// level they're interchangeable (WebKitWebView is-a GtkWidget). Same
/// trick the WebKitGTK source itself uses.
fn contextMenuCallback(
    web_view: *GtkWidget,
    context_menu: *WebKitContextMenu,
    event: *GdkEvent,
    user_data: gpointer,
) callconv(.c) gboolean {
    _ = event;
    _ = user_data;

    // Look up whether developer extras are enabled (set via
    // `webkit_settings_set_enable_developer_extras` in create()).
    // Per WebKitGTK's contract, `webkit_web_view_get_settings`
    // always returns a valid (non-null) pointer — the webview owns
    // its settings object internally. So we don't need a null check
    // (opaque types in Zig can't be compared to null anyway).
    const settings = webkit_web_view_get_settings(web_view);
    if (webkit_settings_get_enable_developer_extras(settings) != 0)
    {
        // Stock "Inspect Element" item. WebKitGTK handles the
        // activation internally (calls webkit_web_inspector_show()
        // on the web view's inspector). Even though the menu is
        // suppressed (we return TRUE below), the inspector is
        // still reachable via Ctrl+Shift+I — adding the item
        // makes that path explicit.
        const item = webkit_context_menu_item_new_from_stock_action(
            WEBKIT_CONTEXT_MENU_ACTION_INSPECT_ELEMENT,
        );
        webkit_context_menu_append(context_menu, item);
    }

    // Return 1 (TRUE) to suppress WebKit's default context menu
    // items. The page's `contextmenu` DOM event still fires, so the
    // Vue app's @contextmenu.prevent handlers run as intended.
    return 1;
}

/// URI scheme callback for the `app://` scheme. Fires on the GTK main
/// thread for every request. Looks up the path in the asset table and
/// returns the bytes via webkit_uri_scheme_request_finish(). If the path
/// doesn't match any asset, returns an empty 200 response (the cleanest
/// way to satisfy the request without propagating a GError).
fn uriSchemeCallback(
    request: *WebKitURISchemeRequest,
    user_data: gpointer,
) callconv(.c) void {
    const ctx: *SchemeContext = @ptrCast(@alignCast(user_data));

    // webkit_uri_scheme_request_get_path returns the path portion of the
    // request URI (e.g. "/index.html" for "app://localhost/index.html").
    // It always returns a non-null string for valid requests.
    const path_z: [*:0]const u8 = webkit_uri_scheme_request_get_path(request);
    const path = std.mem.span(path_z);

    // O(1) lookup through the prebuilt index (see buildAssetIndex).
    // Falls back to the empty-serve path when the map has no entry —
    // same not-found semantics as the old linear scan.
    if (ctx.asset_index.get(path)) |asset_idx| {
        serveAsset(request, ctx.assets[asset_idx]);
        return;
    }

    // Asset not found — return an empty body with a plain MIME type. We
    // deliberately don't propagate a GError because (a) constructing one
    // is verbose and (b) a 200 with empty body lets the webview fall
    // through to its own 404 handling without crashing on a missing
    // asset (e.g. favicon.ico requests from the browser).
    serveEmpty(request, "text/plain");
}

/// Wrap an asset's content in a GBytes + GMemoryInputStream and hand it
/// off to WebKit via webkit_uri_scheme_request_finish(). The bytes are
/// copied (g_bytes_new copies), so it's safe even if the asset table is
/// freed (which it isn't, per the C ABI contract, but defense in depth
/// is cheap).
fn serveAsset(
    request: *WebKitURISchemeRequest,
    asset: webview.CAsset,
) void {
    const bytes = g_bytes_new(asset.content, asset.content_len);
    defer g_object_unref(@ptrCast(bytes));

    const stream = g_memory_input_stream_new_from_bytes(bytes);
    defer g_object_unref(@ptrCast(stream));

    webkit_uri_scheme_request_finish(
        request,
        stream,
        @intCast(asset.content_len),
        asset.mime,
    );
}

/// Return an empty body with the given content type. Used for the
/// "asset not found" case — keeps the request pipeline happy without
/// the verbosity of building a GError.
fn serveEmpty(
    request: *WebKitURISchemeRequest,
    content_type: [*:0]const u8,
) void {
    const empty = "";
    const bytes = g_bytes_new(empty.ptr, 0);
    defer g_object_unref(@ptrCast(bytes));

    const stream = g_memory_input_stream_new_from_bytes(bytes);
    defer g_object_unref(@ptrCast(stream));

    webkit_uri_scheme_request_finish(
        request,
        stream,
        0,
        content_type,
    );
}

// =============================================================================
// Force-link markers
// =============================================================================
//
// `pub const`s at module scope create real symbols in the output binary.
// The Zig linker (with LTO) is aggressive about dead-code elimination:
// an `export fn` that's never called and never addressed gets removed
// along with the whole linux.zig compilation, dropping the GTK/WebKit
// system library dependencies from the link. The three `pub const`s
// below keep the C ABI implementations alive by giving the linker a
// runtime reference to each.
//
// Chunk 8 will replace these with the real `webview.run()` call from
// the app's main flow — at that point, `run` itself transitively
// references the extern "c" symbols, and the force-link markers become
// redundant (the linker keeps the implementation because it's actually
// used).

/// Function-pointer type for `nalar_webview_create` — referenced by the
/// force-link `pub const` below to keep the symbol alive in the output.
pub const create_fn = *const fn (
    *const webview.Config,
    [*:0]const u8,
) callconv(.c) ?*webview.Webview;
pub const create_keepalive: create_fn = nalar_webview_create;

/// Function-pointer type for `nalar_webview_run` — same pattern as
/// `create_keepalive` above.
pub const run_fn = *const fn (*webview.Webview) callconv(.c) void;
pub const run_keepalive: run_fn = nalar_webview_run;

/// Function-pointer type for `nalar_webview_destroy` — same pattern.
pub const destroy_fn = *const fn (*webview.Webview) callconv(.c) void;
pub const destroy_keepalive: destroy_fn = nalar_webview_destroy;
