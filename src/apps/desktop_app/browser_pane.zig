// src/apps/desktop_app/browser_pane.zig
//
// The in-app browser PANE: the page renders in a *second webview* that sits
// INSIDE the app window, over the browser tab's body — so the app's own chrome
// (sidebar, tab strip, other tabs) stays visible beside it. One window, one
// process, no spawned `nalar-desktop`.
// Plan: docs/superpowers/plans/2026-09-14-in-app-browser-pane.md (rev 2).
//
// Layout (rev 2 — the first cut shrank the SPA to a 36px strip and gave the page
// the whole window, which is not "side by side"):
//
//     window → GtkOverlay
//                ├─ main child: the SPA view (fills the window, unchanged)
//                └─ overlay child: the pane host (a scrolled window) — placed at
//                   the rect the SPA reports for the browser tab's BODY
//
//   * the SPA view is never resized or hidden: the app looks exactly as it does
//     without a pane, and the pane floats over the tab's body only;
//   * GTK would size an overlay child by its natural size (a `WebKitWebView`'s is
//     huge — ~1398px measured), so the placement is an explicit allocation in the
//     overlay's `size-allocate` handler, which runs after the default one. That
//     also makes window resizes and sidebar drags free: the SPA reports a new
//     rect and the next allocation uses it;
//   * the pane view gets **no bindings** — it renders third-party content, and
//     the invariant from browser_bridge.zig applies to it exactly as it does to
//     the separate window;
//   * the injected chrome bar (`browser_chrome.js`) is the pane's address bar /
//     ← / → / ↻ — already shipped and jsdom-tested, so nothing new navigates.
//
// PLATFORM: Linux/GTK3 only for now. Off Linux `supported` is false, nothing is
// installed, and the SPA falls back to the window mode (which is why that mode is
// kept, invisibly).

const std = @import("std");
const builtin = @import("builtin");
const cli = @import("cli.zig");
const webview_lib = @import("webview_lib.zig");
const browser_bridge = @import("browser_bridge.zig");

const Webview = webview_lib.Webview;

/// True where the pane can be built at all. Linux-first (GTK3).
pub const supported = builtin.os.tag == .linux;

/// `webview_native_handle_kind_t` (vendor/webview/webview.h:143-153).
const HANDLE_UI_WINDOW: c_int = 0;
const HANDLE_UI_WIDGET: c_int = 1;
const HANDLE_BROWSER_CONTROLLER: c_int = 2;

/// Mirror of GTK3's enum values this file uses, named rather than sprinkled.
const GTK_POLICY_NEVER: c_int = 0;
const FALSE: c_int = 0;
const TRUE: c_int = 1;
/// `GConnectFlags.G_CONNECT_AFTER` — run our handler after the default one.
const G_CONNECT_AFTER: c_int = 1;

// ---------------------------------------------------------------------------
// GTK3 C API. Declared, not linked specially: build.zig already links gtk-3 +
// webkit2gtk-4.1 for the desktop module. webview_lib.zig's "no GTK code in Zig"
// note was about the *window* path — the pane is the one place the shell needs
// widget-level layout, and it is comptime-gated to Linux.
// ---------------------------------------------------------------------------

const GtkWidget = opaque {};

/// `GtkAllocation` — x, y, width, height in logical pixels (which is what
/// WebKitGTK's CSS pixels are, so the SPA's `getBoundingClientRect` maps 1:1).
pub const Rect = extern struct {
    x: c_int = 0,
    y: c_int = 0,
    width: c_int = 0,
    height: c_int = 0,
};

extern "c" fn gtk_overlay_new() *GtkWidget;
extern "c" fn gtk_overlay_add_overlay(overlay: *GtkWidget, widget: *GtkWidget) void;
extern "c" fn gtk_scrolled_window_new(h: ?*anyopaque, v: ?*anyopaque) *GtkWidget;
extern "c" fn gtk_scrolled_window_set_policy(widget: *GtkWidget, h: c_int, v: c_int) void;
extern "c" fn gtk_container_add(container: *GtkWidget, widget: *GtkWidget) void;
extern "c" fn gtk_container_remove(container: *GtkWidget, widget: *GtkWidget) void;
extern "c" fn gtk_widget_show(widget: *GtkWidget) void;
extern "c" fn gtk_widget_hide(widget: *GtkWidget) void;
extern "c" fn gtk_widget_get_visible(widget: *GtkWidget) c_int;
extern "c" fn gtk_widget_set_size_request(widget: *GtkWidget, width: c_int, height: c_int) void;
extern "c" fn gtk_widget_size_allocate(widget: *GtkWidget, allocation: *Rect) void;
extern "c" fn gtk_widget_queue_resize(widget: *GtkWidget) void;
/// `WEBVIEW_NATIVE_HANDLE_KIND_BROWSER_CONTROLLER` — the WebKitWebView itself,
/// which is how the shell can see what the pane actually loaded.
extern "c" fn webkit_web_view_get_uri(view: *anyopaque) ?[*:0]const u8;
extern "c" fn g_signal_connect_data(
    instance: *GtkWidget,
    detailed_signal: [*:0]const u8,
    handler: *const fn (*GtkWidget, *Rect, ?*anyopaque) callconv(.c) void,
    data: ?*anyopaque,
    destroy_data: ?*const fn (?*anyopaque, ?*anyopaque) callconv(.c) void,
    flags: c_int,
) c_ulong;

/// One pane per app window (plan §3): the SPA shows it for the active browser
/// tab, positions it at that tab body's rect, and hides it otherwise. Hide, never
/// destroy — switching tabs must not pay a WebKit cold start, and the page keeps
/// its state.
pub const Pane = struct {
    /// The pane view; created lazily on the first `show`.
    view: ?*Webview = null,
    overlay: ?*GtkWidget = null,
    /// The scrolled window the pane view lives in — the widget we place.
    host: ?*GtkWidget = null,
    visible: bool = false,
    /// Where the SPA says the browser tab's body is, in window coordinates.
    rect: Rect = .{},
    /// Hash of the loaded URL, so re-activating a tab does not reload the page.
    url_hash: u64 = 0,

    /// Build the overlay. Called once, before `webview_run`.
    pub fn install(self: *Pane, app: *Webview) void {
        if (!supported) return;
        const win = webview_lib.webview_get_native_handle(app, HANDLE_UI_WINDOW) orelse return;
        const spa_view = webview_lib.webview_get_native_handle(app, HANDLE_UI_WIDGET) orelse return;
        const win_widget: *GtkWidget = @ptrCast(win);
        const spa_widget: *GtkWidget = @ptrCast(spa_view);

        // The window's single child leaves it; the overlay takes its place and
        // the SPA view becomes the overlay's main child — same geometry as before,
        // so the app renders exactly as it did without a pane.
        gtk_container_remove(win_widget, spa_widget);
        const overlay = gtk_overlay_new();
        gtk_container_add(win_widget, overlay);
        gtk_container_add(overlay, spa_widget);

        const host = gtk_scrolled_window_new(null, null);
        gtk_scrolled_window_set_policy(host, GTK_POLICY_NEVER, GTK_POLICY_NEVER);
        gtk_overlay_add_overlay(overlay, host);

        // Placed by hand: an overlay child would otherwise be sized by its natural
        // size, which for a webview is enormous.
        _ = g_signal_connect_data(
            overlay,
            "size-allocate",
            onSizeAllocate,
            @ptrCast(self),
            null,
            G_CONNECT_AFTER,
        );

        gtk_widget_show(overlay);
        gtk_widget_show(spa_widget);
        // host stays hidden until the first show().

        self.overlay = overlay;
        self.host = host;
        std.log.info("browser pane: overlay installed", .{});
    }

    /// Show the pane and navigate it (only when the URL changed). `rect` is the
    /// tab body the SPA reports; it may be null when the SPA's layout has not
    /// settled yet — then the pane is shown and waits for a `nalarBrowserPaneRect`
    /// (never a refusal: a rect-less show used to be rejected outright, which
    /// left the pane invisible with no error — the bug the human hit).
    pub fn show(self: *Pane, url: []const u8, rect: ?Rect) bool {
        if (!supported) return false;
        const host = self.host orelse return false;

        if (self.view == null) {
            // Created INTO our host: the vendored ctor's container-safe parent
            // path puts the new view in the scrolled window (see the header).
            const created = webview_lib.webview_create(0, host) orelse return false;
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

        if (rect) |value| self.setRect(value);
        gtk_widget_show(host);
        self.visible = true;
        return true;
    }

    /// Move/resize the pane (window resize, sidebar drag, tab body changes).
    pub fn setRect(self: *Pane, rect: Rect) void {
        if (!supported) return;
        self.rect = rect;
        if (self.overlay) |overlay| gtk_widget_queue_resize(overlay);
    }

    /// Hide the pane (the view and the page survive). Safe before any show.
    /// This is the "left the tab" path — state is kept on purpose.
    pub fn hide(self: *Pane) void {
        if (!supported) return;
        if (self.host) |host| gtk_widget_hide(host);
        self.visible = false;
    }

    /// Destroy the pane view so **nothing keeps running**. Used when the browser
    /// tab is *closed* (leaving it is `hide`): WebKit would otherwise keep the
    /// page's web process alive in the background — which is exactly what the
    /// human reported after pressing the tab's close button.
    pub fn close(self: *Pane) bool {
        if (!supported) return false;
        if (self.view) |view| {
            // The vendored destructor removes the widget from the host (our
            // container-safe helper) and releases the webview.
            _ = webview_lib.webview_destroy(view);
            self.view = null;
        }
        if (self.host) |host| gtk_widget_hide(host);
        self.visible = false;
        self.url_hash = 0;
        std.log.info("browser pane: view destroyed (nothing running)", .{});
        return true;
    }

    /// Read the live widget state, not our own flag: the GTK call is the truth.
    pub fn isVisible(self: *const Pane) bool {
        if (!supported) return false;
        const host = self.host orelse return false;
        return gtk_widget_get_visible(host) != 0;
    }

    /// Length of the URL the pane has actually loaded (0 when there is no view).
    /// The live probe uses it to prove the page really rendered; a full
    /// escaped URI would be the follow-up "live URL in the tab" (§10.4).
    pub fn uriLen(self: *const Pane) usize {
        if (!supported) return 0;
        const view = self.view orelse return 0;
        const raw = webview_lib.webview_get_native_handle(view, HANDLE_BROWSER_CONTROLLER) orelse return 0;
        const uri = webkit_web_view_get_uri(raw) orelse return 0;
        return std.mem.span(uri).len;
    }
};

/// JSON array → strings, accepting numbers as well as strings. The SPA sends
/// numbers for the rect (natural in JS); a hand-written probe may send strings.
/// `browser_bridge.parseParams` is string-only, hence this sibling.
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

/// Runs after GtkOverlay's own allocation (G_CONNECT_AFTER) and overrides the
/// pane host's geometry with the rect the SPA reported.
fn onSizeAllocate(widget: *GtkWidget, alloc: *Rect, data: ?*anyopaque) callconv(.c) void {
    _ = widget; // the handler is on the overlay itself; the rect is what matters
    const self: *Pane = @ptrCast(@alignCast(data orelse return));
    const host = self.host orelse return;
    // Clamp to the window so a stale/large rect can never cover the whole app.
    var rect = self.rect;
    if (rect.x < 0) rect.x = 0;
    if (rect.y < 0) rect.y = 0;
    if (rect.width < 0) rect.width = 0;
    if (rect.height < 0) rect.height = 0;
    if (rect.x + rect.width > alloc.width) rect.width = @max(0, alloc.width - rect.x);
    if (rect.y + rect.height > alloc.height) rect.height = @max(0, alloc.height - rect.y);
    if (rect.width == 0 or rect.height == 0) {
        // No usable numbers (the SPA has not measured the body yet, or the element
        // collapsed). Allocate NOTHING: returning early would leave the host with
        // GtkOverlay's default full-window allocation, which covers the whole app
        // — tab strip included — so the user cannot switch back to another tab.
        var hidden = Rect{ .x = 0, .y = 0, .width = 0, .height = 0 };
        gtk_widget_size_allocate(host, &hidden);
        return;
    }
    gtk_widget_size_allocate(host, &rect);
}

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
/// line is what makes "the pane did not appear" diagnosable from the app's own
/// output — the missing log is itself the answer.
pub fn handle(pane: *Pane, method: Method, req: []const u8, out: []u8) [:0]const u8 {
    const result = handleInner(pane, method, req, out);
    std.log.info(
        "browser pane: {s} rect=[{d},{d},{d},{d}] reply={s}",
        .{
            @tagName(method),
            pane.rect.x,
            pane.rect.y,
            pane.rect.width,
            pane.rect.height,
            result,
        },
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
        .status => return browser_bridge.reply(
            out,
            "{{\"supported\":{s},\"visible\":{s},\"uri_len\":{d},\"rect\":[{d},{d},{d},{d}]}}",
            .{
                boolLit(supported),
                boolLit(pane.isVisible()),
                pane.uriLen(),
                pane.rect.x,
                pane.rect.y,
                pane.rect.width,
                pane.rect.height,
            },
        ),
        .rect => {
            const rect = rectFromParams(params[0..count]) orelse
                return browser_bridge.reply(out, "{{\"ok\":false,\"error\":\"rect expects (x, y, width, height)\"}}", .{});
            pane.setRect(rect);
            return okReply(pane, out);
        },
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
            // The rect is optional: the SPA may not have laid the tab body out
            // yet. 4 numbers = the rect; anything else = "wait for a Rect call".
            var rect: ?Rect = null;
            if (count >= 6) {
                rect = rectFromParams(params[2..count]) orelse
                    return browser_bridge.reply(out, "{{\"ok\":false,\"error\":\"bad rect\"}}", .{});
            }
            if (!pane.show(url, rect)) {
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
        "{{\"ok\":true,\"visible\":{s},\"rect\":[{d},{d},{d},{d}]}}",
        .{
            boolLit(pane.isVisible()),
            pane.rect.x,
            pane.rect.y,
            pane.rect.width,
            pane.rect.height,
        },
    );
}

/// Four integers, accepted as JSON numbers or numeric strings (the SPA sends
/// numbers; strings keep a hand-written probe easy).
fn rectFromParams(params: [][]const u8) ?Rect {
    if (params.len < 4) return null;
    var values: [4]c_int = undefined;
    for (params[0..4], 0..) |raw, index| {
        const trimmed = std.mem.trim(u8, raw, " ");
        const parsed = std.fmt.parseInt(i32, trimmed, 10) catch return null;
        values[index] = parsed;
    }
    return .{ .x = values[0], .y = values[1], .width = values[2], .height = values[3] };
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
    const result = handle(&pane, .show, "[\"tab_1\",\"javascript:alert(1)\",\"0\",\"0\",\"100\",\"100\"]", &out);
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
        "[\"bad id!\",\"https://example.com\",\"0\",\"0\",\"10\",\"10\"]",
        "[\"tab_1\",\"https://example.com\",\"0\",\"0\",\"10\"]", // half a rect
    }) |req| {
        const result = handle(&pane, .show, req, &out);
        try testing.expect(std.mem.indexOf(u8, result, "\"ok\":false") != null);
    }
    try testing.expect(pane.view == null);
}

test "browser pane: a show without a rect is not refused for its shape" {
    // The SPA may ask before its layout has settled. That request must reach the
    // widget layer (it used to be rejected outright, which left the pane
    // invisible with no error — the bug the human hit); creating the view needs a
    // display, so here it reports the pane as unavailable instead.
    var pane = Pane{};
    var out: [browser_bridge.REPLY_BUF]u8 = undefined;
    const result = handle(&pane, .show, "[\"tab_1\",\"https://example.com\"]", &out);
    try testing.expect(std.mem.indexOf(u8, result, "expects (tabId, url") == null);
    try testing.expect(std.mem.indexOf(u8, result, "bad rect") == null);
    try testing.expect(std.mem.indexOf(u8, result, "only http(s)") == null);
}

test "browser pane: rect-only updates are validated and stored" {
    var pane = Pane{};
    var out: [browser_bridge.REPLY_BUF]u8 = undefined;
    const bad = handle(&pane, .rect, "[\"1\",\"2\"]", &out);
    try testing.expect(std.mem.indexOf(u8, bad, "\"ok\":false") != null);

    const good = handle(&pane, .rect, "[\"120\",\"36\",\"900\",\"600\"]", &out);
    try testing.expect(std.mem.indexOf(u8, good, "\"ok\":true") != null);
    try testing.expectEqual(@as(c_int, 120), pane.rect.x);
    try testing.expectEqual(@as(c_int, 36), pane.rect.y);
    try testing.expectEqual(@as(c_int, 900), pane.rect.width);
    try testing.expectEqual(@as(c_int, 600), pane.rect.height);
}

test "browser pane: hide and status are safe before anything was shown" {
    var pane = Pane{};
    var out: [browser_bridge.REPLY_BUF]u8 = undefined;
    const hidden = handle(&pane, .hide, "[]", &out);
    try testing.expect(std.mem.indexOf(u8, hidden, "\"ok\":true") != null);
    try testing.expect(std.mem.indexOf(u8, hidden, "\"visible\":false") != null);
    const status = handle(&pane, .status, "[]", &out);
    try testing.expect(std.mem.indexOf(u8, status, "\"visible\":false") != null);
    try testing.expect(std.mem.indexOf(u8, status, "\"supported\":") != null);
    try testing.expect(std.mem.indexOf(u8, status, "\"rect\":[") != null);
}

test "browser pane: close destroys the view state so nothing keeps running" {
    var pane = Pane{};
    var out: [browser_bridge.REPLY_BUF]u8 = undefined;
    // Close is safe before anything was shown …
    const first = handle(&pane, .close, "[]", &out);
    try testing.expect(std.mem.indexOf(u8, first, "\"ok\":true") != null);
    try testing.expect(std.mem.indexOf(u8, first, "\"visible\":false") != null);
    // … and it clears the remembered URL, so a later show navigates again.
    pane.url_hash = 0xdeadbeef;
    _ = handle(&pane, .close, "[]", &out);
    try testing.expectEqual(@as(u64, 0), pane.url_hash);
    const status = handle(&pane, .status, "[]", &out);
    try testing.expect(std.mem.indexOf(u8, status, "\"uri_len\":0") != null);
}

test "browser pane: the platform gate is explicit" {
    if (builtin.os.tag == .linux) {
        try testing.expect(supported);
    } else {
        try testing.expect(!supported);
    }
}

test "browser pane: the four binding names are flat" {
    // Same rule as the process bridge: the vendored glue writes `window[name]`
    // verbatim, so a dotted name would be unreachable — locked here too.
    const names = [_][]const u8{
        "nalarBrowserPaneShow",
        "nalarBrowserPaneRect",
        "nalarBrowserPaneHide",
        "nalarBrowserPaneStatus",
    };
    for (names) |name| {
        try testing.expect(std.mem.indexOfScalar(u8, name, '.') == null);
    }
}
