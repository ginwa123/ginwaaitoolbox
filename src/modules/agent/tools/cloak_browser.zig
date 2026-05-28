const std = @import("std");
const nalarcore = @import("nalarcore");
const http_client = nalarcore.http_client;
const schemas = @import("schemas.zig");
const AgentTool = schemas.AgentTool;
const Value = std.json.Value;

/// Input for CloakBrowser tool execution
pub const CloakBrowserInput = struct {
    /// Action to perform: launch, open_page, snapshot, click, fill, press, close_page, close_browser
    action: []const u8,
    /// Browser ID from launch action
    browser_id: ?[]const u8 = null,
    /// Page ID from open_page action
    page_id: ?[]const u8 = null,
    /// URL to open (for open_page action)
    url: ?[]const u8 = null,
    /// Element reference to click (for click action)
    ref: ?[]const u8 = null,
    /// Text to fill (for fill action)
    text: ?[]const u8 = null,
    /// Key to press (for press action)
    key: ?[]const u8 = null,
    /// API URL (defaults to http://localhost:3000)
    api_url: ?[]const u8 = null,
};

/// Result from CloakBrowser action execution
pub const CloakBrowserResult = struct {
    success: bool,
    browser_id: ?[]const u8 = null,
    page_id: ?[]const u8 = null,
    url: ?[]const u8 = null,
    title: ?[]const u8 = null,
    status: ?u16 = null,
    tree_json: ?[]const u8 = null,
    err_msg: ?[]const u8 = null,
};

/// Execute a CloakBrowser action
pub fn execute_cloak_browser(allocator: std.mem.Allocator, io: std.Io, input: CloakBrowserInput) !CloakBrowserResult {
    const api_url = input.api_url orelse "http://localhost:3000";

    var client = http_client.HttpClient.init(allocator, io);
    defer client.deinit();

    // Build endpoint based on action - some are static, some are heap allocated
    var endpoint_heap: ?[]const u8 = null;
    var static_endpoint: []const u8 = undefined;
    
    if (std.mem.eql(u8, input.action, "launch")) {
        static_endpoint = "/launch";
    } else if (std.mem.eql(u8, input.action, "open_page")) {
        static_endpoint = "/page";
    } else if (std.mem.eql(u8, input.action, "snapshot")) {
        static_endpoint = "/snapshot";
    } else if (std.mem.eql(u8, input.action, "click")) {
        static_endpoint = "/click";
    } else if (std.mem.eql(u8, input.action, "fill")) {
        static_endpoint = "/fill";
    } else if (std.mem.eql(u8, input.action, "press")) {
        static_endpoint = "/press";
    } else if (std.mem.eql(u8, input.action, "close_page")) {
        if (input.page_id) |pid| {
            endpoint_heap = try std.fmt.allocPrint(allocator, "/page/close/{s}", .{pid});
        } else {
            return CloakBrowserResult{
                .success = false,
                .err_msg = try allocator.dupe(u8, "page_id required for close_page action"),
            };
        }
    } else if (std.mem.eql(u8, input.action, "close_browser")) {
        if (input.browser_id) |bid| {
            endpoint_heap = try std.fmt.allocPrint(allocator, "/close/{s}", .{bid});
        } else {
            return CloakBrowserResult{
                .success = false,
                .err_msg = try allocator.dupe(u8, "browser_id required for close_browser action"),
            };
        }
    } else {
        return CloakBrowserResult{
            .success = false,
            .err_msg = try std.fmt.allocPrint(allocator, "Unknown action: {s}", .{input.action}),
        };
    }
    
    const endpoint: []const u8 = if (endpoint_heap) |h| h else static_endpoint;

    const url = try std.fmt.allocPrint(allocator, "{s}{s}", .{ api_url, endpoint });
    defer allocator.free(url);
    if (endpoint_heap) |h| allocator.free(h);

    // Build JSON body
    var body_map = std.StringHashMap([]const u8).init(allocator);
    defer body_map.deinit();

    if (input.browser_id) |bid| try body_map.put("browser_id", bid);
    if (input.page_id) |pid| try body_map.put("page_id", pid);
    if (input.url) |u| try body_map.put("url", u);
    if (input.ref) |r| try body_map.put("ref", r);
    if (input.text) |t| try body_map.put("text", t);
    if (input.key) |k| try body_map.put("key", k);

    const body = try buildJsonBody(allocator, &body_map);
    defer allocator.free(body);

    const result = client.post(url, body, null) catch |err| {
        return CloakBrowserResult{
            .success = false,
            .err_msg = try std.fmt.allocPrint(allocator, "HTTP request failed: {s}", .{@errorName(err)}),
        };
    };
    defer allocator.free(result.body);

    // Parse JSON response
    const parsed = std.json.parseFromSlice(Value, allocator, result.body, .{}) catch |err| {
        return CloakBrowserResult{
            .success = false,
            .err_msg = try std.fmt.allocPrint(allocator, "JSON parse failed: {s}", .{@errorName(err)}),
        };
    };
    defer parsed.deinit();

    const obj = parsed.value.object;

    const success = obj.get("success").?.bool;
    var browser_id: ?[]const u8 = null;
    var page_id: ?[]const u8 = null;
    var url_out: ?[]const u8 = null;
    var title: ?[]const u8 = null;
    var status: ?u16 = null;
    const tree_json: ?[]const u8 = null;
    var err_msg: ?[]const u8 = null;

    if (obj.get("browser_id")) |v| {
        if (v == .string) browser_id = try allocator.dupe(u8, v.string);
    }
    if (obj.get("page_id")) |v| {
        if (v == .string) page_id = try allocator.dupe(u8, v.string);
    }
    if (obj.get("url")) |v| {
        if (v == .string) url_out = try allocator.dupe(u8, v.string);
    }
    if (obj.get("title")) |v| {
        if (v == .string) title = try allocator.dupe(u8, v.string);
    }
    if (obj.get("status")) |v| {
        if (v == .integer) status = @intCast(v.integer);
    }
    if (obj.get("tree")) |v| {
        // Skip tree serialization for now - dynamic JSON stringify is complex
        // The tree info will come directly from the HTTP response if needed
        _ = v;
    }
    if (obj.get("error")) |v| {
        if (v == .string) err_msg = try allocator.dupe(u8, v.string);
    }

    return CloakBrowserResult{
        .success = success,
        .browser_id = browser_id,
        .page_id = page_id,
        .url = url_out,
        .title = title,
        .status = status,
        .tree_json = tree_json,
        .err_msg = err_msg,
    };
}

/// Helper to build JSON body from string hashmap
fn buildJsonBody(allocator: std.mem.Allocator, map: *std.StringHashMap([]const u8)) ![]const u8 {
    var buf = std.ArrayList(u8).empty;
    var first = true;
    try buf.append(allocator, '{');

    var it = map.iterator();
    while (it.next()) |entry| {
        if (!first) try buf.append(allocator, ',');
        try buf.appendSlice(allocator, "\"");
        try buf.appendSlice(allocator, entry.key_ptr.*);
        try buf.appendSlice(allocator, "\":\"");
        try buf.appendSlice(allocator, entry.value_ptr.*);
        try buf.append(allocator, '"');
        first = false;
    }

    try buf.append(allocator, '}');
    return try buf.toOwnedSlice(allocator);
}

/// Convert successful result to XML string
pub fn toXMLSuccess(allocator: std.mem.Allocator, result: CloakBrowserResult) ![]const u8 {
    var buf = std.ArrayList(u8).empty;
    errdefer buf.deinit(allocator);

    try buf.appendSlice(allocator, "<success>");
    try buf.append(allocator, if (result.success) '1' else '0');
    try buf.appendSlice(allocator, "</success>");

    if (result.browser_id) |bid| {
        try buf.appendSlice(allocator, "<browser_id>");
        try buf.appendSlice(allocator, bid);
        try buf.appendSlice(allocator, "</browser_id>");
    }

    if (result.page_id) |pid| {
        try buf.appendSlice(allocator, "<page_id>");
        try buf.appendSlice(allocator, pid);
        try buf.appendSlice(allocator, "</page_id>");
    }

    if (result.url) |u| {
        try buf.appendSlice(allocator, "<url>");
        try buf.appendSlice(allocator, u);
        try buf.appendSlice(allocator, "</url>");
    }

    if (result.title) |t| {
        try buf.appendSlice(allocator, "<title>");
        try buf.appendSlice(allocator, t);
        try buf.appendSlice(allocator, "</title>");
    }

    if (result.status) |s| {
        try buf.appendSlice(allocator, "<status>");
        const status_str = try std.fmt.allocPrint(allocator, "{d}", .{s});
        defer allocator.free(status_str);
        try buf.appendSlice(allocator, status_str);
        try buf.appendSlice(allocator, "</status>");
    }

    if (result.tree_json) |tree| {
        try buf.appendSlice(allocator, "<tree>");
        try buf.appendSlice(allocator, tree);
        try buf.appendSlice(allocator, "</tree>");
    }

    return try buf.toOwnedSlice(allocator);
}

/// Convert error result to XML string
pub fn toXMLError(allocator: std.mem.Allocator, result: CloakBrowserResult, action: []const u8) ![]const u8 {
    var buf = std.ArrayList(u8).empty;
    errdefer buf.deinit(allocator);

    try buf.appendSlice(allocator, "<error>");
    try buf.appendSlice(allocator, "CloakBrowser ");
    try buf.appendSlice(allocator, action);
    try buf.appendSlice(allocator, " failed: ");
    if (result.err_msg) |msg| {
        try buf.appendSlice(allocator, msg);
    }
    try buf.appendSlice(allocator, "</error>");

    return try buf.toOwnedSlice(allocator);
}

/// CloakBrowser tool definition for agent
pub const cloak_browser_tool = AgentTool{
    .type = "function",
    .function = .{
        .name = "cloak_browser",
        .description = "CloakBrowser - stealth Chromium browser for anti-bot bypass. " ++
            "Use this to browse websites that block automated tools (Cloudflare, reCAPTCHA, etc). " ++
            "Workflow: 1) launch to get browser_id, 2) open_page with url to get page_id+title, " ++
            "3) snapshot to get elements with their refs (e1, e2...), 4) click/fill/press to interact, " ++
            "5) close_page/close_browser to cleanup.",
        .parameters = .{
            .type = "object",
            .properties = &.{
                .{
                    .name = "action",
                    .type = "string",
                    .description = "Action to perform: launch (launches browser, returns browser_id), open_page (opens url, returns page_id+title), snapshot (gets accessibility tree with refs), click (clicks element by ref), fill (fills input with text), press (presses keyboard key), close_page (closes tab), close_browser (terminates browser)",
                },
                .{
                    .name = "browser_id",
                    .type = "string",
                    .description = "Browser ID (from launch action). Required for open_page action.",
                },
                .{
                    .name = "page_id",
                    .type = "string",
                    .description = "Page ID (from open_page action). Used by snapshot, click, fill, press, close_page to identify which tab to operate on.",
                },
                .{
                    .name = "url",
                    .type = "string",
                    .description = "URL to navigate to. Required for open_page action. Example: https://www.google.com",
                },
                .{
                    .name = "ref",
                    .type = "string",
                    .description = "Element reference (e.g., 'e1', 'e2') from accessibility tree snapshot. Use to identify clickable elements, inputs, or buttons.",
                },
                .{
                    .name = "text",
                    .type = "string",
                    .description = "Text to type into an input field. Used with fill action after snapshot shows input refs.",
                },
                .{
                    .name = "key",
                    .type = "string",
                    .description = "Keyboard key to press. Use with press action. Examples: Enter, Escape, ArrowDown, Tab",
                },
                .{
                    .name = "api_url",
                    .type = "string",
                    .description = "CloakBrowser API server URL. Defaults to http://localhost:3000. Change if service runs on different port.",
                },
            },
            .required = &.{"action"},
        },
    },
};
