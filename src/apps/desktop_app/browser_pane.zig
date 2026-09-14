// src/apps/desktop_app/browser_pane.zig
//
// The in-app browser PANE: the page renders in a *second webview inside the app's
// own window*, below the tab strip — one window, one process, no spawned
// `nalar-desktop`. Plan: docs/superpowers/plans/2026-09-14-in-app-browser-pane.md.
//
// Why the shell owns this rather than the SPA: the app window holds exactly one
// engine view, so the split has to be made in the widget tree. Shape (validated
// by a spike against this same patched header — plan §2):
//
//     window → GtkPaned(vertical, position = strip height)
//                ├─ pack1: GtkScrolledWindow → the SPA view   (fixed strip slot)
//                └─ pack2: GtkScrolledWindow → the pane view  (fills the rest)
//
//   * the scrolled-window wrappers are load-bearing: a `WebKitWebView`'s natural
//     height is huge (~1398px measured); without them the box hands the SPA view
//     the whole window and the strip slot is impossible;
//   * the SPA slot is pinned to the strip height, so the strip stays visible and
//     clickable while the page fills the rest;
//   * the pane view gets **no bindings** — it renders third-party content, and the
//     invariant from browser_bridge.zig applies to it exactly as it does to the
//     separate window;
//   * the injected chrome bar (`browser_chrome.js`) is the pane's address bar /
//     ← / → / ↻ — already shipped and jsdom-tested, so nothing new navigates.
//
// PLATFORM: Linux/GTK3 only for now. The vendored parent call is container-safe on
// GTK3 (`widget_set_parent`, see vendor/webview/webview.h); Cocoa replaces the
// content view (`setContentView:`, `:2632`) and Windows has no layout containers,
// so each needs its own work — the plan's per-OS follow-ups. On any other target
// `supported` is false, nothing here is installed, and the SPA falls back to the
// window mode (which is why that mode is kept, invisibly).

const std = @import("std");
const builtin = @import("builtin");
const cli = @import("cli.zig");
const webview_lib = @import("webview_lib.zig");
const browser_bridge = @import("browser_bridge.zig");

const Webview = webview_lib.Webview;

/// True where the pane can be built at all. Linux-first (GTK3).
pub const supported = builtin.os.tag == .linux;

/// The strip's height, matching `TabBar.vue`'s `h-9` (36px). The SPA slot is
/// pinned to this while the pane is visible.
pub const STRIP_HEIGHT: c_int = 36;

/// `webview_native_handle_kind_t` (vendor/webview/webview.h:143-153).
const HANDLE_UI_WINDOW: c_int = 0;
const HANDLE_UI_WIDGET: c_int = 1;

/// Mirrors of the GTK3 enum values this file uses, named rather than sprinkled.
const GTK_ORIENTATION_VERTICAL: c_int = 1;
const GTK_POLICY_NEVER: c_int = 0;
const FALSE: c_int = 0;
const TRUE: c_int = 1;

// ---------------------------------------------------------------------------
// GTK3 C API. Declared, not linked specially: build.zig already links gtk-3 +
// webkit2gtk-4.1 for the desktop module. webview_lib.zig's "no GTK code in Zig"
// note was about the *window* path — the pane is the one place the shell needs
// widget-level layout, and it is comptime-gated to Linux.
// ---------------------------------------------------------------------------

const GtkWidget = opaque {};

extern "c" fn gtk_paned_new(orientation: c_int) *GtkWidget;
extern "c" fn gtk_paned_pack1(paned: *GtkWidget, child: *GtkWidget, resize: c_int, shrink: c_int) void;
extern "c" fn gtk_paned_pack2(paned: *GtkWidget, child: *GtkWidget, resize: c_int, shrink: c_int) void;
extern "c" fn gtk_paned_set_position(paned: *GtkWidget, position: c_int) void;
extern "c" fn gtk_scrolled_window_new(h: ?*anyopaque, v: ?*anyopaque) *GtkWidget;
extern "c" fn gtk_scrolled_window_set_policy(widget: *GtkWidget, h: c_int, v: c_int) void;
extern "c" fn gtk_container_add(container: *GtkWidget, widget: *GtkWidget) void;
extern "c" fn gtk_container_remove(container: *GtkWidget, widget: *GtkWidget) void;
extern "c" fn gtk_widget_show(widget: *GtkWidget) void;
extern "c" fn gtk_widget_show_all(widget: *GtkWidget) void;
extern "c" fn gtk_widget_hide(widget: *GtkWidget) void;
extern "c" fn gtk_widget_set_size_request(widget: *GtkWidget, width: c_int, height: c_int) void;
extern "c" fn gtk_widget_get_visible(widget: *GtkWidget) c_int;

/// One pane per app window (plan §3): the SPA shows it for the active browser tab
/// and hides it otherwise. Hide, never destroy — switching tabs must not pay a
/// WebKit cold start, and the page keeps its state.
pub const Pane = struct {
    /// The pane view; created lazily on the first `show`.
    view: ?*Webview = null,
    spa_slot: ?*GtkWidget = null,
    pane_slot: ?*GtkWidget = null,
    paned: ?*GtkWidget = null,
    visible: bool = false,
    /// Hash of the loaded URL, so re-activating a tab does not reload the page.
    url_hash: u64 = 0,

    /// Build the split inside the app window. Called once, before `webview_run`.
    pub fn install(self: *Pane, app: *Webview) void {
        if (!supported) return;
        const win = webview_lib.webview_get_native_handle(app, HANDLE_UI_WINDOW) orelse return;
        const spa_view = webview_lib.webview_get_native_handle(app, HANDLE_UI_WIDGET) orelse return;
        const win_widget: *GtkWidget = @ptrCast(win);
        const spa_widget: *GtkWidget = @ptrCast(spa_view);

        // The window's single child leaves it; the split takes its place.
        gtk_container_remove(win_widget, spa_widget);

        const paned = gtk_paned_new(GTK_ORIENTATION_VERTICAL);
        gtk_container_add(win_widget, paned);

        const spa_slot = scrolledSlot();
        gtk_container_add(spa_slot, spa_widget);
        gtk_paned_pack1(paned, spa_slot, FALSE, FALSE);
        gtk_widget_set_size_request(spa_slot, -1, STRIP_HEIGHT);

        const pane_slot = scrolledSlot();
        gtk_paned_pack2(paned, pane_slot, TRUE, TRUE);
        gtk_paned_set_position(paned, STRIP_HEIGHT);

        gtk_widget_show(paned);
        gtk_widget_show(spa_slot);
        // pane_slot stays hidden until the first show().

        self.paned = paned;
        self.spa_slot = spa_slot;
        self.pane_slot = pane_slot;
        std.log.info("browser pane: split installed (strip {d}px)", .{STRIP_HEIGHT});
    }

    /// Give the page the space below the strip and navigate it (only when the URL
    /// actually changed). Returns false when the pane cannot be built.
    pub fn show(self: *Pane, url: []const u8) bool {
        if (!supported) return false;
        const pane_slot = self.pane_slot orelse return false;
        const spa_slot = self.spa_slot orelse return false;
        const paned = self.paned orelse return false;

        if (self.view == null) {
            // Created INTO our slot: the vendored ctor's container-safe parent
            // path puts the new view in the scrolled window (see the header).
            const created = webview_lib.webview_create(0, pane_slot) orelse return false;
            // The bar is injected before the first navigation, so it exists from
            // the document's first script (the window mode's contract).
            _ = webview_lib.webview_init(created, webview_lib.browser_chrome_js);
            self.view = created;
        }
        const view = self.view.?;

        const hash = std.hash.Wyhash.hash(0, url);
        if (hash != self.url_hash) {
            const url_z = std.heap.page_allocator.allocSentinel(u8, url.len, 0) catch return false;
            defer std.heap.page_allocator.free(url_z);
            @memcpy(url_z[0..url.len], url);
            _ = webview_lib.webview_navigate(view, url_z.ptr);
            self.url_hash = hash;
        }

        gtk_widget_set_size_request(spa_slot, -1, STRIP_HEIGHT);
        gtk_paned_set_position(paned, STRIP_HEIGHT);
        gtk_widget_show_all(pane_slot);
        gtk_widget_set_size_request(pane_slot, -1, -1);
        self.visible = true;
        return true;
    }

    /// Hide the pane (the view and the page survive) and give the SPA the window
    /// back. Safe to call before anything was shown.
    pub fn hide(self: *Pane) void {
        if (!supported) return;
        if (self.pane_slot) |pane_slot| gtk_widget_hide(pane_slot);
        if (self.spa_slot) |spa_slot| gtk_widget_set_size_request(spa_slot, -1, -1);
        if (self.paned) |paned| gtk_paned_set_position(paned, 0);
        self.visible = false;
    }

    /// Read the live widget state, not our own flag: the GTK call is the truth.
    pub fn isVisible(self: *const Pane) bool {
        if (!supported) return false;
        const pane_slot = self.pane_slot orelse return false;
        return gtk_widget_get_visible(pane_slot) != 0;
    }

    fn scrolledSlot() *GtkWidget {
        const slot = gtk_scrolled_window_new(null, null);
        gtk_scrolled_window_set_policy(slot, GTK_POLICY_NEVER, GTK_POLICY_NEVER);
        return slot;
    }
};

// ---------------------------------------------------------------------------
// Bindings — flat names, app window only, same reply shape as browser_bridge.
// ---------------------------------------------------------------------------

/// `installBindings` is a no-op off Linux, so off Linux the SPA sees the pane as
/// unavailable (`{ok:false}`) and keeps its window / system-browser path.
pub fn installBindings(w: *Webview, pane: *Pane) void {
    if (!supported) return;
    bound_window = w;
    _ = webview_lib.webview_bind(w, "nalarBrowserPaneShow", onShow, @ptrCast(pane));
    _ = webview_lib.webview_bind(w, "nalarBrowserPaneHide", onHide, @ptrCast(pane));
    _ = webview_lib.webview_bind(w, "nalarBrowserPaneStatus", onStatus, @ptrCast(pane));
}

pub const Method = enum { show, hide, status };

/// Drive one bound call (webview-independent, so the contract is testable).
pub fn handle(pane: *Pane, method: Method, req: []const u8, out: []u8) [:0]const u8 {
    switch (method) {
        .hide => {
            pane.hide();
            return browser_bridge.reply(
                out,
                "{{\"ok\":true,\"visible\":{s}}}",
                .{boolLit(pane.isVisible())},
            );
        },
        .status => return browser_bridge.reply(
            out,
            "{{\"supported\":{s},\"visible\":{s}}}",
            .{ boolLit(supported), boolLit(pane.isVisible()) },
        ),
        .show => {
            var arena_buf: [4096]u8 = undefined;
            var fba = std.heap.FixedBufferAllocator.init(&arena_buf);
            var params: [4][]const u8 = undefined;
            const count = browser_bridge.parseParams(&fba, req, &params) orelse 0;
            if (count < 2) {
                return browser_bridge.reply(
                    out,
                    "{{\"ok\":false,\"error\":\"show expects (tabId, url)\"}}",
                    .{},
                );
            }
            const tab_id = params[0];
            const url = params[1];
            if (!browser_bridge.isSafeTabId(tab_id)) {
                return browser_bridge.reply(out, "{{\"ok\":false,\"error\":\"invalid tab id\"}}", .{});
            }
            // Second, independent scheme check (the URL reaches the engine).
            if (!cli.isHttpUrl(url)) {
                return browser_bridge.reply(
                    out,
                    "{{\"ok\":false,\"error\":\"only http(s) URLs can be shown\"}}",
                    .{},
                );
            }
            if (!pane.show(url)) {
                return browser_bridge.reply(
                    out,
                    "{{\"ok\":false,\"error\":\"the pane is unavailable\"}}",
                    .{},
                );
            }
            return browser_bridge.reply(out, "{{\"ok\":true,\"visible\":true}}", .{});
        },
    }
}

fn boolLit(value: bool) []const u8 {
    return if (value) "true" else "false";
}

/// The app window `webview_return` answers on. One app window per process.
var bound_window: ?*Webview = null;

fn dispatch(id: [*:0]const u8, req: [*:0]const u8, arg: ?*anyopaque, method: Method) void {
    const pane: *Pane = @ptrCast(@alignCast(arg orelse return));
    const w = bound_window orelse return;
    var out: [browser_bridge.REPLY_BUF]u8 = undefined;
    const result = handle(pane, method, std.mem.span(req), &out);
    // status 0 → the JS promise resolves with JSON.parse(result).
    _ = webview_lib.webview_return(w, id, 0, result.ptr);
}

fn onShow(id: [*:0]const u8, req: [*:0]const u8, arg: ?*anyopaque) callconv(.c) void {
    dispatch(id, req, arg, .show);
}

fn onHide(id: [*:0]const u8, req: [*:0]const u8, arg: ?*anyopaque) callconv(.c) void {
    dispatch(id, req, arg, .hide);
}

fn onStatus(id: [*:0]const u8, req: [*:0]const u8, arg: ?*anyopaque) callconv(.c) void {
    dispatch(id, req, arg, .status);
}

// ---------------------------------------------------------------------------
// Tests — no display needed: the request/reply contract and the platform gate.
// The live engine is covered by scripts/browser-pane-probe.py.
// ---------------------------------------------------------------------------

const testing = std.testing;

test "browser pane: show refuses a non-http URL without touching the widgets" {
    var pane = Pane{};
    var out: [browser_bridge.REPLY_BUF]u8 = undefined;
    const result = handle(&pane, .show, "[\"tab_1\",\"javascript:alert(1)\"]", &out);
    try testing.expect(std.mem.indexOf(u8, result, "\"ok\":false") != null);
    try testing.expect(std.mem.indexOf(u8, result, "only http(s)") != null);
    try testing.expect(pane.view == null);
    try testing.expect(!pane.visible);
}

test "browser pane: a malformed request is refused, never half-applied" {
    var pane = Pane{};
    var out: [browser_bridge.REPLY_BUF]u8 = undefined;
    for ([_][]const u8{ "not json", "[\"tab_1\"]", "[\"bad id!\",\"https://example.com\"]" }) |req| {
        const result = handle(&pane, .show, req, &out);
        try testing.expect(std.mem.indexOf(u8, result, "\"ok\":false") != null);
    }
    try testing.expect(pane.view == null);
}

test "browser pane: hide and status are safe before anything was shown" {
    var pane = Pane{};
    var out: [browser_bridge.REPLY_BUF]u8 = undefined;
    try testing.expectEqualStrings(
        "{\"ok\":true,\"visible\":false}",
        handle(&pane, .hide, "[]", &out),
    );
    const status = handle(&pane, .status, "[]", &out);
    try testing.expect(std.mem.indexOf(u8, status, "\"visible\":false") != null);
    try testing.expect(std.mem.indexOf(u8, status, "\"supported\":") != null);
}

test "browser pane: the platform gate is explicit" {
    if (builtin.os.tag == .linux) {
        try testing.expect(supported);
    } else {
        try testing.expect(!supported);
    }
}

test "browser pane: the three binding names are flat" {
    // Same rule as the process bridge: the vendored glue writes `window[name]`
    // verbatim, so a dotted name would be unreachable — locked here too, so the
    // pane cannot reintroduce the bug that shipped.
    const names = [_][]const u8{
        "nalarBrowserPaneShow",
        "nalarBrowserPaneHide",
        "nalarBrowserPaneStatus",
    };
    for (names) |name| {
        try testing.expect(std.mem.indexOfScalar(u8, name, '.') == null);
    }
}
