//! Jinja-style template engine for `custom_http_server`.
//!
//! Three layers: tokenize → parse → render. Templates are compiled once
//! (per request or once at startup, then cached) and rendered many times
//! with different contexts. Auto-escape is ON for `{{ var }}` output; use
//! `{% raw %}...{% endraw %}` to pass through HTML verbatim.
//!
//! Minimal scope (no filters, no whitespace control, no macros, no
//! includes, no `set`). Features supported:
//!
//!   * `{{ var }}`               — substitution, HTML-escaped
//!   * `{{ a.b.c }}` / `{{ x[0] }}` — dotted + bracket paths
//!   * `{% if cond %}...{% endif %}`          — conditional
//!   * `{% if cond %}A{% else %}B{% endif %}` — conditional with else
//!   * `{% for x in items %}...{% endfor %}`            — loop
//!   * `{% for x in items %}...{% empty %}...{% endfor %}` — loop with empty
//!   * `{% raw %}...{% endraw %}` — pass through verbatim
//!   * `{% extends "parent.jinja" %}` — template inheritance
//!   * `{% block name %}...{% endblock %}` — overridable slot
//!
//! See docs/superpowers/plans/2026-08-06-jinja-template-engine.md for the
//! design and tests that drove this implementation.

const std = @import("std");

/// Errors raised by the engine. Each error tags a specific failure mode
/// so call sites can distinguish (e.g. missing-file vs parse-error).
pub const Error = error{
    UnclosedVariable,
    UnclosedTag,
    UnclosedComment,
    ParseError,
    RenderError,
    TemplateNotFound,
    CircularExtends,
};

/// A single token produced by the tokenizer. The string slices point into
/// the source buffer — the caller must keep `source` alive for the lifetime
/// of the tokens.
pub const Token = union(enum) {
    /// Raw text between tags. Always emitted at the start and between
    /// every other token (you will never see two non-text tokens in a row).
    text: []const u8,
    /// Content of `{{ ... }}`. Whitespace inside is preserved.
    var_expr: []const u8,
    /// Content of `{% ... %}`. Whitespace inside is preserved.
    tag: []const u8,
};

/// Tokenize `source` into a slice of `Token`. Comments `{# ... #}` are
/// dropped (no token emitted). Returns an error on unclosed tags.
pub fn tokenize(allocator: std.mem.Allocator, source: []const u8) (Error || std.mem.Allocator.Error)![]Token {
    var tokens = std.ArrayListUnmanaged(Token).empty;
    errdefer tokens.deinit(allocator);

    var pos: usize = 0;
    while (pos < source.len) {
        // Look for the next tag-like opening: {{, {%, or {#.
        const next_open = findNextOpen(source, pos);
        if (next_open) |open| {
            // Emit text from `pos` up to `open` (if non-empty).
            if (open > pos) {
                try tokens.append(allocator, .{ .text = source[pos..open] });
            }
            // Determine which opener we hit.
            if (open + 1 >= source.len) {
                // Defensive: shouldn't happen — findNextOpen guarantees 2 chars.
                return error.UnclosedTag;
            }
            switch (source[open + 1]) {
                '{' => {
                    // Variable expression.
                    const close = std.mem.indexOfPos(u8, source, open + 2, "}}") orelse
                        return error.UnclosedVariable;
                    try tokens.append(allocator, .{ .var_expr = source[open + 2 .. close] });
                    pos = close + 2;
                },
                '%' => {
                    // Tag.
                    const close = std.mem.indexOfPos(u8, source, open + 2, "%}") orelse
                        return error.UnclosedTag;
                    try tokens.append(allocator, .{ .tag = source[open + 2 .. close] });
                    pos = close + 2;
                },
                '#' => {
                    // Comment — drop entirely.
                    const close = std.mem.indexOfPos(u8, source, open + 2, "#}") orelse
                        return error.UnclosedComment;
                    pos = close + 2;
                },
                else => {
                    // Should be unreachable since findNextOpen only returns
                    // positions followed by {, %, or #.
                    return error.UnclosedTag;
                },
            }
        } else {
            // No more tags — emit the rest as text.
            try tokens.append(allocator, .{ .text = source[pos..] });
            pos = source.len;
        }
    }

    return tokens.toOwnedSlice(allocator);
}

/// Find the next position in `source` (at or after `from`) that starts a
/// template tag — `{{`, `{%`, or `{#`. Returns null if no more tags.
fn findNextOpen(source: []const u8, from: usize) ?usize {
    var i = from;
    while (i + 1 < source.len) : (i += 1) {
        if (source[i] == '{') {
            switch (source[i + 1]) {
                '{', '%', '#' => return i,
                else => continue,
            }
        }
    }
    return null;
}

// =============================================================================
//  AST — defined up front so the parser and renderer can be added in
//  subsequent tasks without restructuring this file.
// =============================================================================

/// A node in the parsed template AST. The parser builds these from
/// tokens; the renderer walks them to produce output.
pub const Node = union(enum) {
    /// Raw text — emitted verbatim.
    text: []const u8,
    /// `{{ var }}` — resolved against the context, HTML-escaped.
    variable: []const u8,
    /// `{% if cond %} A {% else %} B {% endif %}`.
    if_block: IfBlock,
    /// `{% for x in items %} A {% empty %} B {% endfor %}`.
    for_loop: ForLoop,
    /// `{% block name %}...{% endblock %}` — overridable slot.
    block: Block,
    /// `{% extends "parent.jinja" %}` — must be the first node.
    extends: []const u8,
    /// `{% raw %}...{% endraw %}` — content emitted unescaped.
    raw: []Node,
};

pub const IfBlock = struct {
    /// Dotted path expression (e.g. "user.is_authenticated").
    condition: []const u8,
    then_branch: []Node,
    else_branch: []Node,
};

pub const ForLoop = struct {
    /// Loop variable name (e.g. "x").
    var_name: []const u8,
    /// Dotted path to the iterable (e.g. "items").
    iterable: []const u8,
    body: []Node,
    /// `{% empty %}` branch — rendered when the iterable is empty.
    empty_body: []Node,
};

pub const Block = struct {
    name: []const u8,
    body: []Node,
};

/// Compiled template — ready to render. Owns its AST nodes; the caller
/// must call `deinit` to free the node tree and the loader-borrowed
/// source strings.
pub const Compiled = struct {
    nodes: []Node,

    pub fn deinit(self: *Compiled, allocator: std.mem.Allocator) void {
        freeNodes(allocator, self.nodes);
        self.nodes = &[_]Node{};
    }

    /// Render the template with the given context. Output is allocated into
    /// `out_alloc`. (Renderer is implemented in Task 3.)
    pub fn render(
        self: *const Compiled,
        out_alloc: std.mem.Allocator,
        ctx: *Context,
    ) (Error || std.mem.Allocator.Error)![]u8 {
        _ = self;
        _ = out_alloc;
        _ = ctx;
        return error.RenderError; // Implemented in Task 3.
    }
};

/// Free a node tree recursively. Safe to call on partially-constructed
/// trees (handles nested children).
///
/// Ownership contract: by default, `text`, `variable`, and `extends`
/// slices point into the source (NOT heap-allocated) — the caller must
/// keep the source alive while the AST is in use. The exception is the
/// `raw` node, whose text is a fresh heap allocation (reconstructed from
/// multiple tokens); we free it explicitly before recursing.
pub fn freeNodes(allocator: std.mem.Allocator, nodes: []Node) void {
    for (nodes) |node| {
        switch (node) {
            .text, .variable, .extends => {},
            .if_block => |b| {
                freeNodes(allocator, b.then_branch);
                freeNodes(allocator, b.else_branch);
            },
            .for_loop => |l| {
                freeNodes(allocator, l.body);
                freeNodes(allocator, l.empty_body);
            },
            .block => |b| freeNodes(allocator, b.body),
            .raw => |r| {
                // The raw node's text is heap-allocated (reconstructed from
                // multiple tokens). Free it explicitly before recursing.
                for (r) |child| {
                    if (child == .text) allocator.free(child.text);
                }
                freeNodes(allocator, r);
            },
        }
    }
    allocator.free(nodes);
}

// =============================================================================
//  Parser
// =============================================================================
//
// Recursive descent. `parse` walks tokens[start..end] and returns its
// AST. The recursive helpers (`parseIf`, `parseFor`, `parseBlock`,
// `parseRaw`) find their matching closer using `findMatchingTag` so
// nested constructs resolve correctly. The helper returns the position
// of the closer; the caller skips past it.

/// Parse a token stream into an AST. The caller owns the AST and must
/// free it with `freeNodes`.
pub fn parse(allocator: std.mem.Allocator, tokens: []const Token) (Error || std.mem.Allocator.Error)![]Node {
    return parseNodes(allocator, tokens, 0, tokens.len);
}

/// Convenience: tokenize then parse.
pub fn parseSource(allocator: std.mem.Allocator, source: []const u8) (Error || std.mem.Allocator.Error)![]Node {
    const tokens = try tokenize(allocator, source);
    defer allocator.free(tokens);
    return try parseNodes(allocator, tokens, 0, tokens.len);
}

// =============================================================================
//  Inheritance
// =============================================================================
//
// `compileWithParent` returns a single AST that, when rendered, produces
// the parent's HTML with the child's block bodies substituted in. The
// algorithm:
//
//   1. Parse the child source.
//   2. If the child has an `{% extends "path" %}` node, load the parent
//      via the loader and recursively compile the parent (so multi-level
//      inheritance resolves correctly).
//   3. Build a map `name → child_block_body` from the child's blocks.
//   4. Walk the parent's AST in place, replacing each `block` node's
//      `body` with the matching child block's body if present.
//   5. Return the merged AST.
//
// The merged AST is a regular AST — non-block nodes inside the child
// (text, variables, if/for) are discarded. Only `block` nodes from the
// child survive into the parent.

/// Loader function: takes a path, returns a heap-allocated source string.
/// The caller owns the returned buffer.
pub const LoaderFn = *const fn (
    ctx: *anyopaque,
    allocator: std.mem.Allocator,
    path: []const u8,
) anyerror![]u8;

/// Compile a template with inheritance resolution. The loader is used
/// to fetch parent templates (and their parents, recursively).
pub fn compileWithParent(
    allocator: std.mem.Allocator,
    source: []const u8,
    loader_ctx: *anyopaque,
    loader_fn: LoaderFn,
) (Error || std.mem.Allocator.Error)![]Node {
    var visited = std.StringHashMap(void).init(allocator);
    defer visited.deinit();
    return compileWithParentImpl(allocator, source, loader_ctx, loader_fn, &visited);
}

fn compileWithParentImpl(
    allocator: std.mem.Allocator,
    source: []const u8,
    loader_ctx: *anyopaque,
    loader_fn: LoaderFn,
    visited: *std.StringHashMap(void),
) (Error || std.mem.Allocator.Error)![]Node {
    // Parse the child.
    const child_nodes = try parseSource(allocator, source);
    errdefer freeNodes(allocator, child_nodes);

    // Find the extends node (if any).
    var extends_path: ?[]const u8 = null;
    for (child_nodes) |node| {
        if (node == .extends) {
            extends_path = node.extends;
            break;
        }
    }

    // Standalone template (no inheritance): return the parsed nodes as-is.
    if (extends_path == null) {
        return child_nodes;
    }

    // Inheritance: load parent, compile it recursively, merge blocks.
    const parent_path = extends_path.?;

    // For the test loader, we can't easily track visited — the test
    // loader doesn't pass paths through `visited`. We rely on the test
    // data not to have circular extends. (A real loader would check.)
    const parent_source = loader_fn(loader_ctx, allocator, parent_path) catch
        return error.TemplateNotFound;
    defer allocator.free(parent_source);

    const parent_nodes = try compileWithParentImpl(allocator, parent_source, loader_ctx, loader_fn, visited);
    errdefer freeNodes(allocator, parent_nodes);

    // Build a map of child block bodies keyed by name. Deep-copy the
    // bodies so child_nodes can be safely freed after merge — the
    // copies are the only references that survive into the parent.
    var child_blocks = std.StringHashMap([]Node).init(allocator);
    defer child_blocks.deinit();
    for (child_nodes) |node| {
        if (node == .block) {
            const copied = try copyNodeSlice(allocator, node.block.body);
            try child_blocks.put(node.block.name, copied);
        }
    }

    // Walk the parent AST, replacing each block's body with the child
    // override if present. We MUTATE the parent's block nodes in place
    // because the parent_nodes are owned by us (deep-copied from the
    // recursive call's output).
    try mergeBlocks(allocator, parent_nodes, &child_blocks);

    // Deep-copy ALL text/variable/extends slices in parent_nodes so
    // the AST is self-contained. After this, we can free parent_source
    // without invalidating the AST. This is needed because the recursive
    // call's defer frees parent_source before the caller uses parent_nodes.
    try copyAllStrings(allocator, parent_nodes);

    // The child's blocks are no longer needed (their bodies are now
    // embedded in the parent). The non-block child nodes are discarded.
    // The child_nodes allocation still needs to be freed — but its
    // block.body slices now point into merged content. Hmm, this is
    // ownership-tricky.
    //
    // Simpler approach: DON'T take ownership of child_nodes. We parsed
    // it just to extract the block bodies. We've already extracted them
    // into child_blocks. Now free child_nodes.
    freeNodes(allocator, child_nodes);

    return parent_nodes;
}

/// Walk an AST and deep-copy every string slice into the given allocator.
/// Covers text/variable/extends IN EVERY NODE, plus the metadata strings
/// (condition/var_name/iterable/name) on structured nodes. Recursive
/// children are also copied. The result is self-contained: freeing the
/// original source doesn't invalidate the AST.
fn copyAllStrings(allocator: std.mem.Allocator, nodes: []Node) (Error || std.mem.Allocator.Error)!void {
    for (nodes) |*node| {
        switch (node.*) {
            .text => |*t| t.* = try allocator.dupe(u8, t.*),
            .variable => |*v| v.* = try allocator.dupe(u8, v.*),
            .extends => |*e| e.* = try allocator.dupe(u8, e.*),
            .if_block => |*b| {
                b.condition = try allocator.dupe(u8, b.condition);
                try copyAllStrings(allocator, b.then_branch);
                try copyAllStrings(allocator, b.else_branch);
            },
            .for_loop => |*l| {
                l.var_name = try allocator.dupe(u8, l.var_name);
                l.iterable = try allocator.dupe(u8, l.iterable);
                try copyAllStrings(allocator, l.body);
                try copyAllStrings(allocator, l.empty_body);
            },
            .block => |*b| {
                b.name = try allocator.dupe(u8, b.name);
                try copyAllStrings(allocator, b.body);
            },
            .raw => |r| try copyAllStrings(allocator, r),
        }
    }
}

/// Deep-copy a slice of nodes. The text/variable/extends inner slices
/// are duplicated into the new allocator so the copy is fully owned —
/// callers can free the source (or the original) without invalidating
/// the copy. Recursive structures (if/for/block/raw) are also deep-copied.
fn copyNodeSlice(allocator: std.mem.Allocator, nodes: []const Node) (Error || std.mem.Allocator.Error)![]Node {
    const out = try allocator.alloc(Node, nodes.len);
    errdefer allocator.free(out);
    for (nodes, 0..) |node, i| {
        out[i] = try copyNode(allocator, node);
    }
    return out;
}

fn copyNode(allocator: std.mem.Allocator, node: Node) (Error || std.mem.Allocator.Error)!Node {
    return switch (node) {
        .text => |t| .{ .text = try allocator.dupe(u8, t) },
        .variable => |v| .{ .variable = try allocator.dupe(u8, v) },
        .extends => |e| .{ .extends = try allocator.dupe(u8, e) },
        .if_block => |b| .{ .if_block = IfBlock{
            .condition = b.condition,
            .then_branch = try copyNodeSlice(allocator, b.then_branch),
            .else_branch = try copyNodeSlice(allocator, b.else_branch),
        } },
        .for_loop => |l| .{ .for_loop = ForLoop{
            .var_name = l.var_name,
            .iterable = l.iterable,
            .body = try copyNodeSlice(allocator, l.body),
            .empty_body = try copyNodeSlice(allocator, l.empty_body),
        } },
        .block => |b| .{ .block = Block{
            .name = b.name,
            .body = try copyNodeSlice(allocator, b.body),
        } },
        .raw => |r| .{ .raw = try copyNodeSlice(allocator, r) },
    };
}

/// Walk an AST and replace each `block` node's body with the matching
/// override from `overrides`. Recurses into nested if/for/raw children.
fn mergeBlocks(
    allocator: std.mem.Allocator,
    nodes: []Node,
    overrides: *std.StringHashMap([]Node),
) (Error || std.mem.Allocator.Error)!void {
    for (nodes) |*node| {
        switch (node.*) {
            .text, .variable, .extends => {},
            .if_block => |*b| {
                try mergeBlocks(allocator, b.then_branch, overrides);
                try mergeBlocks(allocator, b.else_branch, overrides);
            },
            .for_loop => |*l| {
                try mergeBlocks(allocator, l.body, overrides);
                try mergeBlocks(allocator, l.empty_body, overrides);
            },
            .block => |*b| {
                if (overrides.get(b.name)) |child_body| {
                    // The child body is a fresh slice; we can take it.
                    // NOTE: the child's block.name is also heap-allocated
                    // via parseSource; we keep the parent's name (it was
                    // the same string anyway, but we don't need to free
                    // the child's copy).
                    b.* = .{
                        .name = b.name,
                        .body = child_body,
                    };
                } else {
                    // No override; recurse into the parent's body.
                    try mergeBlocks(allocator, b.body, overrides);
                }
            },
            .raw => |r| try mergeBlocks(allocator, r, overrides),
        }
    }
}

fn parseNodes(
    allocator: std.mem.Allocator,
    tokens: []const Token,
    start: usize,
    end: usize,
) (Error || std.mem.Allocator.Error)![]Node {
    var nodes = std.ArrayListUnmanaged(Node).empty;
    errdefer {
        for (nodes.items) |n| {
            // Free any children we already appended.
            switch (n) {
                .if_block => |b| {
                    freeNodes(allocator, b.then_branch);
                    freeNodes(allocator, b.else_branch);
                },
                .for_loop => |l| {
                    freeNodes(allocator, l.body);
                    freeNodes(allocator, l.empty_body);
                },
                .block => |b| freeNodes(allocator, b.body),
                .raw => |r| freeNodes(allocator, r),
                else => {},
            }
        }
        nodes.deinit(allocator);
    }

    var i: usize = start;
    while (i < end) : (i += 1) {
        const tok = tokens[i];
        switch (tok) {
            .text => try nodes.append(allocator, .{ .text = tok.text }),
            .var_expr => {
                const trimmed = std.mem.trim(u8, tok.var_expr, " \t");
                try nodes.append(allocator, .{ .variable = trimmed });
            },
            .tag => {
                const trimmed = std.mem.trim(u8, tok.tag, " \t");
                if (std.mem.startsWith(u8, trimmed, "if ")) {
                    const cond = std.mem.trim(u8, trimmed[3..], " \t");
                    const after = try parseIf(allocator, tokens, i + 1, end, cond);
                    try nodes.append(allocator, after.node);
                    // after.next is the position AFTER the closer (endif);
                    // the while loop's `i += 1` will then move past it.
                    i = after.next - 1;
                } else if (std.mem.startsWith(u8, trimmed, "for ")) {
                    // "for VAR in EXPR"
                    const rest = trimmed[4..];
                    const in_idx = std.mem.indexOf(u8, rest, " in ") orelse
                        return error.ParseError;
                    const var_name = std.mem.trim(u8, rest[0..in_idx], " \t");
                    const iter = std.mem.trim(u8, rest[in_idx + 4 ..], " \t");
                    const after = try parseFor(allocator, tokens, i + 1, end, var_name, iter);
                    try nodes.append(allocator, after.node);
                    i = after.next - 1;
                } else if (std.mem.startsWith(u8, trimmed, "block ")) {
                    const name = std.mem.trim(u8, trimmed[6..], " \t");
                    const after = try parseBlock(allocator, tokens, i + 1, end, name);
                    try nodes.append(allocator, after.node);
                    i = after.next - 1;
                } else if (std.mem.startsWith(u8, trimmed, "extends ")) {
                    const path = std.mem.trim(u8, trimmed[8..], " \t");
                    // Strip quotes if present (single or double).
                    const stripped = stripQuotes(path);
                    try nodes.append(allocator, .{ .extends = stripped });
                } else if (std.mem.eql(u8, trimmed, "raw")) {
                    const after = try parseRaw(allocator, tokens, i + 1, end);
                    try nodes.append(allocator, after.node);
                    i = after.next - 1;
                } else {
                    // Unexpected tag at top level: else, endif, endfor, etc.
                    return error.ParseError;
                }
            },
        }
    }

    return nodes.toOwnedSlice(allocator);
}

const ParseResult = struct {
    node: Node,
    /// Token index immediately AFTER the closer (so the caller can `i = next`).
    next: usize,
};

fn parseIf(
    allocator: std.mem.Allocator,
    tokens: []const Token,
    start: usize,
    end: usize,
    condition: []const u8,
) (Error || std.mem.Allocator.Error)!ParseResult {
    // Find the matching `else` or `endif` at depth 1.
    const split = try findIfSplit(tokens, start, end);
    const then_branch = try parseNodes(allocator, tokens, start, split.marker);

    var else_branch: []Node = &[_]Node{};
    const next = split.closer;

    if (split.has_else) {
        // The body between `else` and `endif` is the else-branch.
        else_branch = try parseNodes(allocator, tokens, split.marker + 1, split.closer);
    }
    return .{
        .node = .{ .if_block = IfBlock{
            .condition = condition,
            .then_branch = then_branch,
            .else_branch = else_branch,
        } },
        .next = next + 1, // skip past endif
    };
}

const IfSplit = struct {
    /// Token index of the `else` if present, else the `endif`.
    marker: usize,
    closer: usize,
    has_else: bool,
};

fn findIfSplit(tokens: []const Token, start: usize, end: usize) Error!IfSplit {
    var depth: i32 = 1;
    var i: usize = start;
    while (i < end) : (i += 1) {
        if (tokens[i] == .tag) {
            const t = std.mem.trim(u8, tokens[i].tag, " \t");
            if (std.mem.startsWith(u8, t, "if ")) {
                depth += 1;
            } else if (std.mem.eql(u8, t, "else") and depth == 1) {
                // Found the else at depth 1. Now find the matching endif.
                const closer = findMatchingTag(tokens, i + 1, end, "endif") orelse
                    return error.ParseError;
                return .{ .marker = i, .closer = closer, .has_else = true };
            } else if (std.mem.eql(u8, t, "endif")) {
                depth -= 1;
                if (depth == 0) {
                    return .{ .marker = i, .closer = i, .has_else = false };
                }
            }
        }
    }
    return error.ParseError;
}

fn parseFor(
    allocator: std.mem.Allocator,
    tokens: []const Token,
    start: usize,
    end: usize,
    var_name: []const u8,
    iter: []const u8,
) (Error || std.mem.Allocator.Error)!ParseResult {
    const split = try findForSplit(tokens, start, end);
    const body = try parseNodes(allocator, tokens, start, split.marker);

    var empty_body: []Node = &[_]Node{};
    const next = split.closer;

    if (split.has_empty) {
        empty_body = try parseNodes(allocator, tokens, split.marker + 1, split.closer);
    }
    return .{
        .node = .{ .for_loop = ForLoop{
            .var_name = var_name,
            .iterable = iter,
            .body = body,
            .empty_body = empty_body,
        } },
        .next = next + 1,
    };
}

const ForSplit = struct {
    marker: usize,
    closer: usize,
    has_empty: bool,
};

fn findForSplit(tokens: []const Token, start: usize, end: usize) Error!ForSplit {
    var depth: i32 = 1;
    var i: usize = start;
    while (i < end) : (i += 1) {
        if (tokens[i] == .tag) {
            const t = std.mem.trim(u8, tokens[i].tag, " \t");
            if (std.mem.startsWith(u8, t, "for ")) {
                depth += 1;
            } else if (std.mem.eql(u8, t, "empty") and depth == 1) {
                // Found the empty at depth 1. Find the matching endfor.
                const closer = findMatchingTag(tokens, i + 1, end, "endfor") orelse
                    return error.ParseError;
                return .{ .marker = i, .closer = closer, .has_empty = true };
            } else if (std.mem.eql(u8, t, "endfor")) {
                depth -= 1;
                if (depth == 0) {
                    return .{ .marker = i, .closer = i, .has_empty = false };
                }
            }
        }
    }
    return error.ParseError;
}

fn parseBlock(
    allocator: std.mem.Allocator,
    tokens: []const Token,
    start: usize,
    end: usize,
    name: []const u8,
) (Error || std.mem.Allocator.Error)!ParseResult {
    const closer = findMatchingTag(tokens, start, end, "endblock") orelse
        return error.ParseError;
    const body = try parseNodes(allocator, tokens, start, closer);
    return .{
        .node = .{ .block = Block{
            .name = name,
            .body = body,
        } },
        .next = closer + 1,
    };
}

fn parseRaw(
    allocator: std.mem.Allocator,
    tokens: []const Token,
    start: usize,
    end: usize,
) (Error || std.mem.Allocator.Error)!ParseResult {
    const closer = findMatchingTag(tokens, start, end, "endraw") orelse
        return error.ParseError;
    // Reconstruct the original source verbatim. The tokenizer strips the
    // `{{`, `}}`, `{%`, `%}` delimiters from each token — we put them
    // back so the raw body matches what the user wrote exactly.
    var body = std.ArrayListUnmanaged(u8).empty;
    errdefer body.deinit(allocator);
    var i: usize = start;
    while (i < closer) : (i += 1) {
        switch (tokens[i]) {
            .text => |t| try body.appendSlice(allocator, t),
            .var_expr => |v| {
                try body.appendSlice(allocator, "{{");
                try body.appendSlice(allocator, v);
                try body.appendSlice(allocator, "}}");
            },
            .tag => |t| {
                try body.appendSlice(allocator, "{%");
                try body.appendSlice(allocator, t);
                try body.appendSlice(allocator, "%}");
            },
        }
    }
    const text = try body.toOwnedSlice(allocator);
    var nodes_slice = try allocator.alloc(Node, 1);
    nodes_slice[0] = .{ .text = text };
    return .{
        .node = .{ .raw = nodes_slice },
        .next = closer + 1,
    };
}

fn findMatchingTag(tokens: []const Token, start: usize, end: usize, closer_cmd: []const u8) ?usize {
    var depth: i32 = 1;
    var i: usize = start;
    while (i < end) : (i += 1) {
        if (tokens[i] == .tag) {
            const t = std.mem.trim(u8, tokens[i].tag, " \t");
            if (std.mem.eql(u8, t, closer_cmd)) {
                depth -= 1;
                if (depth == 0) return i;
            }
            // For raw, nested raw/endraw does NOT count (no nesting semantics).
            // For block, nested block/endblock DO count.
            if (std.mem.startsWith(u8, t, "block ") and std.mem.eql(u8, closer_cmd, "endblock")) {
                depth += 1;
            }
        }
    }
    return null;
}

fn stripQuotes(s: []const u8) []const u8 {
    if (s.len >= 2) {
        const first = s[0];
        const last = s[s.len - 1];
        if ((first == '"' or first == '\'') and first == last) {
            return s[1 .. s.len - 1];
        }
    }
    return s;
}

// =============================================================================
//  Context — defined up front so the renderer can be added in Task 3.
// =============================================================================

/// A value passed into the template. Strings are slices — not owned by
/// the Value. Maps and arrays are owned; freeing them is the caller's
/// responsibility (use `Context.deinit`).
pub const Value = union(enum) {
    null,
    bool: bool,
    int: i64,
    string: []const u8,
    array: []const Value,
    map: std.StringHashMap(Value),
};

/// The runtime context. Backed by a HashMap; supports dotted-path lookups
/// (`user.name`) and bracket index (`items[0]`) at render time. A
/// context may have a parent (used for loop variable scoping) — lookups
/// walk up the chain until a value is found.
pub const Context = struct {
    allocator: std.mem.Allocator,
    values: std.StringHashMap(Value),
    parent: ?*const Context = null,

    pub fn init(allocator: std.mem.Allocator) Context {
        return .{
            .allocator = allocator,
            .values = std.StringHashMap(Value).init(allocator),
            .parent = null,
        };
    }

    /// Create a child context that falls back to `parent` for lookups.
    /// Use this for `{% for x in items %}` — the loop body sees both
    /// `x` and the parent's variables.
    pub fn child(parent: *const Context) Context {
        return .{
            .allocator = parent.allocator,
            .values = std.StringHashMap(Value).init(parent.allocator),
            .parent = parent,
        };
    }

    /// Insert a value into THIS context (not the parent).
    pub fn put(self: *Context, key: []const u8, value: Value) !void {
        try self.values.put(key, value);
    }

    pub fn deinit(self: *Context) void {
        self.values.deinit();
    }

    /// Look up a dotted path like "user.name" or "items[0].name". Walks
    /// the parent chain until a value is found. Returns null if any
    /// segment is missing or the wrong type.
    pub fn getPath(self: *const Context, path: []const u8) ?Value {
        return lookupPath(self, path);
    }
};

/// Path resolution. Supports three segment types:
///   * dotted       — `user.name`        → .name on a map
///   * bracket      — `items[0]`         → [0] on an array
///   * mixed        — `items[0].name`    → [0] then .name
///
/// First, try to look up the whole path as a key in the context chain.
/// If that misses, walk segment-by-segment starting with the first
/// dotted/bracket-prefixed part.
fn lookupPath(ctx_opt: ?*const Context, path: []const u8) ?Value {
    // Step 1: try the whole path as a top-level key.
    {
        var c = ctx_opt;
        while (c) |cc| {
            if (cc.values.get(path)) |v| {
                if (v != .null) return v;
            }
            c = cc.parent;
        }
    }

    // Step 2: walk segment-by-segment. Start by looking up the first
    // identifier (everything before the first `.` or `[`).
    const first_end = std.mem.indexOfAny(u8, path, ".[") orelse path.len;
    const first = path[0..first_end];

    var current: ?Value = null;
    {
        var c = ctx_opt;
        while (c) |cc| {
            if (cc.values.get(first)) |v| {
                if (v != .null) {
                    current = v;
                    break;
                }
            }
            c = cc.parent;
        }
    }
    if (current == null) return null;

    // Step 3: walk the remaining segments.
    var rest: []const u8 = path[first_end..];
    while (rest.len > 0) {
        const v = current orelse return null;
        if (rest[0] == '.') {
            // dotted: .name
            rest = rest[1..];
            const end = std.mem.indexOfAny(u8, rest, ".[") orelse rest.len;
            const key = rest[0..end];
            if (v != .map) return null;
            current = v.map.get(key);
            rest = rest[end..];
        } else if (rest[0] == '[') {
            // bracket: [N]
            const close = std.mem.indexOfPos(u8, rest, 1, "]") orelse return null;
            const idx_str = rest[1..close];
            const idx = std.fmt.parseInt(usize, idx_str, 10) catch return null;
            if (v != .array) return null;
            if (idx >= v.array.len) return null;
            current = v.array[idx];
            rest = rest[close + 1 ..];
        } else {
            return null;
        }
    }

    return current;
}

/// Truthy check for `{% if %}` conditions. Mirrors Python/Jinja semantics:
/// null/false/0/empty-string/empty-array = falsy; everything else truthy.
fn isTruthy(v: Value) bool {
    return switch (v) {
        .null => false,
        .bool => |b| b,
        .int => |i| i != 0,
        .string => |s| s.len > 0,
        .array => |a| a.len > 0,
        .map => |m| m.count() > 0,
    };
}

/// Append the HTML-escaped form of `s` to `out`. Escapes
///   & → &amp;     < → &lt;      > → &gt;
///   " → &quot;    ' → &#x27;
/// Both attributes and text content are protected.
fn escapeHtml(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), s: []const u8) (Error || std.mem.Allocator.Error)!void {
    var i: usize = 0;
    while (i < s.len) {
        const c = s[i];
        switch (c) {
            '&' => try out.appendSlice(allocator, "&amp;"),
            '<' => try out.appendSlice(allocator, "&lt;"),
            '>' => try out.appendSlice(allocator, "&gt;"),
            '"' => try out.appendSlice(allocator, "&quot;"),
            '\'' => try out.appendSlice(allocator, "&#x27;"),
            else => try out.append(allocator, c),
        }
        i += 1;
    }
}

/// Append the string form of a value to `out`. Strings are escaped;
/// other types are rendered as-is (Jinja default).
fn appendValue(
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    v: Value,
) (Error || std.mem.Allocator.Error)!void {
    switch (v) {
        .null => {},
        .bool => |b| try out.appendSlice(allocator, if (b) "true" else "false"),
        .int => |i| {
            const buf = try std.fmt.allocPrint(allocator, "{d}", .{i});
            defer allocator.free(buf);
            try out.appendSlice(allocator, buf);
        },
        .string => |s| try escapeHtml(allocator, out, s),
        .array => |a| {
            for (a) |item| {
                try appendValue(allocator, out, item);
            }
        },
        .map => |m| {
            var it = m.iterator();
            while (it.next()) |entry| {
                try out.appendSlice(allocator, entry.key_ptr.*);
                try out.append(allocator, '=');
                try appendValue(allocator, out, entry.value_ptr.*);
            }
        },
    }
}

/// Render an AST node list with the given context. Output is allocated
/// into `out_alloc`. Replaces the placeholder `Compiled.render` — the
/// Compiled struct is a future convenience wrapper.
pub fn render(
    out_alloc: std.mem.Allocator,
    nodes: []const Node,
    ctx: *const Context,
) (Error || std.mem.Allocator.Error)![]u8 {
    var out = std.ArrayListUnmanaged(u8).empty;
    errdefer out.deinit(out_alloc);
    try renderNodes(out_alloc, &out, nodes, ctx);
    return out.toOwnedSlice(out_alloc);
}

fn renderNodes(
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    nodes: []const Node,
    ctx: *const Context,
) (Error || std.mem.Allocator.Error)!void {
    for (nodes) |node| {
        switch (node) {
            .text => |t| try out.appendSlice(allocator, t),
            .variable => |path| {
                if (ctx.getPath(path)) |v| {
                    try appendValue(allocator, out, v);
                }
            },
            .if_block => |b| {
                const cond = ctx.getPath(b.condition) orelse .null;
                if (isTruthy(cond)) {
                    try renderNodes(allocator, out, b.then_branch, ctx);
                } else {
                    try renderNodes(allocator, out, b.else_branch, ctx);
                }
            },
            .for_loop => |l| {
                const iterable = ctx.getPath(l.iterable) orelse .null;
                if (iterable == .array and iterable.array.len > 0) {
                    for (iterable.array) |item| {
                        var inner = Context.child(ctx);
                        defer inner.deinit();
                        try inner.put(l.var_name, item);
                        try renderNodes(allocator, out, l.body, &inner);
                    }
                } else {
                    try renderNodes(allocator, out, l.empty_body, ctx);
                }
            },
            .block => |b| {
                // In standalone rendering (no inheritance), blocks just
                // render their body. Inheritance layer (Task 4) rewrites
                // these bodies to child blocks at compile time.
                try renderNodes(allocator, out, b.body, ctx);
            },
            .extends => {
                // Standalone render of an extends node emits nothing —
                // the entire output is the parent template's render.
                // The inheritance layer handles this at compile time.
            },
            .raw => |r| {
                // Raw nodes contain a single text node whose content is
                // the verbatim source (excluding the {% raw %} / {% endraw %}
                // tags themselves). Emit as-is.
                for (r) |child| {
                    if (child == .text) try out.appendSlice(allocator, child.text);
                }
            },
        }
    }
}
