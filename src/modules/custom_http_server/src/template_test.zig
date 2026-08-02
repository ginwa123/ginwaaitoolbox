// Tests for the Jinja-style template engine (template.zig).
//
// Organised by ENGINE LAYER — Tokenizer, Parser, Renderer, Inheritance —
// so each test block maps to one Task in the plan. Within each block,
// tests are ordered simplest to most-complex.
//
// Test data lives inline as comptime-known strings so failures show the
// exact input that broke.
const std = @import("std");
const testing = std.testing;
const Template = @import("template.zig");

// =============================================================================
//  Task 1 — Tokenizer
// =============================================================================
//
// Tokenize() returns a slice of `text | var_expr | tag` tokens whose
// content slices point into the source. Comments `{# ... #}` are
// dropped (no token emitted). Three unclosed cases raise errors so the
// caller gets a parse error pointing at the source location.
//
// Note on slice equality: tests use `expectEqualStrings` on the
// inner slices because `expectEqual` on slices compares pointers
// (the token's slice points into the source buffer; the test literal
// points into the test's rodata).

fn tokenizeChecked(alloc: std.mem.Allocator, source: []const u8) ![]Template.Token {
    return try Template.tokenize(alloc, source);
}

test "tokenize: plain text returns one text token" {
    const tokens = try tokenizeChecked(testing.allocator, "hello world");
    defer testing.allocator.free(tokens);

    try testing.expectEqual(@as(usize, 1), tokens.len);
    try testing.expect(tokens[0] == .text);
    try testing.expectEqualStrings("hello world", tokens[0].text);
}

test "tokenize: variable expression returns var_expr token" {
    const tokens = try tokenizeChecked(testing.allocator, "{{ name }}");
    defer testing.allocator.free(tokens);

    try testing.expectEqual(@as(usize, 1), tokens.len);
    try testing.expect(tokens[0] == .var_expr);
    // The lexer preserves the surrounding whitespace inside `{{ ... }}`;
    // the parser is responsible for trimming/parsing it.
    try testing.expectEqualStrings(" name ", tokens[0].var_expr);
}

test "tokenize: tag returns tag token with inner content" {
    const tokens = try tokenizeChecked(testing.allocator, "{% if x %}");
    defer testing.allocator.free(tokens);

    try testing.expectEqual(@as(usize, 1), tokens.len);
    try testing.expect(tokens[0] == .tag);
    try testing.expectEqualStrings(" if x ", tokens[0].tag);
}

test "tokenize: comment is dropped (no token emitted)" {
    const tokens = try tokenizeChecked(testing.allocator, "before {# skipped #} after");
    defer testing.allocator.free(tokens);

    try testing.expectEqual(@as(usize, 2), tokens.len);
    try testing.expect(tokens[0] == .text);
    try testing.expectEqualStrings("before ", tokens[0].text);
    try testing.expect(tokens[1] == .text);
    try testing.expectEqualStrings(" after", tokens[1].text);
}

test "tokenize: mixed text + var + tag + comment interleaves correctly" {
    // Source: "a {{ b }} c {% d %} {# e #} f"
    //   index: 0         1     2          3
    //   text "a " + var_expr " b " + text " c " + tag " d " + text " " + text " f"
    // (The text between the tag and the comment is a single space — not
    // coalesced with the text after the comment, since the lexer doesn't
    // know that "comment" is a no-op.)
    const tokens = try tokenizeChecked(testing.allocator, "a {{ b }} c {% d %} {# e #} f");
    defer testing.allocator.free(tokens);

    try testing.expectEqual(@as(usize, 6), tokens.len);
    try testing.expectEqualStrings("a ", tokens[0].text);
    try testing.expectEqualStrings(" b ", tokens[1].var_expr);
    try testing.expectEqualStrings(" c ", tokens[2].text);
    try testing.expectEqualStrings(" d ", tokens[3].tag);
    try testing.expectEqualStrings(" ", tokens[4].text);
    try testing.expectEqualStrings(" f", tokens[5].text);
}

test "tokenize: unclosed {{ raises UnclosedVariable" {
    const result = tokenizeChecked(testing.allocator, "hello {{ name");
    try testing.expectError(error.UnclosedVariable, result);
}

test "tokenize: unclosed {% raises UnclosedTag" {
    const result = tokenizeChecked(testing.allocator, "hello {% if x");
    try testing.expectError(error.UnclosedTag, result);
}

test "tokenize: unclosed {# raises UnclosedComment" {
    const result = tokenizeChecked(testing.allocator, "hello {# comment");
    try testing.expectError(error.UnclosedComment, result);
}

// =============================================================================
//  Task 2 — Parser
// =============================================================================
//
// parse() walks the token stream and produces an AST. The AST is a flat
// slice of `Node` (which is a tagged union including text, variable, if,
// for, block, extends, raw). Nested constructs (if-inside-for) appear
// as nested slices inside the parent node.

fn parseChecked(alloc: std.mem.Allocator, source: []const u8) ![]Template.Node {
    const tokens = try Template.tokenize(alloc, source);
    defer testing.allocator.free(tokens);
    return try Template.parse(alloc, tokens);
}

test "parse: empty source returns empty node list" {
    const nodes = try parseChecked(testing.allocator, "");
    defer testing.allocator.free(nodes);
    try testing.expectEqual(@as(usize, 0), nodes.len);
}

test "parse: text only → single text node" {
    const nodes = try parseChecked(testing.allocator, "hello world");
    defer testing.allocator.free(nodes);
    try testing.expectEqual(@as(usize, 1), nodes.len);
    try testing.expect(nodes[0] == .text);
    try testing.expectEqualStrings("hello world", nodes[0].text);
}

test "parse: variable only → single variable node" {
    const nodes = try parseChecked(testing.allocator, "{{ name }}");
    defer testing.allocator.free(nodes);
    try testing.expectEqual(@as(usize, 1), nodes.len);
    try testing.expect(nodes[0] == .variable);
    try testing.expectEqualStrings("name", nodes[0].variable);
}

test "parse: if without else → if_block with empty else_branch" {
    const nodes = try parseChecked(testing.allocator, "{% if cond %}yes{% endif %}");
    defer Template.freeNodes(testing.allocator, nodes);
    try testing.expectEqual(@as(usize, 1), nodes.len);
    try testing.expect(nodes[0] == .if_block);
    const ifb = nodes[0].if_block;
    try testing.expectEqualStrings("cond", ifb.condition);
    try testing.expectEqual(@as(usize, 1), ifb.then_branch.len);
    try testing.expectEqualStrings("yes", ifb.then_branch[0].text);
    try testing.expectEqual(@as(usize, 0), ifb.else_branch.len);
}

test "parse: if with else → both branches populated" {
    const nodes = try parseChecked(testing.allocator, "{% if cond %}A{% else %}B{% endif %}");
    defer Template.freeNodes(testing.allocator, nodes);
    try testing.expectEqual(@as(usize, 1), nodes.len);
    const ifb = nodes[0].if_block;
    try testing.expectEqualStrings("A", ifb.then_branch[0].text);
    try testing.expectEqualStrings("B", ifb.else_branch[0].text);
}

test "parse: for loop → for_loop with empty_body empty" {
    const nodes = try parseChecked(testing.allocator, "{% for x in items %}<{{ x }}>{% endfor %}");
    defer Template.freeNodes(testing.allocator, nodes);
    try testing.expectEqual(@as(usize, 1), nodes.len);
    try testing.expect(nodes[0] == .for_loop);
    const fl = nodes[0].for_loop;
    try testing.expectEqualStrings("x", fl.var_name);
    try testing.expectEqualStrings("items", fl.iterable);
    try testing.expectEqual(@as(usize, 0), fl.empty_body.len);
    // Body should have text "<" + variable "x" + text ">".
    try testing.expectEqual(@as(usize, 3), fl.body.len);
    try testing.expectEqualStrings("<", fl.body[0].text);
    try testing.expectEqualStrings("x", fl.body[1].variable);
    try testing.expectEqualStrings(">", fl.body[2].text);
}

test "parse: for with empty branch → empty_body populated" {
    const nodes = try parseChecked(testing.allocator, "{% for x in items %}A{% empty %}B{% endfor %}");
    defer Template.freeNodes(testing.allocator, nodes);
    const fl = nodes[0].for_loop;
    try testing.expectEqualStrings("A", fl.body[0].text);
    try testing.expectEqualStrings("B", fl.empty_body[0].text);
}

test "parse: nested if inside for" {
    const nodes = try parseChecked(
        testing.allocator,
        "{% for x in items %}{% if x %}{{ x }}{% endif %}{% endfor %}",
    );
    defer Template.freeNodes(testing.allocator, nodes);
    try testing.expectEqual(@as(usize, 1), nodes.len);
    const fl = nodes[0].for_loop;
    try testing.expectEqual(@as(usize, 1), fl.body.len);
    try testing.expect(fl.body[0] == .if_block);
    try testing.expectEqualStrings("x", fl.body[0].if_block.condition);
    try testing.expectEqualStrings("x", fl.body[0].if_block.then_branch[0].variable);
}

test "parse: extends + block → extends first, then block" {
    const nodes = try parseChecked(testing.allocator,
        \\{% extends "base.jinja" %}
        \\{% block content %}hello{% endblock %}
    );
    defer Template.freeNodes(testing.allocator, nodes);
    // 3 nodes: extends, the "\n" text in between, block.
    try testing.expectEqual(@as(usize, 3), nodes.len);
    try testing.expect(nodes[0] == .extends);
    try testing.expectEqualStrings("base.jinja", nodes[0].extends);
    try testing.expect(nodes[1] == .text);
    try testing.expectEqualStrings("\n", nodes[1].text);
    try testing.expect(nodes[2] == .block);
    try testing.expectEqualStrings("content", nodes[2].block.name);
    try testing.expectEqualStrings("hello", nodes[2].block.body[0].text);
}

test "parse: raw → raw node with text children" {
    const nodes = try parseChecked(testing.allocator,
        \\{% raw %}{{ not processed }}{% endraw %}
    );
    defer Template.freeNodes(testing.allocator, nodes);
    try testing.expectEqual(@as(usize, 1), nodes.len);
    try testing.expect(nodes[0] == .raw);
    try testing.expectEqual(@as(usize, 1), nodes[0].raw.len);
    try testing.expect(nodes[0].raw[0] == .text);
    try testing.expectEqualStrings("{{ not processed }}", nodes[0].raw[0].text);
}

test "parse: dotted path variable preserves dots" {
    const nodes = try parseChecked(testing.allocator, "{{ user.name }}");
    defer testing.allocator.free(nodes);
    try testing.expectEqual(@as(usize, 1), nodes.len);
    try testing.expectEqualStrings("user.name", nodes[0].variable);
}

test "parse: malformed if (no endif) → ParseError" {
    const result = parseChecked(testing.allocator, "{% if cond %}yes");
    try testing.expectError(error.ParseError, result);
}

test "parse: malformed for (no endfor) → ParseError" {
    const result = parseChecked(testing.allocator, "{% for x in items %}body");
    try testing.expectError(error.ParseError, result);
}

// =============================================================================
//  Task 3 — Renderer
// =============================================================================
//
// Render() walks the AST with a Context and produces a string. Tests
// cover the four core features plus the auto-escape default.

fn renderChecked(
    alloc: std.mem.Allocator,
    source: []const u8,
    context: *Template.Context,
) ![]u8 {
    const nodes = try Template.parseSource(alloc, source);
    defer Template.freeNodes(alloc, nodes);
    return try Template.render(alloc, nodes, context);
}

fn renderWith(alloc: std.mem.Allocator, source: []const u8, kvs: []const struct { key: []const u8, value: Template.Value }) ![]u8 {
    var ctx = Template.Context.init(alloc);
    defer ctx.deinit();
    for (kvs) |kv| try ctx.put(kv.key, kv.value);
    return renderChecked(alloc, source, &ctx);
}

test "render: plain text passes through verbatim" {
    const out = try renderWith(testing.allocator, "hello world", &.{});
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("hello world", out);
}

test "render: variable substitution with string value" {
    const out = try renderWith(testing.allocator, "{{ name }}", &.{
        .{ .key = "name", .value = .{ .string = "World" } },
    });
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("World", out);
}

test "render: dotted path resolves nested map" {
    var ctx = Template.Context.init(testing.allocator);
    defer ctx.deinit();
    var user = std.StringHashMap(Template.Value).init(testing.allocator);
    defer user.deinit();
    try user.put("name", .{ .string = "Alice" });
    try ctx.put("user", .{ .map = user });

    const out = try renderChecked(testing.allocator, "Hello, {{ user.name }}!", &ctx);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("Hello, Alice!", out);
}

test "render: missing variable resolves to empty string" {
    const out = try renderWith(testing.allocator, "[{{ undef }}]", &.{});
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("[]", out);
}

test "render: if true branch renders" {
    const out = try renderWith(testing.allocator, "{% if cond %}A{% endif %}", &.{
        .{ .key = "cond", .value = .{ .bool = true } },
    });
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("A", out);
}

test "render: if false branch with else renders else" {
    const out = try renderWith(testing.allocator, "{% if cond %}A{% else %}B{% endif %}", &.{
        .{ .key = "cond", .value = .{ .bool = false } },
    });
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("B", out);
}

test "render: if false without else renders empty" {
    const out = try renderWith(testing.allocator, "[{% if cond %}A{% endif %}]", &.{
        .{ .key = "cond", .value = .{ .bool = false } },
    });
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("[]", out);
}

test "render: for loop iterates array" {
    const items = [_]Template.Value{
        .{ .string = "a" },
        .{ .string = "b" },
        .{ .string = "c" },
    };
    const out = try renderWith(testing.allocator, "{% for x in items %}<{{ x }}>{% endfor %}", &.{
        .{ .key = "items", .value = .{ .array = &items } },
    });
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("<a><b><c>", out);
}

test "render: for empty array renders empty branch" {
    const items = [_]Template.Value{};
    const out = try renderWith(testing.allocator, "{% for x in items %}A{% empty %}B{% endfor %}", &.{
        .{ .key = "items", .value = .{ .array = &items } },
    });
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("B", out);
}

test "render: nested if inside for runs per iteration" {
    const items = [_]Template.Value{
        .{ .bool = true },
        .{ .bool = false },
        .{ .bool = true },
    };
    const out = try renderWith(testing.allocator, "{% for x in items %}{% if x %}Y{% else %}N{% endif %}{% endfor %}", &.{
        .{ .key = "items", .value = .{ .array = &items } },
    });
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("YNY", out);
}

test "render: {{ var }} HTML-escapes by default" {
    const out = try renderWith(testing.allocator, "{{ v }}", &.{
        .{ .key = "v", .value = .{ .string = "<script>alert(1)</script>" } },
    });
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("&lt;script&gt;alert(1)&lt;/script&gt;", out);
}

test "render: {% raw %} passes through verbatim without escaping" {
    const out = try renderWith(testing.allocator, "{% raw %}<b>{{ not parsed }}</b>{% endraw %}", &.{});
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("<b>{{ not parsed }}</b>", out);
}

test "render: for over non-array (missing key) renders empty branch" {
    const out = try renderWith(testing.allocator, "{% for x in items %}A{% empty %}B{% endfor %}", &.{});
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("B", out);
}

test "render: index access via bracket notation" {
    const items = [_]Template.Value{
        .{ .string = "first" },
        .{ .string = "second" },
    };
    const out = try renderWith(testing.allocator, "{{ items[0] }}", &.{
        .{ .key = "items", .value = .{ .array = &items } },
    });
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("first", out);
}

// =============================================================================
//  Task 4 — Inheritance
// =============================================================================
//
// `compileWithParent` takes a child source and a loader, and merges the
// child's block bodies into the parent's AST. The result is a single
// AST that, when rendered, produces the parent's HTML with the child's
// blocks substituted in.
//
// For testing, the loader is a simple map from path → source.

const TestLoader = struct {
    files: std.StringHashMap([]const u8),

    fn load(ctx: *anyopaque, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
        const self: *TestLoader = @ptrCast(@alignCast(ctx));
        const source = self.files.get(path) orelse return error.TemplateNotFound;
        // Return a heap-allocated copy so the caller can own it.
        return try allocator.dupe(u8, source);
    }

    fn deinit(self: *TestLoader) void {
        self.files.deinit();
    }
};

fn compileWithParent(
    alloc: std.mem.Allocator,
    source: []const u8,
    loader_ctx: *anyopaque,
    loader_fn: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator, path: []const u8) anyerror![]u8,
) ![]Template.Node {
    return Template.compileWithParent(alloc, source, loader_ctx, loader_fn);
}

fn renderInherit(alloc: std.mem.Allocator, source: []const u8, ctx: *Template.Context, loader_ctx: *anyopaque, loader_fn: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator, path: []const u8) anyerror![]u8) ![]u8 {
    const nodes = try compileWithParent(alloc, source, loader_ctx, loader_fn);
    defer Template.freeNodes(alloc, nodes);
    return try Template.render(alloc, nodes, ctx);
}

test "inherit: child overrides one block → child body replaces parent body" {
    var files = std.StringHashMap([]const u8).init(testing.allocator);
    defer files.deinit();
    try files.put("base.jinja",
        \\<html>
        \\<head><title>{% block title %}Default{% endblock %}</title></head>
        \\<body>{% block content %}default body{% endblock %}</body>
        \\</html>
    );
    const child =
        \\{% extends "base.jinja" %}
        \\{% block content %}Hello, World!{% endblock %}
    ;
    var loader = TestLoader{ .files = files };
    var ctx = Template.Context.init(testing.allocator);
    defer ctx.deinit();
    const out = try renderInherit(testing.allocator, child, &ctx, &loader, &TestLoader.load);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(
        "<html>\n<head><title>Default</title></head>\n<body>Hello, World!</body>\n</html>",
        out,
    );
}

test "inherit: child overrides multiple blocks" {
    var files = std.StringHashMap([]const u8).init(testing.allocator);
    defer files.deinit();
    try files.put("base.jinja",
        \\<title>{% block title %}Default{% endblock %}</title>
        \\<h1>{% block header %}Default Header{% endblock %}</h1>
        \\<p>{% block body %}Default Body{% endblock %}</p>
    );
    const child =
        \\{% extends "base.jinja" %}
        \\{% block title %}My Title{% endblock %}
        \\{% block body %}My Body{% endblock %}
    ;
    var loader = TestLoader{ .files = files };
    var ctx = Template.Context.init(testing.allocator);
    defer ctx.deinit();
    const out = try renderInherit(testing.allocator, child, &ctx, &loader, &TestLoader.load);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("<title>My Title</title>\n<h1>Default Header</h1>\n<p>My Body</p>", out);
}

test "inherit: child doesn't override a block → parent default rendered" {
    var files = std.StringHashMap([]const u8).init(testing.allocator);
    defer files.deinit();
    try files.put("base.jinja",
        \\<h1>{% block header %}Parent Header{% endblock %}</h1>
        \\<p>{% block body %}Parent Body{% endblock %}</p>
    );
    const child =
        \\{% extends "base.jinja" %}
        \\{% block body %}Child Body{% endblock %}
    ;
    var loader = TestLoader{ .files = files };
    var ctx = Template.Context.init(testing.allocator);
    defer ctx.deinit();
    const out = try renderInherit(testing.allocator, child, &ctx, &loader, &TestLoader.load);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("<h1>Parent Header</h1>\n<p>Child Body</p>", out);
}

test "inherit: two-level (grandchild → child → base)" {
    var files = std.StringHashMap([]const u8).init(testing.allocator);
    defer files.deinit();
    try files.put("base.jinja",
        \\<title>{% block title %}Base{% endblock %}</title>
        \\<body>{% block content %}Base Body{% endblock %}</body>
    );
    try files.put("child.jinja",
        \\{% extends "base.jinja" %}
        \\{% block title %}Child Title{% endblock %}
    );
    const grandchild =
        \\{% extends "child.jinja" %}
        \\{% block content %}Grandchild Body{% endblock %}
    ;
    var loader = TestLoader{ .files = files };
    var ctx = Template.Context.init(testing.allocator);
    defer ctx.deinit();
    const out = try renderInherit(testing.allocator, grandchild, &ctx, &loader, &TestLoader.load);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("<title>Child Title</title>\n<body>Grandchild Body</body>", out);
}

test "inherit: child block body can use {{ var }} and {% if %}" {
    var files = std.StringHashMap([]const u8).init(testing.allocator);
    defer files.deinit();
    try files.put("base.jinja",
        \\<p>{% block greeting %}default{% endblock %}</p>
    );
    const child =
        \\{% extends "base.jinja" %}
        \\{% block greeting %}Hello, {{ name }}!{% endblock %}
    ;
    var loader = TestLoader{ .files = files };
    var ctx = Template.Context.init(testing.allocator);
    defer ctx.deinit();
    try ctx.put("name", .{ .string = "Alice" });
    const out = try renderInherit(testing.allocator, child, &ctx, &loader, &TestLoader.load);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("<p>Hello, Alice!</p>", out);
}
