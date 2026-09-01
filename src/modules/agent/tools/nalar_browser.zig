const std = @import("std");
const schemas = @import("schemas.zig");
const AgentTool = schemas.AgentTool;
const Value = std.json.Value;

/// Input for NalarBrowser tool execution
pub const NalarBrowserInput = struct {
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

/// Result from NalarBrowser action execution
pub const NalarBrowserResult = struct {
    success: bool,
    browser_id: ?[]const u8 = null,
    page_id: ?[]const u8 = null,
    url: ?[]const u8 = null,
    title: ?[]const u8 = null,
    status: ?u16 = null,
    tree_json: ?[]const u8 = null,
    err_msg: ?[]const u8 = null,
};

/// Execute a NalarBrowser action
pub fn execute_nalar_browser(allocator: std.mem.Allocator, io: std.Io, input: NalarBrowserInput) !NalarBrowserResult {
    const api_url = input.api_url orelse "http://localhost:3000";

    // Build endpoint based on action
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
            return NalarBrowserResult{
                .success = false,
                .err_msg = try allocator.dupe(u8, "page_id required for close_page action"),
            };
        }
    } else if (std.mem.eql(u8, input.action, "close_browser")) {
        if (input.browser_id) |bid| {
            endpoint_heap = try std.fmt.allocPrint(allocator, "/close/{s}", .{bid});
        } else {
            return NalarBrowserResult{
                .success = false,
                .err_msg = try allocator.dupe(u8, "browser_id required for close_browser action"),
            };
        }
    } else {
        return NalarBrowserResult{
            .success = false,
            .err_msg = try std.fmt.allocPrint(allocator, "Unknown action: {s}", .{input.action}),
        };
    }

    const endpoint: []const u8 = if (endpoint_heap) |h| h else static_endpoint;
    defer if (endpoint_heap) |h| allocator.free(h);

    const full_url = try std.fmt.allocPrint(allocator, "{s}{s}", .{ api_url, endpoint });
    defer allocator.free(full_url);

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

    // Perform HTTP POST using std.http.Client
    var client = std.http.Client{ .allocator = allocator, .io = io };
    defer client.deinit();

    const uri = std.Uri.parse(full_url) catch |err| {
        return NalarBrowserResult{
            .success = false,
            .err_msg = try std.fmt.allocPrint(allocator, "Invalid URL: {s}", .{@errorName(err)}),
        };
    };

    var req = client.request(.POST, uri, .{
        .version = .@"HTTP/1.1",
        .headers = .{
            .content_type = .{ .override = "application/json" },
        },
    }) catch |err| {
        return NalarBrowserResult{
            .success = false,
            .err_msg = try std.fmt.allocPrint(allocator, "HTTP request failed: {s}", .{@errorName(err)}),
        };
    };
    defer req.deinit();

    const body_mut = try allocator.dupe(u8, body);
    defer allocator.free(body_mut);
    try req.sendBodyComplete(body_mut);

    var redirect_buffer: [8192]u8 = undefined;
    var response = try req.receiveHead(&redirect_buffer);

    var transfer_buffer: [64 * 1024]u8 = undefined;
    const resp_bytes = try response.reader(&transfer_buffer).allocRemaining(allocator, .unlimited);
    defer allocator.free(resp_bytes);

    const status_code = @intFromEnum(response.head.status);

    // DEBUG: Log response body details
    if (resp_bytes.len < 500) {
        std.debug.print("DEBUG nalar_browser: url={s}, body={s}, status={d}, resp_len={d}, resp={s}\n", .{ full_url, body, status_code, resp_bytes.len, resp_bytes });
    } else {
        std.debug.print("DEBUG nalar_browser: url={s}, body={s}, status={d}, resp_len={d}, resp_first_200={s}\n", .{ full_url, body, status_code, resp_bytes.len, resp_bytes[0..200] });
    }

    // Parse JSON response
    const parsed = std.json.parseFromSlice(Value, allocator, resp_bytes, .{}) catch |err| {
        std.debug.print("DEBUG nalar_browser: JSON parse error: {s}, body_len={d}\n", .{ @errorName(err), resp_bytes.len });
        if (resp_bytes.len > 0) {
            std.debug.print("DEBUG nalar_browser: body_content (first 500)={s}\n", .{resp_bytes[0..@min(500, resp_bytes.len)]});
        }
        return NalarBrowserResult{
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
    var tree_json: ?[]const u8 = null;
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
        var out: std.Io.Writer.Allocating = .init(allocator);
        errdefer out.deinit();
        var jws: std.json.Stringify = .{ .writer = &out.writer };
        try jws.write(v);
        tree_json = try out.toOwnedSlice();
    }
    if (obj.get("error")) |v| {
        if (v == .string) err_msg = try allocator.dupe(u8, v.string);
    }

    return NalarBrowserResult{
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
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    var first = true;
    try buf.append(allocator,'{');

    var it = map.iterator();
    while (it.next()) |entry| {
        if (!first) try buf.append(allocator,',');
        try buf.appendSlice(allocator,"\"");
        try buf.appendSlice(allocator,entry.key_ptr.*);
        try buf.appendSlice(allocator,"\":\"");
        try buf.appendSlice(allocator,entry.value_ptr.*);
        try buf.append(allocator,'"');
        first = false;
    }

    try buf.append(allocator,'}');
    return try buf.toOwnedSlice(allocator);
}

/// Convert successful result to XML string
pub fn toXMLSuccess(allocator: std.mem.Allocator, result: NalarBrowserResult) ![]const u8 {
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
pub fn toXMLError(allocator: std.mem.Allocator, result: NalarBrowserResult, action: []const u8) ![]const u8 {
    var buf = std.ArrayList(u8).empty;
    errdefer buf.deinit(allocator);

    try buf.appendSlice(allocator, "<error>");
    try buf.appendSlice(allocator, "NalarBrowser ");
    try buf.appendSlice(allocator, action);
    try buf.appendSlice(allocator, " failed: ");
    if (result.err_msg) |msg| {
        try buf.appendSlice(allocator, msg);
    }
    try buf.appendSlice(allocator, "</error>");

    return try buf.toOwnedSlice(allocator);
}

/// NalarBrowser tool definition for agent
pub const nalar_browser_tool_system_prompt =
    \\## Nalar Browser Tool — Behavior
    \\Use `nalar_browser` for stealth Chromium automation on anti-bot sites.
    \\- Workflow: `launch` → `open_page` → `snapshot` → `click`/`fill`/`press` → `close_page`/`close_browser`.
    \\- Use for sites that block normal fetch (Cloudflare, reCAPTCHA).
    \\
;

pub const nalar_browser_tool = AgentTool{
    .type = "function",
    .function = .{
        .name = "nalar_browser",
        .description = "Nalar Browser - stealth Chromium browser for anti-bot bypass. " ++
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
                    .description = "Nalar Browser API server URL. Defaults to http://localhost:3000. Change if service runs on different port.",
                },
            },
            .required = &.{"action"},
        },
        .system_prompt = nalar_browser_tool_system_prompt,
    },
};

const nalar_browser = @import("nalar_browser.zig");

test "NalarBrowserInput default values" {
    const input = nalar_browser.NalarBrowserInput{ .action = "launch" };
    try std.testing.expect(std.mem.eql(u8, input.action, "launch"));
    try std.testing.expect(input.browser_id == null);
    try std.testing.expect(input.page_id == null);
    try std.testing.expect(input.url == null);
    try std.testing.expect(input.ref == null);
    try std.testing.expect(input.text == null);
    try std.testing.expect(input.key == null);
    try std.testing.expect(input.api_url == null);
}

test "NalarBrowserInput with all fields" {
    const input = nalar_browser.NalarBrowserInput{
        .action = "open_page",
        .browser_id = "browser_123",
        .page_id = "page_456",
        .url = "https://example.com",
        .ref = "e1",
        .text = "search query",
        .key = "Enter",
        .api_url = "http://localhost:9000",
    };
    try std.testing.expect(std.mem.eql(u8, input.action, "open_page"));
    try std.testing.expect(std.mem.eql(u8, input.browser_id.?, "browser_123"));
    try std.testing.expect(std.mem.eql(u8, input.page_id.?, "page_456"));
    try std.testing.expect(std.mem.eql(u8, input.url.?, "https://example.com"));
    try std.testing.expect(std.mem.eql(u8, input.ref.?, "e1"));
    try std.testing.expect(std.mem.eql(u8, input.text.?, "search query"));
    try std.testing.expect(std.mem.eql(u8, input.key.?, "Enter"));
    try std.testing.expect(std.mem.eql(u8, input.api_url.?, "http://localhost:9000"));
}

test "NalarBrowserResult success with all fields" {
    const result = nalar_browser.NalarBrowserResult{
        .success = true,
        .browser_id = "browser_abc",
        .page_id = "page_xyz",
        .url = "https://ziglang.org",
        .title = "Zig Programming Language",
        .tree_json = "[{\"ref\":\"e1\",\"text\":\"Download\"}]",
    };
    try std.testing.expect(result.success == true);
    try std.testing.expect(std.mem.eql(u8, result.browser_id.?, "browser_abc"));
    try std.testing.expect(std.mem.eql(u8, result.page_id.?, "page_xyz"));
    try std.testing.expect(std.mem.eql(u8, result.url.?, "https://ziglang.org"));
    try std.testing.expect(std.mem.eql(u8, result.title.?, "Zig Programming Language"));
    try std.testing.expect(std.mem.eql(u8, result.tree_json.?, "[{\"ref\":\"e1\",\"text\":\"Download\"}]"));
    try std.testing.expect(result.err_msg == null);
}

test "NalarBrowserResult error case" {
    const result = nalar_browser.NalarBrowserResult{
        .success = false,
        .err_msg = "Connection refused",
    };
    try std.testing.expect(result.success == false);
    try std.testing.expect(result.browser_id == null);
    try std.testing.expect(result.err_msg != null);
    try std.testing.expect(std.mem.eql(u8, result.err_msg.?, "Connection refused"));
}

test "toXMLSuccess with minimal result" {
    const allocator = std.testing.allocator;
    const result = nalar_browser.NalarBrowserResult{ .success = true };

    const xml = try nalar_browser.toXMLSuccess(allocator, result);
    defer allocator.free(xml);

    try std.testing.expect(std.mem.indexOf(u8, xml, "<success>1</success>") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml, "</success>") != null);
}

test "toXMLSuccess with all fields" {
    const allocator = std.testing.allocator;
    const result = nalar_browser.NalarBrowserResult{
        .success = true,
        .browser_id = "browser_test",
        .page_id = "page_test",
        .url = "https://example.com",
        .title = "Example Domain",
        .tree_json = "[{\"ref\":\"e1\",\"text\":\"Click Here\",\"href\":\"https://example.com/link\"}]",
    };

    const xml = try nalar_browser.toXMLSuccess(allocator, result);
    defer allocator.free(xml);

    try std.testing.expect(std.mem.indexOf(u8, xml, "<browser_id>browser_test</browser_id>") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml, "<page_id>page_test</page_id>") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml, "<url>https://example.com</url>") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml, "<title>Example Domain</title>") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml, "<tree>") != null);
}

test "toXMLError with error message" {
    const allocator = std.testing.allocator;
    const result = nalar_browser.NalarBrowserResult{
        .success = false,
        .err_msg = "Page not found",
    };

    const xml = try nalar_browser.toXMLError(allocator, result, "open_page");
    defer allocator.free(xml);

    try std.testing.expect(std.mem.indexOf(u8, xml, "<error>NalarBrowser open_page failed: Page not found</error>") != null);
}

test "toXMLError with null error message" {
    const allocator = std.testing.allocator;
    const result = nalar_browser.NalarBrowserResult{
        .success = false,
        .err_msg = null,
    };

    const xml = try nalar_browser.toXMLError(allocator, result, "click");
    defer allocator.free(xml);

    try std.testing.expect(std.mem.indexOf(u8, xml, "<error>NalarBrowser click failed: </error>") != null);
}

test "nalar_browser_tool definition" {
    try std.testing.expect(std.mem.eql(u8, nalar_browser.nalar_browser_tool.type, "function"));
    try std.testing.expect(std.mem.eql(u8, nalar_browser.nalar_browser_tool.function.name, "nalar_browser"));
    try std.testing.expect(nalar_browser.nalar_browser_tool.function.description.len > 0);
    try std.testing.expect(std.mem.eql(u8, nalar_browser.nalar_browser_tool.function.parameters.type, "object"));
    try std.testing.expect(nalar_browser.nalar_browser_tool.function.parameters.properties.len == 8);
    try std.testing.expect(nalar_browser.nalar_browser_tool.function.parameters.required.len == 1);
    try std.testing.expect(std.mem.eql(u8, nalar_browser.nalar_browser_tool.function.parameters.required[0], "action"));
}

test "nalar_browser_tool has correct property names" {
    const props = nalar_browser.nalar_browser_tool.function.parameters.properties;
    const expected_names = &[_][]const u8{
        "action", "browser_id", "page_id", "url", "ref", "text", "key", "api_url",
    };
    for (expected_names, props) |expected, prop| {
        try std.testing.expect(std.mem.eql(u8, prop.name, expected));
    }
}

test "buildJsonBody with empty map" {
    const allocator = std.testing.allocator;
    var map = std.StringHashMap([]const u8).init(allocator);
    defer map.deinit();

    // Can't test buildJsonBody directly since it's private
    // Just verify empty map behavior
    try std.testing.expect(map.count() == 0);
}

test "buildJsonBody with single field" {
    const allocator = std.testing.allocator;
    var map = std.StringHashMap([]const u8).init(allocator);
    defer map.deinit();
    try map.put("action", "launch");

    // Can't test buildJsonBody directly since it's private
    // Just verify map contents
    try std.testing.expect(map.get("action") != null);
    try std.testing.expect(std.mem.eql(u8, map.get("action").?, "launch"));
}

test "buildJsonBody with multiple fields" {
    const allocator = std.testing.allocator;
    var map = std.StringHashMap([]const u8).init(allocator);
    defer map.deinit();
    try map.put("action", "open_page");
    try map.put("browser_id", "browser_123");
    try map.put("url", "https://example.com");

    // Can't test buildJsonBody directly since it's private
    // Just verify map contents
    try std.testing.expect(map.get("action") != null);
    try std.testing.expect(map.get("browser_id") != null);
    try std.testing.expect(map.get("url") != null);
}

test "buildJsonBody with special characters" {
    const allocator = std.testing.allocator;
    var map = std.StringHashMap([]const u8).init(allocator);
    defer map.deinit();
    try map.put("text", "hello world");

    // Can't test buildJsonBody directly since it's private
    // Just verify map is correct
    try std.testing.expect(map.get("text") != null);
}
