//! Shared id-shape validation for the `design_*` tools.
//!
//! ## Why this file exists
//!
//! `validateElementIdShape` was copy-pasted into `update_design_element.zig`,
//! `move_design_element.zig` and `set_element_parent.zig`. The only real
//! difference between the three was the tool name embedded in the final
//! error message — and the copies had already drifted in their check order
//! (`update_element` tested `item_` before `page_`, the other two the other
//! way around). That drift is cosmetic today only because an id cannot
//! begin with both prefixes; the day someone adds a third prefix the copies
//! stop agreeing for a real reason.
//!
//! Taking `tool_name` as a parameter collapses the three into one function
//! that cannot drift, and makes the tool name in the message a fact rather
//! than a thing you have to remember to change.
//!
//! ## Ownership
//!
//! Returns `null` when the id is well-formed. Otherwise returns an owned
//! JSON error envelope the caller must `allocator.free`.

const std = @import("std");
const tool_json = @import("helpers").tool_json;
const errorJSON = tool_json.errorJSON;
const errorJSONOwned = tool_json.errorJSONOwned;

/// Validate an `element_id` argument for the design tools that take one.
///
/// `tool_name` is the wire name of the calling tool (`update_element`,
/// `move_design_element`, ...) and is interpolated into the final message so
/// the agent is told which tool rejected the call.
pub fn validateElementIdShape(
    allocator: std.mem.Allocator,
    element_id: []const u8,
    tool_name: []const u8,
) !?[]u8 {
    if (element_id.len == 0) {
        return try errorJSON(allocator, "element_id is required (find it in the `id` field of an element object in a previous set_design_page response)");
    }
    if (std.mem.startsWith(u8, element_id, "item_")) {
        return try errorJSONOwned(allocator, try std.fmt.allocPrint(allocator,
            \\element_id '{s}' looks like an ITEM id (starts with 'item_'). Pass the ELEMENT id instead — find it in the `id` field of an element object in a `set_design_page` response.
        , .{element_id}));
    }
    if (std.mem.startsWith(u8, element_id, "page_")) {
        return try errorJSONOwned(allocator, try std.fmt.allocPrint(allocator,
            \\element_id '{s}' looks like a PAGE id (starts with 'page_'). Pass the ELEMENT id instead — find it in the `id` field of an element object in a `set_design_page` response.
        , .{element_id}));
    }
    if (!std.mem.startsWith(u8, element_id, "elem_")) {
        return try errorJSONOwned(allocator, try std.fmt.allocPrint(allocator,
            \\element_id '{s}' has an unrecognized prefix (expected 'elem_'). {s} expects an element_id from a previous set_design_page response, not a free-form string.
        , .{ element_id, tool_name }));
    }
    return null;
}

const testing = std.testing;

test "a well-formed elem_ id passes" {
    const bad = try validateElementIdShape(testing.allocator, "elem_abc123", "update_element");
    try testing.expect(bad == null);
}

test "an empty id is rejected with the required-message" {
    const out = (try validateElementIdShape(testing.allocator, "", "update_element")).?;
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "element_id is required") != null);
}

test "an item_ id names the item mistake and the set_design_page source" {
    const out = (try validateElementIdShape(testing.allocator, "item_7", "update_element")).?;
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "ITEM id") != null);
    try testing.expect(std.mem.indexOf(u8, out, "set_design_page") != null);
}

test "a page_ id names the page mistake" {
    const out = (try validateElementIdShape(testing.allocator, "page_2", "set_element_parent")).?;
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "PAGE id") != null);
}

test "an unknown prefix reports the CALLING tool, not a hardcoded one" {
    // This is the assertion that pins the parameterization: the three
    // call sites used to each carry their own baked-in name, and there was
    // nothing that would have caught a copy left behind.
    const out = (try validateElementIdShape(testing.allocator, "bogus_1", "move_design_element")).?;
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "move_design_element") != null);
    try testing.expect(std.mem.indexOf(u8, out, "update_element") == null);
}
