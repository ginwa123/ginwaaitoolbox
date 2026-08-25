// src/apps/desktop_app/webview.zig
//
// Zig wrapper around the shared webview C ABI (see shared/webview_c.h).
// The C ABI is implemented by 3 platform-specific files:
//   - platform/linux.zig   (Chunk 5: WebKitGTK 4.1 + GTK 3 via @cImport)
//   - platform/macos.zig   (Chunk 6: WKWebView via .mm shim)
//   - platform/windows.zig (Chunk 7: WebView2 via .cpp shim)
//
// At link time, the build system selects ONE of the three platform .o files
// based on the target OS. The Zig side of this file is platform-agnostic.

const std = @import("std");

/// Mirror of nalar_webview (opaque on the C side).
pub const Webview = opaque {};

/// Mirror of nalar_webview_asset.
pub const CAsset = extern struct {
    path: [*:0]const u8,
    content: [*]const u8,
    content_len: usize,
    mime: [*:0]const u8,
};

/// Graphics/compositing preset for the embedded webview.
///
/// WebKitGTK (Linux) picks its rendering path from environment variables
/// read during GLib/WebKit init. Driver support varies wildly — some
/// setups silently fall back to software rendering (slow scrolling),
/// others glitch with the DMABUF renderer. The presets let users pick a
/// known-good combination without editing platform code:
///
///   .auto   — pin acceleration-friendly defaults, but respect any value
///             already present in the process environ (user override wins)
///   .compat — force the conservative path (DMABUF renderer disabled);
///             for machines that render black/glitched windows with
///             DMABUF (older NVIDIA, some virtualized GPUs)
///   .debug  — same as auto plus WEBKIT_DEBUG compositing output on stderr
pub const GfxPreset = enum(c_int) { auto = 0, compat = 1, debug = 2 };

/// Mirror of nalar_webview_config.
pub const Config = extern struct {
    title: [*:0]const u8 = "Nalar",
    width: c_int = 1280,
    height: c_int = 800,
    min_width: c_int = 400,
    min_height: c_int = 300,
    resizable: bool = true,
    maximizable: bool = true,
    minimizable: bool = true,
    user_agent: ?[*:0]const u8 = null,
    icon_path: ?[*:0]const u8 = null,
    assets: [*]const CAsset = &.{},
    asset_count: usize = 0,
    /// When true, the platform enables developer-extras (right-click →
    /// Inspect Element → DevTools). Off by default; enable with the
    /// nalar-desktop `--devtools` flag.
    enable_developer_extras: bool = false,
    /// Linux-only today (no-op elsewhere): which WebKitGTK gfx env preset
    /// to apply before gtk_init. See GfxPreset docs above.
    gfx_preset: GfxPreset = .auto,
};

// extern "c" declarations of the C ABI. The implementations live in
// platform/{linux,macos,windows}.zig; the build links the matching one.
extern "c" fn nalar_webview_create(
    cfg: *const Config,
    url: [*:0]const u8,
) ?*Webview;

extern "c" fn nalar_webview_run(wv: *Webview) void;
extern "c" fn nalar_webview_destroy(wv: *Webview) void;

/// High-level Zig wrapper. Allocates a null-terminated copy of `url`, calls
/// into the C ABI to create the webview, runs the platform event loop
/// (blocks until the window closes), and destroys the webview on return.
///
/// Errors:
///   - error.WebviewCreateFailed: the platform implementation returned NULL
///     (window creation failed, WebView2 init failed, etc.)
///   - error.OutOfMemory: `allocator.dupeZ` for `url` failed
pub fn run(allocator: std.mem.Allocator, cfg: Config, url: []const u8) !void {
    const url_z = try allocator.dupeZ(u8, url);
    defer allocator.free(url_z);
    const wv = nalar_webview_create(&cfg, url_z) orelse return error.WebviewCreateFailed;
    defer nalar_webview_destroy(wv);
    nalar_webview_run(wv);
}
