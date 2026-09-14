// src/apps/desktop_app/browser_pane.zig
//
// The in-app browser PANE: the page renders in a *second webview* inside the app
// window, BESIDE the app's own content — one window, one process, no spawned
// `nalar-desktop`, no separate window.
// Plan: docs/superpowers/plans/2026-09-14-in-app-browser-pane.md (rev 3).
//
// Layout (rev 3 — GTK owns the geometry, on purpose):
//
//     window → GtkPaned(HORIZONTAL)
//                ├─ pack1 (resize=true):  the SPA's view  → the app, left
//                └─ pack2 (resize=false): the pane host   → the page, right
//                     with a HARDCODED width (PANE_WIDTH)
//
// Why a paned and not an overlay with a computed rect (rev 1/2): an overlay child
// placed by hand had paint and INPUT disagree — the app painted correctly while
// clicks meant for the sidebar never landed there, and a mapped-but-unplaced
// child fell back to the overlay's default full-window allocation and swallowed
// every click. With a paned, GTK lays out and hit-tests the same rectangles: the
// two views cannot overlap, so the app stays fully clickable, and the divider is
// even draggable for free.
//
// The trade-off is honest and visible: while a browser tab is up the app's own
// content is narrower (the pane takes PANE_WIDTH on the right). The strip and the
// sidebar stay in the left half, fully interactive.
//
// PLATFORM: Linux/GTK3 only for now. Off Linux `supported` is false, nothing is
// installed, and the SPA falls back to the window mode.

const std = @import("std");
const builtin = @import("builtin");
const cli = @import("cli.zig");
const webview_lib = @import("webview_lib.zig");
const browser_bridge = @import("browser_bridge.zig");

const Webview = webview_lib.Webview;

/// True where the pane can be built at all. Linux-first (GTK3).
pub const supported = builtin.os.tag == .linux;

/// The pane's width in logical px. Hardcoded on purpose: GTK keeps it, so the
/// page never covers the app and the geometry is not something the SPA can get
/// wrong. The divider is draggable, so the user can adjust it live.
pub const PANE_WIDTH: c_int = 560;

/// `webview_native_handle_kind_t` (vendor/webview/webview.h:143-153).
const HANDLE_UI_WINDOW: c_int = 0;
const HANDLE_UI_WIDGET: c_int = 1;
const HANDLE_BROWSER_CONTROLLER: c_int = 2;

/// Mirror of the GTK3 enum values this file uses, named rather than sprinkled.
const GTK_POLICY_NEVER: c_int = 0;
const GTK_ORIENTATION_HORIZONTAL: c_int = 0;
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
extern "c" fn gtk_widget_get_visible(widget: *GtkWidget) c_int;
extern "c" fn gtk_widget_set_size_request(widget: *GtkWidget, width: c_int, height: c_int) void;
extern "c" fn gtk_widget_get_allocated_width(widget: *GtkWidget) c_int;
extern "c" fn gtk_widget_get_allocated_height(widget: *GtkWidget) c_int;
/// `WEBVIEW_NATIVE_HANDLE_KIND_BROWSER_CONTROLLER` — the WebKitWebView itself,
/// which is how the shell can see what the pane actually loaded.
extern "c" fn webkit_web_view_get_uri(view: *anyopaque) ?[*:0]const u8;

/// One pane per app window (plan §3): the SPA shows it for the active browser
/// tab and hides it otherwise. Hide, never destroy, when merely leaving a tab.
pub const Pane = struct {
    /// The pane view; created lazily on the first `show`.
    view: ?*Webview = null,
    paned: ?*GtkWidget = null,
    /// The scrolled window the pane view lives in — what GTK lays out.
    panel: ?*GtkWidget = null,
    /// The scrolled window holding the SPA's view (the left/top half).
    spa_slot: ?*GtkWidget = null,
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
        const paned = gtk_paned_new(GTK_ORIENTATION_HORIZONTAL);
        gtk_container_add(win_widget, paned);

        // Left: the SPA (the app). resize=true → it absorbs window resizes.
        const spa_slot = scrolledSlot();
        gtk_container_add(spa_slot, spa_widget);
        // A floor on the app's side: the pane's width is fixed, so a narrow window
        // must not squeeze the app out of existence.
        gtk_widget_set_size_request(spa_slot, 360, -1);
        gtk_paned_pack1(paned, spa_slot, TRUE, TRUE);

        // Right: the pane, at a fixed width. resize=false → it keeps its width
        // while the window resizes, so the page never grows over the app.
        const panel = scrolledSlot();
        gtk_widget_set_size_request(panel, PANE_WIDTH, -1);
        gtk_paned_pack2(paned, panel, FALSE, TRUE);

        // NO gtk_paned_set_position: with pack2 resize=false, GTK gives the pane
        // exactly its size request and the app everything else — automatically,
        // and correctly for whatever the window's real size turns out to be.
        // (Setting a position from a guessed width is what left the pane a
        // 60px sliver: the width at that moment was not the final one.)
        // The divider stays user-draggable on top of that.

        gtk_widget_show(paned);
        gtk_widget_show(spa_slot);
        // `panel` stays hidden until the first show(): with one visible child the
        // SPA gets the whole window, i.e. the app looks exactly as it does today.

        self.paned = paned;
        self.spa_slot = spa_slot;
        self.panel = panel;
        std.log.info("browser pane: split installed ({d}px panel)", .{PANE_WIDTH});
    }

    /// Show the pane and navigate it (only when the URL changed). The `rect` the
    /// SPA may send is deliberately IGNORED now (GTK owns the geometry); the
    /// parameter stays so the binding contract is unchanged.
    pub fn show(self: *Pane, url: []const u8, rect: ?Rect) bool {
        if (!supported) return false;
        const panel = self.panel orelse return false;
        _ = rect;

        if (self.view == null) {
            // Created INTO our panel: the vendored ctor's container-safe parent
            // path puts the new view in the scrolled window (see the header).
            const created = webview_lib.webview_create(0, panel) orelse return false;
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

        gtk_widget_show_all(panel);
        if (self.paned) |paned| gtk_widget_show(paned);
        self.visible = true;
        return true;
    }

    /// Kept for the binding contract: the geometry is GTK's, so there is nothing
    /// to move. A no-op is the point — that is what removed the whole class of
    /// "the pane covered the app / ate its clicks" bugs.
    pub fn setRect(self: *Pane, rect: Rect) void {
        if (!supported) return;
        _ = rect;
        _ = self;
    }

    /// Hide the pane (the view and the page survive; the app gets the window back).
    pub fn hide(self: *Pane) void {
        if (!supported) return;
        if (self.panel) |panel| gtk_widget_hide(panel);
        self.visible = false;
    }

    /// Destroy the pane view so **nothing keeps running**. Used when the browser
    /// tab is *closed* (leaving it is `hide`).
    pub fn close(self: *Pane) bool {
        if (!supported) return false;
        if (self.view) |view| {
            // The vendored destructor removes the widget from the host (our
            // container-safe helper) and releases the webview.
            _ = webview_lib.webview_destroy(view);
            self.view = null;
        }
        if (self.panel) |panel| gtk_widget_hide(panel);
        self.visible = false;
        self.url_hash = 0;
        std.log.info("browser pane: view destroyed (nothing running)", .{});
        return true;
    }

    /// Read the live widget state, not our own flag: the GTK call is the truth.
    pub fn isVisible(self: *const Pane) bool {
        if (!supported) return false;
        const panel = self.panel orelse return false;
        return gtk_widget_get_visible(panel) != 0;
    }

    /// The panel's REAL allocated size — reported in `status` so a mis-sized pane
    /// is readable in one log line instead of guessed at.
    pub fn allocWidth(self: *const Pane) c_int {
        if (!supported) return 0;
        const panel = self.panel orelse return 0;
        return gtk_widget_get_allocated_width(panel);
    }

    pub fn allocHeight(self: *const Pane) c_int {
        if (!supported) return 0;
        const panel = self.panel orelse return 0;
        return gtk_widget_get_allocated_height(panel);
    }

    /// Length of the URL the pane has actually loaded (0 when there is no view).
    pub fn uriLen(self: *const Pane) usize {
        if (!supported) return 0;
        const view = self.view orelse return 0;
        const raw = webview_lib.webview_get_native_handle(view, HANDLE_BROWSER_CONTROLLER) orelse return 0;
        const uri = webkit_web_view_get_uri(raw) orelse return 0;
        return std.mem.span(uri).len;
    }

    fn scrolledSlot() *GtkWidget {
        const slot = gtk_scrolled_window_new(null, null);
        gtk_scrolled_window_set_policy(slot, GTK_POLICY_NEVER, GTK_POLICY_NEVER);
        return slot;
    }
};

/// The rect the SPA may send. Ignored by the layout (rev 3) but kept in the
/// binding contract so the frontend did not have to change.
pub const Rect = extern struct {
    x: c_int = 0,
    y: c_int = 0,
    width: c_int = 0,
    height: c_int = 0,
};

// ---------------------------------------------------------------------------
// Bindings — flat names, app window only, same reply shape as browser_bridge.
// ---------------------------------------------------------------------------

/// A no-op off Linux, so off Linux the SPA sees the pane as unavailable
/// (`{ok:false}`) and keeps its window / system-browser path.
pub fn installBindings(w: *Webview, pane: *Pane) void {
    if (!supported) return;
    bound_window = w;
    _ = webview_lib.webview_bind(w, "nalarBrowserPaneShow", onShow, @ptrCast(pane));
    _ = webview_lib.webview_bind(w, "nalarBrowserPaneRect", onRect, @ptrCast(pane));
    _ = webview_lib.webview_bind(w, "nalarBrowserPaneHide", onHide, @ptrCast(pane));
    _ = webview_lib.webview_bind(w, "nalarBrowserPaneClose", onClose, @ptrCast(pane));
    _ = webview_lib.webview_bind(w, "nalarBrowserPaneStatus", onStatus, @ptrCast(pane));
}

pub const Method = enum { show, rect, hide, close, status };

/// Drive one bound call (webview-independent, so the contract is testable).
/// Logs one line per call: these are user-driven events (never a loop), and the
/// line is what makes "the pane did not appear" diagnosable from the app's output.
pub fn handle(pane: *Pane, method: Method, req: []const u8, out: []u8) [:0]const u8 {
    const result = handleInner(pane, method, req, out);
    std.log.info(
        "browser pane: {s} alloc=[{d},{d}] reply={s}",
        .{ @tagName(method), pane.allocWidth(), pane.allocHeight(), result },
    );
    return result;
}

fn handleInner(pane: *Pane, method: Method, req: []const u8, out: []u8) [:0]const u8 {
    var arena_buf: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&arena_buf);
    var params: [8][]const u8 = undefined;
    const count = parseLoose(&fba, req, &params) orelse 0;

    switch (method) {
        .hide => {
            pane.hide();
            return okReply(pane, out);
        },
        .close => {
            _ = pane.close();
            return okReply(pane, out);
        },
        .rect => {
            // Accepted and ignored: the geometry is GTK's (see the file header).
            return okReply(pane, out);
        },
        .status => return browser_bridge.reply(
            out,
            "{{\"supported\":{s},\"visible\":{s},\"uri_len\":{d},\"panel_width\":{d},\"alloc\":[{d},{d}]}}",
            .{
                boolLit(supported),
                boolLit(pane.isVisible()),
                pane.uriLen(),
                PANE_WIDTH,
                pane.allocWidth(),
                pane.allocHeight(),
            },
        ),
        .show => {
            if (count < 2) {
                return browser_bridge.reply(
                    out,
                    "{{\"ok\":false,\"error\":\"show expects (tabId, url[, x, y, width, height])\"}}",
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
            if (!pane.show(url, null)) {
                return browser_bridge.reply(
                    out,
                    "{{\"ok\":false,\"error\":\"the pane is unavailable\"}}",
                    .{},
                );
            }
            return okReply(pane, out);
        },
    }
}

fn okReply(pane: *Pane, out: []u8) [:0]const u8 {
    return browser_bridge.reply(
        out,
        "{{\"ok\":true,\"visible\":{s},\"panel_width\":{d},\"alloc\":[{d},{d}]}}",
        .{
            boolLit(pane.isVisible()),
            PANE_WIDTH,
            pane.allocWidth(),
            pane.allocHeight(),
        },
    );
}

fn boolLit(value: bool) []const u8 {
    return if (value) "true" else "false";
}

/// JSON array → strings, accepting numbers as well as strings (the SPA may send
/// either; `browser_bridge.parseParams` is string-only).
fn parseLoose(fba: *std.heap.FixedBufferAllocator, req: []const u8, out: *[8][]const u8) ?usize {
    const parsed = std.json.parseFromSlice(std.json.Value, fba.allocator(), req, .{}) catch return null;
    const items = switch (parsed.value) {
        .array => |array| array.items,
        else => return null,
    };
    if (items.len > out.len) return null;
    for (items, 0..) |item, index| {
        out[index] = switch (item) {
            .string => |text| text,
            .number_string => |text| text,
            .integer => |number| std.fmt.allocPrint(fba.allocator(), "{d}", .{number}) catch return null,
            .float => |number| std.fmt.allocPrint(
                fba.allocator(),
                "{d}",
                .{@as(i64, @intFromFloat(number))},
            ) catch return null,
            else => return null,
        };
    }
    return items.len;
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

fn onRect(id: [*:0]const u8, req: [*:0]const u8, arg: ?*anyopaque) callconv(.c) void {
    dispatch(id, req, arg, .rect);
}

fn onHide(id: [*:0]const u8, req: [*:0]const u8, arg: ?*anyopaque) callconv(.c) void {
    dispatch(id, req, arg, .hide);
}

fn onClose(id: [*:0]const u8, req: [*:0]const u8, arg: ?*anyopaque) callconv(.c) void {
    dispatch(id, req, arg, .close);
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
    for ([_][]const u8{
        "not json",
        "[\"tab_1\"]",
        "[\"bad id!\",\"https://example.com\"]",
    }) |req| {
        const result = handle(&pane, .show, req, &out);
        try testing.expect(std.mem.indexOf(u8, result, "\"ok\":false") != null);
    }
    try testing.expect(pane.view == null);
}

test "browser pane: hide, close and status are safe before anything was shown" {
    var pane = Pane{};
    var out: [browser_bridge.REPLY_BUF]u8 = undefined;
    const hidden = handle(&pane, .hide, "[]", &out);
    try testing.expect(std.mem.indexOf(u8, hidden, "\"ok\":true") != null);
    try testing.expect(std.mem.indexOf(u8, hidden, "\"visible\":false") != null);

    pane.url_hash = 0xdeadbeef;
    _ = handle(&pane, .close, "[]", &out);
    try testing.expectEqual(@as(u64, 0), pane.url_hash);

    const status = handle(&pane, .status, "[]", &out);
    try testing.expect(std.mem.indexOf(u8, status, "\"visible\":false") != null);
    try testing.expect(std.mem.indexOf(u8, status, "\"supported\":") != null);
    try testing.expect(std.mem.indexOf(u8, status, "\"panel_width\":") != null);
}

test "browser pane: the geometry is GTK's, so a rect is accepted and ignored" {
    // The whole point of rev 3: the SPA cannot influence the placement, so a
    // wrong/absent rect can no longer cover the app or its clicks.
    var pane = Pane{};
    var out: [browser_bridge.REPLY_BUF]u8 = undefined;
    const result = handle(&pane, .rect, "[\"0\",\"0\",\"99999\",\"99999\"]", &out);
    try testing.expect(std.mem.indexOf(u8, result, "\"ok\":true") != null);
}

test "browser pane: the platform gate is explicit" {
    if (builtin.os.tag == .linux) {
        try testing.expect(supported);
    } else {
        try testing.expect(!supported);
    }
}

test "browser pane: the five binding names are flat" {
    // Same rule as the process bridge: the vendored glue writes `window[name]`
    // verbatim, so a dotted name would be unreachable.
    const names = [_][]const u8{
        "nalarBrowserPaneShow",
        "nalarBrowserPaneRect",
        "nalarBrowserPaneHide",
        "nalarBrowserPaneClose",
        "nalarBrowserPaneStatus",
    };
    for (names) |name| {
        try testing.expect(std.mem.indexOfScalar(u8, name, '.') == null);
    }
}
