//! Data model for the `design_page_elements` entity table.
//!
//! One row per positioned element on a design page (rectangle,
//! ellipse, text, image, frame, or group). The HTML body lives on
//! disk at `file_path`; this row is the metadata side of that
//! contract.
//!
//! Schema: Migration 056 (`design_page_elements` created) + 057
//! (v6 element properties) + Migration 057 (add `parent_id` for
//! grouped layers).

const std = @import("std");

pub const EntityId = []u8;

id: EntityId,
page_id: []u8,
name: []u8,
/// Absolute or workspace-relative path to the HTML body file on
/// disk. Empty slice for elements created before the file model
/// migration.
file_path: []u8 = &.{},
x: i64 = 0,
y: i64 = 0,
width: i64 = 375,
height: i64 = 667,
/// Stack order within a page. Higher = on top. The kanban-model
/// convention puts containers BELOW children (`min_z - 1`), so a
/// group painted with `fill: #181616` does NOT occlude its kids.
z_index: i64 = 0,
/// Order within the (z_index, position) sort key.
position: i64 = 0,
created_at: []u8,
updated_at: []u8,
/// One of `"rectangle"` | `"ellipse"` | `"text"` | `"image"` |
/// `"frame"` | `"group"` | `"unknown"`. The DB column has no CHECK
/// constraint.
elem_type: []u8,
rotation: f64 = 0.0,
/// CSS color string (`#rrggbb`, `rgba(...)`, etc.). Empty slice
/// is "no fill" (the canvas background shows through).
fill: []u8 = &.{},
stroke: []u8 = &.{},
stroke_width: i64 = 0,
/// Only meaningful for `rectangle` elements.
corner_radius: i64 = 0,
opacity: f64 = 1.0,
text_content: []u8 = &.{},
/// JSON-encoded text-style object (font, weight, size, etc.).
text_style: []u8 = &.{},
image_url: []u8 = &.{},
/// Migration 057 — FK to a `group` or `frame` on the same page
/// (NULL for top-level).
parent_id: ?[]u8 = null,

const Self = @This();

pub const InitArgs = struct {
    id: []const u8,
    page_id: []const u8,
    name: []const u8,
    file_path: []const u8 = "",
    x: i64 = 0,
    y: i64 = 0,
    width: i64 = 375,
    height: i64 = 667,
    z_index: i64 = 0,
    position: i64 = 0,
    created_at: []const u8 = "",
    updated_at: []const u8 = "",
    elem_type: []const u8,
    rotation: f64 = 0.0,
    fill: []const u8 = "",
    stroke: []const u8 = "",
    stroke_width: i64 = 0,
    corner_radius: i64 = 0,
    opacity: f64 = 1.0,
    text_content: []const u8 = "",
    text_style: []const u8 = "",
    image_url: []const u8 = "",
    parent_id: ?[]const u8 = null,
};

pub fn init(allocator: std.mem.Allocator, args: InitArgs) !Self {
    return .{
        .id = try allocator.dupe(u8, args.id),
        .page_id = try allocator.dupe(u8, args.page_id),
        .name = try allocator.dupe(u8, args.name),
        .file_path = try allocator.dupe(u8, args.file_path),
        .x = args.x,
        .y = args.y,
        .width = args.width,
        .height = args.height,
        .z_index = args.z_index,
        .position = args.position,
        .created_at = try allocator.dupe(u8, args.created_at),
        .updated_at = try allocator.dupe(u8, args.updated_at),
        .elem_type = try allocator.dupe(u8, args.elem_type),
        .rotation = args.rotation,
        .fill = try allocator.dupe(u8, args.fill),
        .stroke = try allocator.dupe(u8, args.stroke),
        .stroke_width = args.stroke_width,
        .corner_radius = args.corner_radius,
        .opacity = args.opacity,
        .text_content = try allocator.dupe(u8, args.text_content),
        .text_style = try allocator.dupe(u8, args.text_style),
        .image_url = try allocator.dupe(u8, args.image_url),
        .parent_id = if (args.parent_id) |p| try allocator.dupe(u8, p) else null,
    };
}

pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
    allocator.free(self.id);
    allocator.free(self.page_id);
    allocator.free(self.name);
    if (self.file_path.len > 0) allocator.free(self.file_path);
    allocator.free(self.created_at);
    allocator.free(self.updated_at);
    allocator.free(self.elem_type);
    if (self.fill.len > 0) allocator.free(self.fill);
    if (self.stroke.len > 0) allocator.free(self.stroke);
    if (self.text_content.len > 0) allocator.free(self.text_content);
    if (self.text_style.len > 0) allocator.free(self.text_style);
    if (self.image_url.len > 0) allocator.free(self.image_url);
    if (self.parent_id) |p| allocator.free(p);
}

pub fn clone(self: *const Self, allocator: std.mem.Allocator) !Self {
    return .init(allocator, .{
        .id = self.id,
        .page_id = self.page_id,
        .name = self.name,
        .file_path = self.file_path,
        .x = self.x,
        .y = self.y,
        .width = self.width,
        .height = self.height,
        .z_index = self.z_index,
        .position = self.position,
        .created_at = self.created_at,
        .updated_at = self.updated_at,
        .elem_type = self.elem_type,
        .rotation = self.rotation,
        .fill = self.fill,
        .stroke = self.stroke,
        .stroke_width = self.stroke_width,
        .corner_radius = self.corner_radius,
        .opacity = self.opacity,
        .text_content = self.text_content,
        .text_style = self.text_style,
        .image_url = self.image_url,
        .parent_id = if (self.parent_id) |p| p else null,
    });
}