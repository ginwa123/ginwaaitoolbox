const std = @import("std");
const json = std.json;
const Reader = std.Io.Reader;
const bashTool = @import("tools/bash.zig").bash_tool;
const bashMod = @import("tools/bash.zig");
const schemas = @import("tools/schemas.zig");
const BashInput = schemas.BashInput;
const ToolProperty = schemas.ToolProperty;
const ToolParameters = schemas.ToolParameters;
const AgentToolFunction = schemas.AgentToolFunction;
pub const AgentTool = schemas.AgentTool;
pub const prompt = @import("prompts.zig");
pub const LLMModels = @import("LLMModels.zig");
const helpers = @import("helpers");
const custom_http_client = @import("kabelweb").client;
// Leaf module (std-only) shared with the agentic loop — same cross-directory
// import `prompts.zig` already uses.
const args_repair = @import("../../agentic_loop/tools_args_repair.zig");

/// Log level for agent logging
const LogLevel = enum { err, warn, info, debug };

/// Get current timestamp in milliseconds since epoch
fn timestampMs(io: std.Io) i64 {
    return @intCast(@divTrunc(std.Io.Timestamp.now(io, .real).nanoseconds, 1_000_000));
}

/// Calculate elapsed time in milliseconds
fn elapsedMs(io: std.Io, start: i64) i64 {
    return timestampMs(io) - start;
}

/// Format duration for human-readable output
fn formatDuration(ms: i64) struct { value: i64, unit: []const u8 } {
    if (ms < 1000) return .{ .value = ms, .unit = "ms" };
    if (ms < 60000) return .{ .value = @divTrunc(ms, 1000), .unit = "s" };
    return .{ .value = @divTrunc(ms, 60000), .unit = "min" };
}

pub const UnresolvedIntentResult = struct {
    has_unresolved: bool,
    reason: ?[]const u8,
};

/// Content part types for multimodal messages (text, image_url, or video_url)
pub const ContentPart = struct {
    part_type: []const u8,
    text: ?[]const u8 = null,
    image_url: ?ImageUrl = null,
    video_url: ?VideoUrl = null,

    pub fn jsonStringify(self: @This(), stringify: *std.json.Stringify) !void {
        try stringify.beginObject();
        try stringify.objectField("type");
        try stringify.write(self.part_type);
        if (self.text) |t| {
            try stringify.objectField("text");
            try stringify.write(t);
        }
        if (self.image_url) |img| {
            try stringify.objectField("image_url");
            try img.jsonStringify(stringify);
        }
        if (self.video_url) |vid| {
            try stringify.objectField("video_url");
            try vid.jsonStringify(stringify);
        }
        try stringify.endObject();
    }
};

/// Image URL content for vision support
pub const ImageUrl = struct {
    url: ?[]const u8 = null,
    detail: ?[]const u8 = null,

    pub fn jsonStringify(self: @This(), stringify: *std.json.Stringify) !void {
        try stringify.beginObject();
        if (self.url) |u| {
            try stringify.objectField("url");
            try stringify.write(u);
        }
        if (self.detail) |d| {
            try stringify.objectField("detail");
            try stringify.write(d);
        }
        try stringify.endObject();
    }
};

/// Video URL content for video understanding.
/// Wire shape mirrors ImageUrl: `{ "video_url": { "url": "data:video/<mime>;base64,..." } }`
/// on OpenAI Chat, `{ "type": "input_video", "video_url": "..." }` on Responses,
/// `{ "type": "video", "source": {...} }` on Anthropic.
pub const VideoUrl = struct {
    url: ?[]const u8 = null,

    pub fn jsonStringify(self: @This(), stringify: *std.json.Stringify) !void {
        try stringify.beginObject();
        if (self.url) |u| {
            try stringify.objectField("url");
            try stringify.write(u);
        }
        try stringify.endObject();
    }
};

/// Allowlisted video MIME suffixes (after `data:video/`).
/// Locked 2026-09-18: full video/* v1 = mp4, webm, quicktime (mov),
/// x-msvideo (avi), x-matroska (mkv). Providers document mp4/webm/mov
/// natively; avi/mkv pass validation and fail at the provider with a
/// hard error (never silently dropped).
pub fn isSupportedVideoMime(mime: []const u8) bool {
    if (std.mem.eql(u8, mime, "video/mp4")) return true;
    if (std.mem.eql(u8, mime, "video/webm")) return true;
    if (std.mem.eql(u8, mime, "video/quicktime")) return true;
    if (std.mem.eql(u8, mime, "video/x-msvideo")) return true;
    if (std.mem.eql(u8, mime, "video/x-matroska")) return true;
    return false;
}

/// Extract the `video/<suffix>` mime from a `data:video/...;base64,...` URL.
/// Returns null when the URL is not a video data URL.
pub fn videoMimeFromDataUrl(url: []const u8) ?[]const u8 {
    const prefix = "data:video/";
    if (!std.mem.startsWith(u8, url, prefix)) return null;
    const after = url[prefix.len..];
    const sep = std.mem.indexOf(u8, after, ";base64,") orelse return null;
    if (sep == 0) return null;
    // Slice `video/<suffix>` out of the input (skip the `data:` scheme).
    return url["data:".len .. prefix.len + sep];
}

pub const ToolCall = struct {
    id: []const u8,
    type: []const u8 = "function",
    function: FunctionCall,
};

pub const FunctionCall = struct {
    name: []const u8,
    arguments: []const u8,
};

pub const FinishReason = enum {
    stop,
    length,
    tool_calls,
    content_filter,
    tool,
    null,
    assistant,
    /// Not a provider value: persisted by the agentic loop when a batch
    /// contained `ask_user`. The tool returned `<status>pending</status>`,
    /// the loop BROKE instead of looping back, and a new run will resume once
    /// the human answers. Added to the enum (rather than a free-form string
    /// like "cancelled") so any future exhaustive `switch` on a finish reason
    /// fails to compile until it handles this case.
    awaiting_user,

    pub fn from_str(s: ?[]const u8) ?FinishReason {
        if (s == null) return .null;
        const str = s.?;
        if (std.mem.eql(u8, str, "stop")) return .stop;
        if (std.mem.eql(u8, str, "length")) return .length;
        if (std.mem.eql(u8, str, "tool_calls")) return .tool_calls;
        if (std.mem.eql(u8, str, "content_filter")) return .content_filter;
        if (std.mem.eql(u8, str, "tool")) return .tool;
        if (std.mem.eql(u8, str, "assistant")) return .assistant;
        if (std.mem.eql(u8, str, "awaiting_user")) return .awaiting_user;
        return null;
    }

    pub fn to_str(self: FinishReason) []const u8 {
        return switch (self) {
            .stop => "stop",
            .length => "length",
            .tool_calls => "tool_calls",
            .content_filter => "content_filter",
            .tool => "tool",
            .null => "null",
            .assistant => "assistant",
            .awaiting_user => "awaiting_user",
        };
    }
};

const JsonFunctionCall = struct {
    name: []const u8,
    arguments: []const u8,
};

const JsonToolCall = struct {
    id: []const u8,
    type: []const u8 = "function",
    function: JsonFunctionCall,
};

const JsonMessage = struct {
    role: []const u8,
    content: ?[]const u8 = null,
    content_parts: ?[]const ContentPart = null,
    tool_calls: ?[]const JsonToolCall = null,
    tool_call_id: ?[]const u8 = null,
    reasoning_content: ?[]const u8 = null,

    pub fn jsonStringify(self: @This(), stringify: *std.json.Stringify) !void {
        try stringify.beginObject();
        try stringify.objectField("role");
        try stringify.write(self.role);
        if (self.content) |c| {
            try stringify.objectField("content");
            try stringify.write(c);
        } else if (self.content_parts) |parts| {
            try stringify.objectField("content");
            try stringify.write(parts);
        }
        if (self.tool_calls) |tc| {
            try stringify.objectField("tool_calls");
            try stringify.write(tc);
        }
        if (self.tool_call_id) |id| {
            try stringify.objectField("tool_call_id");
            try stringify.write(id);
        }
        if (self.reasoning_content) |rc| {
            try stringify.objectField("reasoning_content");
            try stringify.write(rc);
        }
        try stringify.endObject();
    }
};

const JsonToolParameters = struct {
    properties: []const ToolProperty,
    required: []const []const u8,

    pub fn jsonStringify(self: @This(), stringify: *std.json.Stringify) !void {
        try stringify.beginObject();
        try stringify.objectField("type");
        try stringify.write("object");
        try stringify.objectField("properties");
        try stringify.beginObject();
        for (self.properties) |prop| {
            try stringify.objectField(prop.name);
            try stringify.beginObject();
            try stringify.objectField("type");
            try stringify.write(prop.type);
            try stringify.objectField("description");
            try stringify.write(prop.description);
            try stringify.endObject();
        }
        try stringify.endObject();
        try stringify.objectField("required");
        try stringify.write(self.required);
        try stringify.endObject();
    }
};

const JsonToolFunction = struct {
    name: []const u8,
    description: []const u8,
    parameters: JsonToolParameters,
};

const JsonTool = struct {
    type: []const u8,
    function: JsonToolFunction,
};

const JsonThinkingConfig = struct {
    type: []const u8 = "disabled",
};

const JsonStreamOptions = struct {
    include_usage: bool,
};

const JsonRequest = struct {
    model: []const u8,
    enable_thinking: bool,
    thinking: ?JsonThinkingConfig = null,
    messages: []const JsonMessage,
    temperature: f32,
    max_tokens: usize,
    stream: bool,
    tools: ?[]const JsonTool = null,
    tool_choice: ?[]const u8 = null,

    /// Optional end-user identifier. Omitted from the JSON body when null
    /// or empty. Maps to OpenAI's `user` request-body parameter. See
    /// https://platform.openai.com/docs/api-reference/chat/create.
    user: ?[]const u8 = null,

    /// OpenAI-style reasoning effort (o1 / o3 / GPT-5 / DeepSeek-R1).
    /// One of "low" | "medium" | "high" | "auto". Mirrors the
    /// `Agent.reasoningEffort` field directly. Empty string is
    /// treated the same as null (field omitted from the wire).
    /// Anthropic-style URLs ignore this — they're routed through
    /// `buildJsonAnthropicRequest` which doesn't see this struct.
    /// See https://platform.openai.com/docs/guides/reasoning.
    reasoning_effort: ?[]const u8 = null,

    pub fn jsonStringify(self: @This(), stringify: *std.json.Stringify) !void {
        try stringify.beginObject();
        try stringify.objectField("model");
        try stringify.write(self.model);
        if (self.thinking) |th| {
            try stringify.objectField("thinking");
            try stringify.write(th);
        }
        try stringify.objectField("enable_thinking");
        try stringify.write(self.enable_thinking);
        try stringify.objectField("messages");
        try stringify.write(self.messages);
        try stringify.objectField("temperature");
        try stringify.write(self.temperature);
        try stringify.objectField("max_tokens");
        try stringify.write(self.max_tokens);
        if (self.stream) {
            try stringify.objectField("stream");
            try stringify.write(true);
            try stringify.objectField("stream_options");
            try stringify.write(.{ .include_usage = true });
        }
        if (self.tools) |t| {
            try stringify.objectField("tools");
            try stringify.write(t);
            try stringify.objectField("tool_choice");
            try stringify.write(self.tool_choice.?);
        }
        if (self.user) |u| {
            if (u.len > 0) {
                try stringify.objectField("user");
                try stringify.write(u);
            }
        }
        // reasoning_effort: only emitted when non-null AND non-empty.
        // The Agent struct's reasoningEffort field is borrowed from
        // the workflow's LlmConfig (process-lifetime singleton), so
        // it's safe to write verbatim — no aliasing concerns.
        if (self.reasoning_effort) |re| {
            if (re.len > 0) {
                try stringify.objectField("reasoning_effort");
                try stringify.write(re);
            }
        }
        try stringify.endObject();
    }
};

const AnthropicContentBlock = struct {
    text: ?[]const u8 = null,
    tool_use: ?AnthropicToolUse = null,
    tool_result: ?AnthropicToolResult = null,
    /// Anthropic vision image source. Wire shape:
    ///   { "type": "image",
    ///     "source": { "type": "url", "url": "<image-url-or-data-uri>" } }
    /// We also accept `data:image/<mime>;base64,<payload>` URLs and break
    /// them out into the Anthropic-native `source.type=base64` +
    /// `media_type` + `data` shape — that path is what strict
    /// Anthropic API gates validate. `data:` URL passthrough covers
    /// every OpenAI-compatible relay (e.g. api.minimax.io/anthropic);
    /// the explicit base64 split covers the canonical Anthropic API.
    image: ?AnthropicImage = null,
    video: ?AnthropicVideo = null,

    pub fn jsonStringify(self: @This(), stringify: *std.json.Stringify) !void {
        try stringify.beginObject();
        if (self.text) |t| {
            try stringify.objectField("type");
            try stringify.write("text");
            try stringify.objectField("text");
            try stringify.write(t);
        } else if (self.tool_use) |tu| {
            try stringify.objectField("type");
            try stringify.write("tool_use");
            try stringify.objectField("id");
            try stringify.write(tu.id);
            try stringify.objectField("name");
            try stringify.write(tu.name);
            try stringify.objectField("input");
            try stringify.write(tu.input);
        } else if (self.tool_result) |tr| {
            try stringify.objectField("type");
            try stringify.write("tool_result");
            try stringify.objectField("tool_use_id");
            try stringify.write(tr.tool_use_id);
            try stringify.objectField("content");
            try stringify.write(tr.content);
        } else if (self.image) |img| {
            try stringify.objectField("type");
            try stringify.write("image");
            try stringify.objectField("source");
            try img.jsonStringify(stringify);
        } else if (self.video) |vid| {
            try stringify.objectField("type");
            try stringify.write("video");
            try stringify.objectField("source");
            try vid.jsonStringify(stringify);
        }
        try stringify.endObject();
    }
};

const AnthropicImage = struct {
    /// Either "url" (for an `https://` URL or a `data:` URL) or
    /// "base64" (for a broken-out `media_type` + `data` payload).
    /// Matches Anthropic's `image.source.type` enum.
    source_type: []const u8,
    /// For `source_type = "url"`, the full URL or `data:` URI. For
    /// `source_type = "base64"`, the raw base64 payload.
    url_or_data: []const u8,
    /// Only populated when `source_type = "base64"`, e.g. "image/png".
    /// Null for `url` sources (Anthropic's strict API infers media_type
    /// from the URL extension; OpenAI-compatible relays don't care).
    media_type: ?[]const u8 = null,

    pub fn jsonStringify(self: @This(), stringify: *std.json.Stringify) !void {
        try stringify.beginObject();
        try stringify.objectField("type");
        try stringify.write(self.source_type);
        if (std.mem.eql(u8, self.source_type, "base64")) {
            try stringify.objectField("media_type");
            try stringify.write(self.media_type orelse "image/png");
            try stringify.objectField("data");
            try stringify.write(self.url_or_data);
        } else {
            try stringify.objectField("url");
            try stringify.write(self.url_or_data);
        }
        try stringify.endObject();
    }
};

/// Anthropic video source. Same `url` vs `base64` split as AnthropicImage,
/// but defaults to `video/mp4` and carries video mimes.
const AnthropicVideo = struct {
    source_type: []const u8,
    url_or_data: []const u8,
    media_type: ?[]const u8 = null,

    pub fn jsonStringify(self: @This(), stringify: *std.json.Stringify) !void {
        try stringify.beginObject();
        try stringify.objectField("type");
        try stringify.write(self.source_type);
        if (std.mem.eql(u8, self.source_type, "base64")) {
            try stringify.objectField("media_type");
            try stringify.write(self.media_type orelse "video/mp4");
            try stringify.objectField("data");
            try stringify.write(self.url_or_data);
        } else {
            try stringify.objectField("url");
            try stringify.write(self.url_or_data);
        }
        try stringify.endObject();
    }
};

const AnthropicToolUse = struct {
    id: []const u8,
    name: []const u8,
    input: std.json.Value,
};

const AnthropicToolResult = struct {
    tool_use_id: []const u8,
    content: []const u8,
};

const AnthropicMessageContent = union(enum) {
    single: struct {
        text: []const u8 = "",
    },
    array: []const AnthropicContentBlock,

    pub fn jsonStringify(self: @This(), stringify: *std.json.Stringify) !void {
        switch (self) {
            .single => |s| try stringify.write(s.text),
            .array => |arr| try stringify.write(arr),
        }
    }
};

const AnthropicMessage = struct {
    role: []const u8,
    content: AnthropicMessageContent,

    pub fn jsonStringify(self: @This(), stringify: *std.json.Stringify) !void {
        try stringify.beginObject();
        try stringify.objectField("role");
        try stringify.write(self.role);
        try stringify.objectField("content");
        try stringify.write(self.content);
        try stringify.endObject();
    }
};

const AnthropicThinking = struct {
    /// "enabled" (with budget_tokens) or "adaptive" (Anthropic picks
    /// its own budget — recommended for Sonnet 4.5+). Never
    /// "disabled" — when the agent wants thinking off, the entire
    /// `thinking` block is omitted from the request body, not
    /// serialized as `{type: "disabled"}`.
    type: []const u8,
    /// Required only when `type == "enabled"`. Minimum value is
    /// 1024 and it must be strictly less than `max_tokens` — the
    /// call site in `buildJsonAnthropicRequest` derives this from
    /// `Agent.thinkingBudgetTokens` (or the 50%-of-max heuristic),
    /// clamped to the [1024, max_tokens-1] range. Null when
    /// `type == "adaptive"`.
    budget_tokens: ?usize = null,

    pub fn jsonStringify(self: @This(), stringify: *std.json.Stringify) !void {
        try stringify.beginObject();
        try stringify.objectField("type");
        try stringify.write(self.type);
        if (self.budget_tokens) |bt| {
            try stringify.objectField("budget_tokens");
            try stringify.write(bt);
        }
        try stringify.endObject();
    }
};

const AnthropicToolInputSchema = struct {
    properties: []const ToolProperty,
    required: []const []const u8,

    pub fn jsonStringify(self: @This(), stringify: *std.json.Stringify) !void {
        try stringify.beginObject();
        try stringify.objectField("type");
        try stringify.write("object");
        try stringify.objectField("properties");
        try stringify.beginObject();
        for (self.properties) |prop| {
            try stringify.objectField(prop.name);
            try stringify.beginObject();
            try stringify.objectField("type");
            try stringify.write(prop.type);
            try stringify.objectField("description");
            try stringify.write(prop.description);
            try stringify.endObject();
        }
        try stringify.endObject();
        try stringify.objectField("required");
        try stringify.write(self.required);
        try stringify.endObject();
    }
};

const AnthropicTool = struct {
    name: []const u8,
    description: []const u8,
    input_schema: AnthropicToolInputSchema,

    pub fn jsonStringify(self: @This(), stringify: *std.json.Stringify) !void {
        try stringify.beginObject();
        try stringify.objectField("name");
        try stringify.write(self.name);
        try stringify.objectField("description");
        try stringify.write(self.description);
        try stringify.objectField("input_schema");
        try stringify.write(self.input_schema);
        try stringify.endObject();
    }
};

/// Anthropic `metadata` block. Currently only `user_id` is supported —
/// Anthropic's Messages API accepts arbitrary key/value metadata but
/// nalar only uses `user_id` for the LLM-API end-user identifier.
const AnthropicMetadata = struct {
    user_id: []const u8,

    pub fn jsonStringify(self: @This(), stringify: *std.json.Stringify) !void {
        try stringify.beginObject();
        try stringify.objectField("user_id");
        try stringify.write(self.user_id);
        try stringify.endObject();
    }
};

const AnthropicRequest = struct {
    model: []const u8,
    messages: []const AnthropicMessage,
    max_tokens: usize,
    stream: bool,
    tools: ?[]const AnthropicTool = null,
    thinking: ?AnthropicThinking = null,
    temperature: ?f32 = null,
    /// Top-level system prompt. Anthropic rejects `role: "system"`
    /// inside `messages` (400s) — system instructions belong here.
    /// Built by `buildJsonAnthropicRequest` from `params.messages`
    /// entries with `role == .system`. `null` when no system prompt
    /// is in scope (the field is omitted entirely from the wire).
    system: ?[]const u8 = null,

    /// Optional metadata block. Currently emits `{"user_id": "..."}`
    /// from `Agent.userIdentifier`. See
    /// https://docs.claude.com/en/api/messages.
    metadata: ?AnthropicMetadata = null,

    pub fn jsonStringify(self: @This(), stringify: *std.json.Stringify) !void {
        try stringify.beginObject();
        try stringify.objectField("model");
        try stringify.write(self.model);
        // Anthropic accepts `system` as a plain string or as an array
        // of content blocks; a string is sufficient for the
        // `role == .system` join the builder does today.
        if (self.system) |s| {
            try stringify.objectField("system");
            try stringify.write(s);
        }
        try stringify.objectField("messages");
        try stringify.write(self.messages);
        try stringify.objectField("max_tokens");
        try stringify.write(self.max_tokens);
        if (self.temperature) |t| {
            try stringify.objectField("temperature");
            try stringify.write(t);
        }
        if (self.thinking) |th| {
            try stringify.objectField("thinking");
            try stringify.write(th);
        }
        if (self.tools) |t| {
            try stringify.objectField("tools");
            try stringify.write(t);
        }
        if (self.stream) {
            try stringify.objectField("stream");
            try stringify.write(true);
            // NOTE: do NOT emit `stream_options` here. Anthropic has
            // no request-side toggle for usage tracking — usage
            // comes through SSE `message_start` / `message_delta`
            // events unconditionally. Emitting a `stream_options`
            // key (a copy-paste leftover from the OpenAI serializer)
            // would 400 against the strict Anthropic API.
        }
        if (self.metadata) |m| {
            try stringify.objectField("metadata");
            try stringify.write(m);
        }
        try stringify.endObject();
    }
};

/// --- OpenAI Responses API (url_style = "openai-response") -----------------
/// Request shape for POST /v1/responses  (https://developers.openai.com/api/reference/resources/responses)
/// Mirrors the chat completions feature set: model, input (messages), instructions (system),
/// max_output_tokens, stream, temperature, reasoning.effort, tools, tool_choice, user.
const ResponsesInputContent = struct {
    /// "input_text" | "input_image" | "input_video"
    content_type: []const u8,
    text: ?[]const u8 = null,
    image_url: ?[]const u8 = null,
    video_url: ?[]const u8 = null,
    detail: ?[]const u8 = null,

    pub fn jsonStringify(self: @This(), stringify: *std.json.Stringify) !void {
        try stringify.beginObject();
        try stringify.objectField("type");
        try stringify.write(self.content_type);
        if (std.mem.eql(u8, self.content_type, "input_text")) {
            if (self.text) |t| {
                try stringify.objectField("text");
                try stringify.write(t);
            }
        } else if (std.mem.eql(u8, self.content_type, "input_image")) {
            if (self.image_url) |u| {
                try stringify.objectField("image_url");
                try stringify.write(u);
            }
            if (self.detail) |d| {
                try stringify.objectField("detail");
                try stringify.write(d);
            }
        } else if (std.mem.eql(u8, self.content_type, "input_video")) {
            if (self.video_url) |u| {
                try stringify.objectField("video_url");
                try stringify.write(u);
            }
        } else {
            if (self.text) |t| {
                try stringify.objectField("text");
                try stringify.write(t);
            }
        }
        try stringify.endObject();
    }
};

const ResponsesReasoningSummary = struct {
    type: []const u8 = "summary_text",
    text: []const u8,

    pub fn jsonStringify(self: @This(), stringify: *std.json.Stringify) !void {
        try stringify.beginObject();
        try stringify.objectField("type");
        try stringify.write(self.type);
        try stringify.objectField("text");
        try stringify.write(self.text);
        try stringify.endObject();
    }
};

const ResponsesInputItem = struct {
    /// "message" | "function_call" | "function_call_output" | "reasoning"
    item_type: []const u8,
    role: ?[]const u8 = null,
    content: ?[]const ResponsesInputContent = null,
    call_id: ?[]const u8 = null,
    name: ?[]const u8 = null,
    arguments: ?[]const u8 = null,
    output: ?[]const u8 = null,
    id: ?[]const u8 = null,
    summary: ?[]const ResponsesReasoningSummary = null,
    encrypted_content: ?[]const u8 = null,

    pub fn jsonStringify(self: @This(), stringify: *std.json.Stringify) !void {
        try stringify.beginObject();
        try stringify.objectField("type");
        try stringify.write(self.item_type);
        if (std.mem.eql(u8, self.item_type, "reasoning")) {
            if (self.id) |rid| {
                if (rid.len > 0) {
                    try stringify.objectField("id");
                    try stringify.write(rid);
                }
            }
            if (self.summary) |s| {
                try stringify.objectField("summary");
                try stringify.write(s);
            }
            if (self.encrypted_content) |ec| {
                if (ec.len > 0) {
                    try stringify.objectField("encrypted_content");
                    try stringify.write(ec);
                }
            }
        } else if (std.mem.eql(u8, self.item_type, "message")) {
            if (self.role) |r| {
                try stringify.objectField("role");
                try stringify.write(r);
            }
            if (self.content) |c| {
                try stringify.objectField("content");
                try stringify.write(c);
            }
        } else if (std.mem.eql(u8, self.item_type, "function_call")) {
            if (self.call_id) |cid| {
                try stringify.objectField("call_id");
                try stringify.write(cid);
            }
            if (self.name) |n| {
                try stringify.objectField("name");
                try stringify.write(n);
            }
            if (self.arguments) |a| {
                try stringify.objectField("arguments");
                try stringify.write(a);
            }
        } else if (std.mem.eql(u8, self.item_type, "function_call_output")) {
            if (self.call_id) |cid| {
                try stringify.objectField("call_id");
                try stringify.write(cid);
            }
            if (self.output) |o| {
                try stringify.objectField("output");
                try stringify.write(o);
            }
        }
        try stringify.endObject();
    }
};

const ResponsesToolParameters = struct {
    properties: []const ToolProperty,
    required: []const []const u8,

    pub fn jsonStringify(self: @This(), stringify: *std.json.Stringify) !void {
        try stringify.beginObject();
        try stringify.objectField("type");
        try stringify.write("object");
        try stringify.objectField("properties");
        try stringify.beginObject();
        for (self.properties) |prop| {
            try stringify.objectField(prop.name);
            try stringify.beginObject();
            try stringify.objectField("type");
            try stringify.write(prop.type);
            try stringify.objectField("description");
            try stringify.write(prop.description);
            try stringify.endObject();
        }
        try stringify.endObject();
        try stringify.objectField("required");
        try stringify.write(self.required);
        try stringify.endObject();
    }
};

const ResponsesTool = struct {
    type: []const u8 = "function",
    name: []const u8,
    description: []const u8,
    parameters: ResponsesToolParameters,
    strict: ?bool = null,

    pub fn jsonStringify(self: @This(), stringify: *std.json.Stringify) !void {
        try stringify.beginObject();
        try stringify.objectField("type");
        try stringify.write(self.type);
        try stringify.objectField("name");
        try stringify.write(self.name);
        try stringify.objectField("description");
        try stringify.write(self.description);
        try stringify.objectField("parameters");
        try stringify.write(self.parameters);
        if (self.strict) |s| {
            try stringify.objectField("strict");
            try stringify.write(s);
        }
        try stringify.endObject();
    }
};

const ResponsesReasoning = struct {
    effort: []const u8,

    pub fn jsonStringify(self: @This(), stringify: *std.json.Stringify) !void {
        try stringify.beginObject();
        try stringify.objectField("effort");
        try stringify.write(self.effort);
        try stringify.endObject();
    }
};

const ResponsesRequest = struct {
    model: []const u8,
    input: []const ResponsesInputItem,
    instructions: ?[]const u8 = null,
    max_output_tokens: usize,
    stream: bool,
    temperature: ?f32 = null,
    reasoning: ?ResponsesReasoning = null,
    tools: ?[]const ResponsesTool = null,
    tool_choice: ?[]const u8 = null,
    store: bool = false,
    user: ?[]const u8 = null,

    pub fn jsonStringify(self: @This(), stringify: *std.json.Stringify) !void {
        try stringify.beginObject();
        try stringify.objectField("model");
        try stringify.write(self.model);
        if (self.instructions) |ins| {
            try stringify.objectField("instructions");
            try stringify.write(ins);
        }
        try stringify.objectField("input");
        try stringify.write(self.input);
        try stringify.objectField("max_output_tokens");
        try stringify.write(self.max_output_tokens);
        if (self.temperature) |t| {
            try stringify.objectField("temperature");
            try stringify.write(t);
        }
        if (self.reasoning) |r| {
            try stringify.objectField("reasoning");
            try stringify.write(r);
        }
        if (self.tools) |t| {
            try stringify.objectField("tools");
            try stringify.write(t);
            if (self.tool_choice) |tc| {
                try stringify.objectField("tool_choice");
                try stringify.write(tc);
            }
        }
        if (self.stream) {
            try stringify.objectField("stream");
            try stringify.write(true);
        }
        // store=false keeps the API stateless like chat/completions (no previous_response_id)
        try stringify.objectField("store");
        try stringify.write(self.store);
        if (self.user) |u| {
            if (u.len > 0) {
                try stringify.objectField("user");
                try stringify.write(u);
            }
        }
        try stringify.endObject();
    }
};

pub const AgentResponse = struct {
    choices: []Choice,
};

pub const Choice = struct {
    index: usize = 0,
    message: Message,
    finish_reason: ?FinishReason = null,
};

pub const Message = struct {
    role: []const u8 = "assistant",
    content: ?[]const u8 = null,
    tool_calls: ?[]ToolCall = null,
    reasoning_content: ?[]const u8 = null,
};

pub const Role = enum {
    system,
    user,
    assistant,
    tool,

    pub fn from_str(s: []const u8) ?Role {
        if (std.mem.eql(u8, s, "system")) return .system;
        if (std.mem.eql(u8, s, "user")) return .user;
        if (std.mem.eql(u8, s, "assistant")) return .assistant;
        if (std.mem.eql(u8, s, "tool")) return .tool;
        return null;
    }

    pub fn to_str(self: Role) []const u8 {
        return switch (self) {
            .system => "system",
            .user => "user",
            .assistant => "assistant",
            .tool => "tool",
        };
    }
};

pub const AgentMessage = struct {
    /// DB primary key from `llm_history.id` (19-digit timestamp string).
    /// NULL for messages synthesized in-memory (e.g. system prompts at
    /// workflow.zig:1046-1064). Populated by
    /// `transform_llm_history_to_agent_message` for messages loaded from
    /// the DB. Used by `buildCompactionEnvelope` to embed real ids in
    /// the `<compact_messages>` envelope so `read_workspace_session`
    /// can find them.
    id: ?[]const u8 = null,
    role: Role,
    content: ?[]const u8,
    content_parts: ?[]const ContentPart = null,
    tool_calls: ?[]ToolCall = null,
    tool_call_id: ?[]const u8 = null,
    reasoning_content: ?[]const u8 = null,
    reasoning_id: ?[]const u8 = null,
    reasoning_encrypted_content: ?[]const u8 = null,

    pub fn deinit(self: *const AgentMessage, allocator: std.mem.Allocator) void {
        if (self.id) |i| allocator.free(i);
        if (self.content) |c| allocator.free(c);
        if (self.content_parts) |parts| {
            for (parts) |part| {
                if (part.text) |t| allocator.free(t);
                if (part.image_url) |img| {
                    if (img.url) |u| allocator.free(u);
                    if (img.detail) |d| allocator.free(d);
                }
                if (part.video_url) |vid| {
                    if (vid.url) |u| allocator.free(u);
                }
            }
            allocator.free(parts);
        }
        if (self.tool_call_id) |id| allocator.free(id);
        if (self.reasoning_content) |rc| allocator.free(rc);
        if (self.reasoning_id) |rid| allocator.free(rid);
        if (self.reasoning_encrypted_content) |rec| allocator.free(rec);
        if (self.tool_calls) |tc| {
            for (tc) |*tool_call| {
                allocator.free(tool_call.id);
                allocator.free(tool_call.function.name);
                allocator.free(tool_call.function.arguments);
            }
            allocator.free(tc);
        }
    }
};

pub const Usage = struct {
    prompt_tokens: usize = 0,
    completion_tokens: usize = 0,
    total_tokens: usize = 0,
    /// Anthropic-only: tokens used to write a cache entry on this call.
    /// Billed at the cache-write rate (typically ~1.25× input rate), so
    /// DO add this to any billing formula. 0 for non-Anthropic profiles.
    cache_creation_input_tokens: usize = 0,
    /// Anthropic-only: tokens read from a cache entry on this call.
    /// Billed at the cache-read rate (typically ~0.1× input rate) — but
    /// still tokens the model processed, so this IS included in
    /// `prompt_tokens` and `total_tokens` (matching OpenAI's semantic
    /// of "tokens the LLM saw"). 0 for non-Anthropic profiles.
    cache_read_input_tokens: usize = 0,
};

pub const ToolCallDelta = struct {
    index: usize,
    id: ?[]const u8 = null,
    function_name: ?[]const u8 = null,
    function_arguments: ?[]const u8 = null,
};

pub const StreamChunk = struct {
    content: ?[]const u8 = null,
    reasoning_content: ?[]const u8 = null,
    reasoning_id: ?[]const u8 = null,
    reasoning_encrypted_content: ?[]const u8 = null,
    tool_calls_delta: ?[]const ToolCallDelta = null,
    finish_reason: ?FinishReason = null,
    usage: ?Usage = null,
    done: bool = false,
};

pub const StreamCallback = *const fn (ctx: ?*anyopaque, chunk: StreamChunk) void;

pub const StreamingAggregator = struct {
    allocator: std.mem.Allocator,
    content: std.ArrayList(u8),
    reasoning_content: std.ArrayList(u8),
    reasoning_id: ?[]const u8 = null,
    reasoning_encrypted_content: ?[]const u8 = null,
    finish_reason: ?FinishReason = null,
    usage: Usage = .{},

    // Per-LLM-tool-call intermediate buffer. The `id` + `name` slices
    // and the `arguments.items` ArrayList all live on `self.allocator`
    // (the caller's arena, which is also the arena passed to
    // `Agent.init(allocator, …)`). The `finalize` method hands the
    // arena-allocated `[]ToolCall` slice headers back to the caller
    // unchanged — the arena owns the lifetime wholesale.
    //
    // Note: the legacy `tool_calls: std.ArrayList(ToolCall)` field is
    // gone. The pre-fix code wrote tool calls to BOTH `tool_calls` AND
    // `tool_call_buffers` (via `tool_calls.append` here + populate-
    // buffer in `process_chunk`), then read `tool_calls.items` inside
    // `finalize` to dup each entry AGAIN into `tool_calls_copy`. That
    // 2-deep-dup pattern is what produced the 2026-08-15 "bash tool
    // leak" — see the `CallResponse.deinit` doc for the full story.
    tool_call_buffers: std.AutoHashMap(usize, struct {
        id: ?[]const u8 = null,
        name: ?[]const u8 = null,
        arguments: std.ArrayList(u8),
    }),

    pub fn init(allocator: std.mem.Allocator) StreamingAggregator {
        return .{
            .allocator = allocator,
            .content = .empty,
            .reasoning_content = .empty,
            .tool_call_buffers = .init(allocator),
        };
    }

    /// NO-OP. Lifetime is arena-owned by the caller (see `CallResponse`
    /// doc). Kept as a `pub fn` so existing `defer aggregator.deinit()`
    /// call sites stay valid — but the body does nothing now.
    ///
    /// Pre-fix code free'd `tool_call_buffers` hash-map values one by one
    /// (`id`, `name`, `arguments` ArrayList), then called
    /// `tool_call_buffers.deinit()`. Under the arena allocator that's
    /// wasted work; under `testing.allocator` it actively corrupts state
    /// (see 2026-08-15 "bash tool leak" bug — the same pattern repeated
    /// in `CallResponse.deinit` is what produced 0xAA-poisoned slice
    /// headers that reached the bash tool as `ls -la $'\xaa…'`).
    pub fn deinit(_: *StreamingAggregator) void {}

    pub fn process_chunk(self: *StreamingAggregator, chunk: StreamChunk) !void {
        if (chunk.done) return;

        if (chunk.content) |c| {
            try self.content.appendSlice(self.allocator, c);
        }
        if (chunk.reasoning_content) |rc| {
            // Terminal chunks (finish_reason or reasoning_id present) carry
            // summary[] as fallback — only use if no delta reasoning arrived.
            const is_terminal = chunk.finish_reason != null or chunk.reasoning_id != null or chunk.reasoning_encrypted_content != null;
            if (is_terminal) {
                if (self.reasoning_content.items.len == 0 and rc.len > 0) {
                    try self.reasoning_content.appendSlice(self.allocator, rc);
                }
            } else {
                try self.reasoning_content.appendSlice(self.allocator, rc);
            }
        }

        if (chunk.tool_calls_delta) |deltas| {
            for (deltas) |delta| {
                const gop = try self.tool_call_buffers.getOrPut(delta.index);
                if (!gop.found_existing) {
                    gop.value_ptr.* = .{
                        .id = null,
                        .name = null,
                        .arguments = .empty,
                    };
                }
                if (delta.id) |id| {
                    if (gop.value_ptr.id) |old| self.allocator.free(old);
                    gop.value_ptr.id = try self.allocator.dupe(u8, id);
                }
                if (delta.function_name) |name| {
                    if (gop.value_ptr.name) |old| self.allocator.free(old);
                    gop.value_ptr.name = try self.allocator.dupe(u8, name);
                }
                if (delta.function_arguments) |args| {
                    try gop.value_ptr.arguments.appendSlice(self.allocator, args);
                }
            }
        }

        if (chunk.reasoning_id) |rid| {
            if (self.reasoning_id) |old| self.allocator.free(old);
            self.reasoning_id = try self.allocator.dupe(u8, rid);
        }
        if (chunk.reasoning_encrypted_content) |rec| {
            if (self.reasoning_encrypted_content) |old| self.allocator.free(old);
            self.reasoning_encrypted_content = try self.allocator.dupe(u8, rec);
        }

        if (chunk.finish_reason) |fr| {
            self.finish_reason = fr;
        }

        if (chunk.usage) |usage| {
            if (usage.total_tokens > 0) {
                self.usage = usage;
            }
        }
    }

    pub fn finalize(self: *StreamingAggregator) !CallResponse {
        var sorted_indices: std.ArrayList(usize) = .empty;
        defer sorted_indices.deinit(self.allocator);

        var iter = self.tool_call_buffers.iterator();
        while (iter.next()) |entry| {
            try sorted_indices.append(self.allocator, entry.key_ptr.*);
        }
        std.sort.pdq(usize, sorted_indices.items, {}, std.sort.asc(usize));

        // Allocate the final `[]ToolCall` slice ONCE on `self.allocator`
        // (the caller's arena) and copy each inner slice header into it.
        // The inner slices (id, function.name, function.arguments) come
        // straight from `tool_call_buffers` — they were `dupe`d into
        // `self.allocator` during `process_chunk`, so they already live on
        // the same arena. No second dupe pass needed.
        //
        // This replaces the previous 2-deep-dup pattern (which duped into
        // `self.tool_calls`, then duped AGAIN into `tool_calls_copy`),
        // each duplication creating another slice header with an arena
        // pointer that the previous production code tried to `free` one
        // at a time — see the 2026-08-15 "bash tool leak" bug where the
        // defer ordering left a dangling `tool_call.function.arguments`
        // slice header that the bash tool then executed as a literal
        // `ls -la $'\xaa…'` shell command.
        var tool_calls_out: ?[]ToolCall = null;
        if (sorted_indices.items.len > 0) {
            const count = sorted_indices.items.len;
            const tool_call_slice = try self.allocator.alloc(ToolCall, count);
            var out_i: usize = 0;
            for (sorted_indices.items) |idx| {
                const buffer = self.tool_call_buffers.get(idx).?;
                if (buffer.id) |id| {
                    tool_call_slice[out_i] = .{
                        .id = id,
                        .function = .{
                            .name = if (buffer.name) |n| n else "",
                            .arguments = buffer.arguments.items,
                        },
                    };
                    out_i += 1;
                }
            }
            tool_calls_out = tool_call_slice[0..out_i];
        }

        var content_copy: ?[]const u8 = null;
        if (self.content.items.len > 0) {
            content_copy = try self.allocator.dupe(u8, std.mem.trim(u8, self.content.items, &std.ascii.whitespace));
        }

        var reasoning_copy: ?[]const u8 = null;
        if (self.reasoning_content.items.len > 0) {
            reasoning_copy = try self.allocator.dupe(u8, self.reasoning_content.items);
        }

        var reasoning_id_copy: ?[]const u8 = null;
        if (self.reasoning_id) |rid| {
            reasoning_id_copy = try self.allocator.dupe(u8, rid);
        }
        var reasoning_enc_copy: ?[]const u8 = null;
        if (self.reasoning_encrypted_content) |rec| {
            reasoning_enc_copy = try self.allocator.dupe(u8, rec);
        }

        return .{
            .allocator = self.allocator,
            .content = content_copy,
            .tool_calls = tool_calls_out,
            .finish_reason = self.finish_reason,
            .reasoning_content = reasoning_copy,
            .reasoning_id = reasoning_id_copy,
            .reasoning_encrypted_content = reasoning_enc_copy,
            .usage = self.usage,
        };
    }
};

pub const AgentCall = struct {
    tools: []const AgentTool,
    messages: []const AgentMessage,
    temperature: ?f32 = null,
    max_tokens: ?usize = null,
    /// Polled between SSE chunks so a caller can abort an in-flight turn.
    /// When it returns true, `callStreaming` cancels the HTTP transfer and
    /// returns `error.Cancelled` instead of reading the response to
    /// completion — see the cancel check in the chunk-read loop.
    ///
    /// A function pointer (rather than a flag or a DB handle) keeps the
    /// dependency direction caller → agent: the agent module must not import
    /// the workflow's config/sqlite helpers. Same shape as the existing
    /// `cancel_fn` used for the MCP tools fetch.
    cancel_fn: ?*const fn () bool = null,
};

pub const HttpOptions = struct {
    /// Overall deadline for the entire streaming read (response head + body).
    /// Triggers `error.StreamTimeout` if exceeded. Default 5 minutes.
    read_timeout_ms: u32 = 300_000,
    /// Idle window: if no new bytes arrive for this long after readSliceShort
    /// returns, the stream is considered hung. With TCP keepalive set to ~25s,
    /// keep this comfortably above the keepalive window so keepalive probes
    /// have time to fire and return an error (StreamInterrupted) before this
    /// deadline (StreamIdleTimeout) triggers. Hard floor: 30_000 (1.2× the
    /// ~25s keepalive window).
    ///
    /// Raised from 60_000 (2026-06-28) to 180_000 to accommodate reasoning
    /// models (Claude with extended thinking, OpenAI o1/o3, DeepSeek R1,
    /// Qwen QwQ) that routinely pause for tens of seconds to minutes
    /// between SSE chunks while reasoning internally. The previous 60s
    /// default fired StreamIdleTimeout on perfectly healthy streams.
    idle_timeout_ms: u32 = 180_000,
    /// Buffer size for reading HTTP response body
    response_buffer_size: usize = 256 * 1024,
    /// Buffer size for HTTP headers
    header_buffer_size: usize = 16 * 1024,
};

pub const CallResponse = struct {
    allocator: std.mem.Allocator,
    content: ?[]const u8,
    tool_calls: ?[]ToolCall,
    finish_reason: ?FinishReason,
    reasoning_content: ?[]const u8 = null,
    reasoning_id: ?[]const u8 = null,
    reasoning_encrypted_content: ?[]const u8 = null,
    usage: Usage = .{},

    pub fn deinit(self: *const CallResponse) void {
        if (self.content) |c| self.allocator.free(c);
        if (self.reasoning_content) |rc| self.allocator.free(rc);
        if (self.reasoning_id) |rid| self.allocator.free(rid);
        if (self.reasoning_encrypted_content) |rec| self.allocator.free(rec);
        if (self.tool_calls) |tc| {
            for (tc) |*tool_call| {
                self.allocator.free(tool_call.id);
                self.allocator.free(tool_call.function.name);
                self.allocator.free(tool_call.function.arguments);
            }
            self.allocator.free(tc);
        }
    }
};

pub const Agent = struct {
    name: []const u8 = "",
    apiKey: []const u8 = "",
    baseUrl: []const u8 = "",
    model: []const u8 = "",
    temperature: f32 = 0.4,
    maxTokens: usize = 4096,
    client: custom_http_client.Client,
    io: std.Io,
    thinkingEnabled: bool = true,
    /// Anthropic-only: override for `thinking.budget_tokens`. When set,
    /// `buildJsonAnthropicRequest` uses it directly (clamped to >=1024
    /// and <max_tokens). When null AND `thinkingAdaptive` is true
    /// (user picked "auto"), the request emits Anthropic's
    /// `type: "adaptive"` mode and lets the model pick its own budget
    /// (Sonnet 4.5+ recommendation). When null AND `thinkingAdaptive`
    /// is false, the request falls back to the 50%-of-max_tokens
    /// heuristic. OpenAI-style URLs ignore this field — they use
    /// `reasoningEffort` instead. Plan 2026-08-23-model-thinking.
    thinkingBudgetTokens: ?u32 = null,
    /// Anthropic-only: when true AND `thinkingBudgetTokens` is null,
    /// `buildJsonAnthropicRequest` emits `thinking: {type: "adaptive"}`
    /// instead of the 50%-of-max heuristic. The workflow sets this
    /// from `profile.thinking == "auto"`. OpenAI-style URLs ignore
    /// this field.
    thinkingAdaptive: bool = false,
    /// OpenAI-style reasoning effort knob (o1 / o3 / GPT-5 /
    /// DeepSeek-R1). One of "low" | "medium" | "high" | "auto".
    /// Emitted verbatim into the request body's `reasoning_effort`
    /// field by `buildJsonOpenAIRequest`. When null, the field is
    /// omitted (model-default reasoning). Anthropic-style URLs
    /// ignore this field entirely. The slice BORROWS from the
    /// workflow's `LlmConfig` singleton — safe for the duration of
    /// one LLM call (the per-iteration arena doesn't own it).
    reasoningEffort: ?[]const u8 = null,
    allocator: std.mem.Allocator,
    httpOptions: HttpOptions = .{},
    UrlStyle: []const u8 = "openai",
    userIdentifier: []const u8 = "AnakMagang",
    /// Stable per-conversation session id for OpenCode Go / Zen routing.
    /// Sent as the `x-opencode-session` HTTP header on every LLM request
    /// when non-empty. See https://opencode.ai/docs/go/#where-can-i-use-it
    /// ("Send a stable session ID in `x-opencode-session` for each
    /// conversation so we can optimize routing and prompt caching").
    /// Without it Console Go answers with
    /// `{"type":"error","error":{"type":"MissingSessionID",...}}` on a
    /// 200 SSE stream, which surfaces here as
    /// "stream ended without finish_reason after 0 chunk(s)".
    /// BORROWED slice — the workflow sets it from `copy_session_id`
    /// (per-iteration arena) for the duration of one `callStreaming`.
    sessionId: []const u8 = "",
    /// Most recent server/transporter error detail (e.g. the JSON error body
    /// the LLM provider returned for HTTP >=400, or a synthesized reason for
    /// mid-stream failures like scanner errors / missing finish_reason).
    /// Heap-allocated via `self.allocator`; freed by `deinit()`. Survives
    /// only until the next `callStreaming` call or `deinit()`. Workflow
    /// reads this in its retry-catch block to log WHY the call failed —
    /// without it we only see error names like "ApiError" /
    /// "StreamInterrupted" and have no way to distinguish a rate limit
    /// from an auth failure from a transport glitch.
    last_error_message: ?[]const u8 = null,

    /// Anthropic-only: cached input_tokens from the `message_start` event.
    /// Emitted on the first `content_block_delta` chunk so the aggregator
    /// sees a single usage event (mirrors how the OpenAI parser uses
    /// `stream_options.include_usage=true` to get a trailing usage chunk).
    /// Reset to 0 at the top of every `callStreaming` invocation.
    _anthropic_input_tokens: u32 = 0,
    /// Anthropic-only: guard so the cached input_tokens are sent exactly
    /// once per call (on the first delta). Reset to false at the top of
    /// every `callStreaming` invocation.
    _anthropic_usage_emitted: bool = false,
    /// Anthropic-only: cached `cache_read_input_tokens` from message_start.
    /// Some relays send the cache-read count at message_start but not at
    /// message_delta — keep it around so the first-delta usage chunk can
    /// fold it into `prompt_tokens`. Reset to 0 at the top of every
    /// `callStreaming` invocation.
    _anthropic_cache_read_tokens: u32 = 0,
    /// Anthropic-only: cached `cache_creation_input_tokens` from
    /// message_start. The strict API sends the cache-write count only
    /// at message_delta, but some relays include it earlier. Reset to
    /// 0 at the top of every `callStreaming` invocation.
    _anthropic_cache_creation_tokens: u32 = 0,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) Agent {
        return Agent{
            .allocator = allocator,
            .io = io,
            .client = custom_http_client.Client.init(allocator),
        };
    }

    pub fn init_with_options(allocator: std.mem.Allocator, io: std.Io, options: HttpOptions) Agent {
        return Agent{
            .allocator = allocator,
            .io = io,
            .client = custom_http_client.Client.init(allocator),
            .httpOptions = options,
        };
    }

    pub fn log_msg(_: Agent, level: LogLevel, message: []const u8) void {
        std.debug.print("[{s}] {s}\n", .{ @tagName(level), message });
    }

    pub fn log_fmt(self: Agent, comptime level: LogLevel, comptime fmt: []const u8, args: anytype) void {
        const msg = std.fmt.allocPrint(self.allocator, fmt, args) catch {
            std.debug.print("fmt alloc failed\n", .{});
            return;
        };
        defer self.allocator.free(msg);
        self.log_msg(level, msg);
    }

    pub fn log_error(self: Agent, operation: []const u8, err: anyerror, detail: ?[]const u8) void {
        if (detail) |d| {
            self.log_fmt(.err, "{s} failed: {s} - {s}", .{ operation, @errorName(err), d });
        } else {
            self.log_fmt(.err, "{s} failed: {s}", .{ operation, @errorName(err) });
        }
    }

    pub fn log_api_error(self: Agent, operation: []const u8, err: anyerror, body: []const u8) void {
        const max_body_len = 500;
        const truncated = body.len > max_body_len;
        const body_to_log = if (truncated) body[0..max_body_len] else body;
        if (truncated) {
            self.log_fmt(.err, "{s} failed: {s}\nResponse (truncated): {s}...", .{ operation, @errorName(err), body_to_log });
        } else {
            self.log_fmt(.err, "{s} failed: {s}\nResponse: {s}", .{ operation, @errorName(err), body_to_log });
        }
    }

    pub fn log_request(self: Agent, method: []const u8, url: []const u8, body_len: usize) void {
        self.log_fmt(.debug, "HTTP {s} {s} (body: {} bytes)", .{ method, url, body_len });
    }

    pub fn buildJsonAnthropicRequest(self: Agent, params: AgentCall, stream: bool) ![]u8 {
        const allocator = self.allocator;

        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const arena_alloc = arena.allocator();

        var total_content_size: usize = 0;
        for (params.messages) |msg| {
            if (msg.content) |c| total_content_size += c.len;
        }
        self.log_fmt(.debug, "ANTHROPIC_STATS: tools={d}, content={d}", .{
            params.tools.len, total_content_size,
        });

        const json_messages = try arena_alloc.alloc(AnthropicMessage, params.messages.len);
        // `params.messages` may contain entries with `role == .system`.
        // Anthropic rejects `role: "system"` inside `messages`, so we
        // join system-typed messages into a single top-level
        // `system` string and DROP them from `json_messages` (don't
        // count them in the allocation index).
        //
        // `json_message_count` is the live write index for
        // `json_messages`; it can be lower than
        // `params.messages.len` once system entries are filtered.
        // `system_text` accumulates the joined system prompt (arena-
        // backed; no manual free needed because the arena is torn
        // down by `defer arena.deinit()` at the top of this fn).
        var json_message_count: usize = 0;
        var system_text: std.ArrayList(u8) = .empty;
        for (params.messages) |msg| {
            if (msg.role == .system) {
                if (msg.content) |c| {
                    if (system_text.items.len > 0) {
                        try system_text.appendSlice(arena_alloc, "\n\n");
                    }
                    try system_text.appendSlice(arena_alloc, c);
                }
                continue; // skip — already joined into top-level "system"
            }
            if (msg.role == .assistant and msg.tool_calls != null) {
                var content_blocks: []AnthropicContentBlock = &.{};
                // NOTE: content_blocks is stored into
                // json_messages[json_message_count].content below and
                // must stay alive until the whole request has been
                // serialized by std.json.fmt in this function. It's
                // an arena allocation — the arena is torn down by
                // the `defer arena.deinit()` above once this function
                // returns, so it must NOT be freed early here.
                // (Freeing it early via arena_alloc.free() would
                // rewind the arena's bump pointer and let it get
                // silently overwritten by later allocations in this
                // same function — e.g. the next message's content
                // blocks, or the tools array.)

                if (msg.reasoning_content) |rc| {
                    content_blocks = try arena_alloc.realloc(content_blocks, content_blocks.len + 1);
                    // CRITICAL: explicitly set ALL three optional fields. In
                    // Zig 0.16, `.{ .text = rc }` only initializes .text — the
                    // other fields stay as whatever was in the arena's
                    // uninitialized memory (0xAA debug poison from previous
                    // occupants), and `AnthropicContentBlock.jsonStringify`'s
                    // `if (self.text)` reads the poisoned bytes as a slice
                    // pointer → SEGV in utf8ValidateSlice.
                    content_blocks[content_blocks.len - 1] = .{
                        .text = rc,
                        .tool_use = null,
                        .tool_result = null,
                    };
                }

                for (msg.tool_calls.?) |tc| {
                    const input_value = blk: {
                        const parsed = std.json.parseFromSlice(std.json.Value, arena_alloc, tc.function.arguments, .{}) catch {
                            break :blk std.json.Value{ .null = {} };
                        };
                        break :blk parsed.value;
                    };
                    content_blocks = try arena_alloc.realloc(content_blocks, content_blocks.len + 1);
                    content_blocks[content_blocks.len - 1] = .{
                        .text = null,
                        .tool_use = .{
                            .id = tc.id,
                            .name = tc.function.name,
                            .input = input_value,
                        },
                        .tool_result = null,
                    };
                }

                json_messages[json_message_count] = .{
                    .role = "assistant",
                    .content = .{ .array = content_blocks },
                };
            } else if (msg.role == .tool) {
                const tool_content = try arena_alloc.alloc(AnthropicContentBlock, 1);
                tool_content[0] = .{
                    .text = null,
                    .tool_use = null,
                    .tool_result = .{
                        .tool_use_id = msg.tool_call_id orelse "",
                        .content = msg.content orelse "",
                    },
                };
                json_messages[json_message_count] = .{
                    .role = "user",
                    .content = .{ .array = tool_content },
                };
            } else {
                // User messages (or any role whose `content_parts`
                // carries multimodal content, e.g. an attached
                // image). We build an `AnthropicContentBlock` array
                // so the image survives onto the wire — previously
                // `buildJsonAnthropicRequest` only read `msg.content`
                // and silently dropped `content_parts`, which is why
                // `url_style: "anthropic"` profiles couldn't see
                // user-attached images.
                //
                // NOTE: system-typed messages are filtered out at
                // the top of this loop, so this branch only sees
                // user / assistant / tool roles here (the `tool`
                // branch above already handled tool).
                //
                // Anthropic API accepts `data:image/<mime>;base64,...`
                // URLs as `source: { type: "url", url: "data:..." }`,
                // and most OpenAI-compatible relays (e.g.
                // `api.minimax.io/anthropic`) accept this too. The
                // strict Anthropic API also wants
                //   { source: { type: "base64", media_type, data } }
                // for larger payloads — if a relay rejects the URL
                // form we'll detect it from the server error and add
                // the split path in a follow-up. For the common
                // clipboard-paste / FileReader small-image flow the
                // URL form is fine.
                const parts = msg.content_parts;
                const has_parts = parts != null and parts.?.len > 0;
                if (has_parts) {
                    var non_assistant_blocks: []AnthropicContentBlock = &.{};
                    // Contents live until `defer arena.deinit()` (top of fn)
                    // — same lifetime as the assistant branch's blocks.
                    const part_count = parts.?.len;
                    non_assistant_blocks = try arena_alloc.alloc(
                        AnthropicContentBlock,
                        part_count,
                    );
                    for (parts.?, 0..) |part, j| {
                        // CRITICAL: explicitly set ALL optional fields (see
                        // comment above about 0xAA arena poison → SEGV).
                        non_assistant_blocks[j] = .{
                            .text = null,
                            .tool_use = null,
                            .tool_result = null,
                            .image = null,
                            .video = null,
                        };
                        if (part.image_url) |img| {
                            const url_str = img.url orelse "";
                            non_assistant_blocks[j].image = .{
                                .source_type = "url",
                                .url_or_data = url_str,
                                .media_type = null,
                            };
                        } else if (part.video_url) |vid| {
                            const url_str = vid.url orelse "";
                            if (url_str.len == 0) return error.UnsupportedVideoModel;
                            const mime = videoMimeFromDataUrl(url_str);
                            if (mime) |m| {
                                if (!isSupportedVideoMime(m)) return error.UnsupportedVideoModel;
                            }
                            non_assistant_blocks[j].video = .{
                                .source_type = "url",
                                .url_or_data = url_str,
                                .media_type = null,
                            };
                        } else if (part.text) |t| {
                            non_assistant_blocks[j].text = t;
                        } else {
                            // Hard error: never silently drop an unknown part
                            // (locked 2026-09-18). A video part from a future
                            // mime or a malformed part must surface, not coerce to "".
                            return error.UnsupportedContentPart;
                        }
                    }
                    json_messages[json_message_count] = .{
                        .role = msg.role.to_str(),
                        .content = .{ .array = non_assistant_blocks },
                    };
                } else {
                    json_messages[json_message_count] = .{
                        .role = msg.role.to_str(),
                        .content = .{ .single = .{ .text = msg.content orelse "" } },
                    };
                }
            }
            json_message_count += 1;
        }

        var json_tools: ?[]AnthropicTool = null;
        if (params.tools.len > 0) {
            const tool_slice = try arena_alloc.alloc(AnthropicTool, params.tools.len);
            for (params.tools, 0..) |tool, i| {
                const props = tool.function.parameters.properties;
                const json_props = try arena_alloc.alloc(ToolProperty, props.len);
                for (props, 0..) |prop, j| {
                    json_props[j] = prop;
                }
                tool_slice[i] = .{
                    .name = tool.function.name,
                    .description = tool.function.description,
                    .input_schema = .{
                        .properties = json_props,
                        .required = tool.function.parameters.required,
                    },
                };
            }
            json_tools = tool_slice;
        }

        const resolved_max_tokens: usize = params.max_tokens orelse self.maxTokens;

        // Anthropic requires `budget_tokens` to be >= 1024 AND
        // strictly less than `max_tokens`. The simpler 50%-of-max
        // heuristic wins for typical `max_tokens` values; clamp the
        // upper bound to `max_tokens - 1` so we never emit an
        // unsatisfiable request.
        //
        // For `max_tokens < 1025` the floor (1024) collides with the
        // strict-less-than constraint (budget must be < max_tokens),
        // so Anthropic literally cannot accept a thinking-enabled
        // request with that budget. Rather than silently emitting
        // an invalid request, force thinking off for this call and
        // log a warning — the alternative (clamps to 0, or to
        // some value >= max_tokens) would either be a 400 from the
        // server or violate the Anthropic invariant.
        const thinking_on: bool = blk: {
            if (!self.thinkingEnabled) break :blk false;
            if (resolved_max_tokens < 1025) {
                self.log_fmt(.warn, "buildJsonAnthropicRequest: thinkingEnabled=true but max_tokens={d} (<1025) — Anthropic requires budget_tokens >= 1024 AND < max_tokens, so thinking is forced off for this request. Raise max_tokens to >=1025 to re-enable.", .{resolved_max_tokens});
                break :blk false;
            }
            break :blk true;
        };

        const thinking_budget: ?usize = blk: {
            if (!thinking_on) break :blk null;
            // Three sources, in priority order (plan 2026-08-23-model-thinking):
            //   1. Explicit `Agent.thinkingBudgetTokens` override.
            //      Wins always, but still clamped to the
            //      [1024, max_tokens-1] range so the wire shape is
            //      always valid.
            //   2. `Agent.thinkingAdaptive = true` → null (let
            //      Anthropic pick). Triggered by the workflow when
            //      `profile.thinking == "auto"` and no explicit
            //      budget was set.
            //   3. 50%-of-max_tokens heuristic — the previous
            //      default. Triggered when `thinkingAdaptive = false`
            //      (i.e. user picked "on" without an explicit budget).
            if (self.thinkingBudgetTokens) |explicit| {
                const floor_constrained: usize = if (explicit < 1024) 1024 else explicit;
                const ceiling: usize = resolved_max_tokens -| 1;
                break :blk if (floor_constrained < ceiling) floor_constrained else ceiling;
            }
            if (self.thinkingAdaptive) {
                break :blk null;
            }
            const half = resolved_max_tokens / 2;
            const floor_constrained: usize = if (half < 1024) 1024 else half;
            const ceiling: usize = resolved_max_tokens -| 1;
            break :blk if (floor_constrained < ceiling) floor_constrained else ceiling;
        };

        // Anthropic requires `temperature` to be omitted (or exactly
        // 1) when `thinking.type == "enabled"`. Drop the caller's
        // value rather than overriding it with 1 — Anthropic's
        // default under thinking is already 1, so omitting doesn't
        // change server behavior. Log at .debug so callers can see
        // WHY their temperature was ignored without this being a
        // silent behavior change.
        if (thinking_on) {
            if (params.temperature) |t| {
                if (t != 1.0) {
                    self.log_fmt(.debug, "buildJsonAnthropicRequest: dropping temperature={d} because thinkingEnabled=true (Anthropic requires temperature omitted or 1 when thinking is enabled)", .{t});
                }
            }
        }

        const thinking_value: ?AnthropicThinking = blk: {
            if (!thinking_on) break :blk null;
            if (thinking_budget) |bt| break :blk .{ .type = "enabled", .budget_tokens = bt };
            // Adaptive mode — Anthropic picks the budget itself.
            // Triggered by profile.thinking == "auto" with no
            // explicit budget override.
            break :blk .{ .type = "adaptive" };
        };

        const json_request = AnthropicRequest{
            .model = self.model,
            .messages = json_messages[0..json_message_count],
            .max_tokens = resolved_max_tokens,
            .stream = stream,
            .tools = json_tools,
            .thinking = thinking_value,
            .temperature = if (thinking_on) null else params.temperature,
            .system = if (system_text.items.len > 0) system_text.items else null,
            .metadata = if (self.userIdentifier.len > 0)
                .{ .user_id = self.userIdentifier }
            else
                null,
        };

        var aw: std.Io.Writer.Allocating = .init(allocator);
        try aw.writer.print("{f}", .{std.json.fmt(json_request, .{})});
        return aw.toOwnedSlice();
    }

    pub fn buildJsonOpenAIRequest(self: Agent, params: AgentCall, stream: bool) ![]u8 {
        const allocator = self.allocator;

        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const arena_alloc = arena.allocator();

        var total_content_size: usize = 0;
        for (params.messages) |msg| {
            if (msg.content) |c| total_content_size += c.len;
            if (msg.reasoning_content) |rc| total_content_size += rc.len;
        }
        var total_props: usize = 0;
        for (params.tools) |tool| {
            total_props += tool.function.parameters.properties.len;
        }
        self.log_fmt(.debug, "TOOL_STATS: tools={d}, props={d}, content={d}", .{
            params.tools.len, total_props, total_content_size,
        });

        // Reasoning-echo backfill (task_1789091513563_0): DeepSeek-style
        // providers in thinking mode REQUIRE every assistant message to
        // carry `reasoning_content` ("must be passed back to the API").
        // Turns where the model streamed no reasoning deltas (e.g. pure
        // tool-call turns with empty content) persist NULL, and omitting
        // the field on replay bricks the session — every subsequent
        // request 400s with 0 chunks. Emit "" instead of omitting, but
        // ONLY for thinking conversations (thinking on now, or reasoning
        // present elsewhere in history) so plain OpenAI sessions keep
        // their exact current wire shape. Assistant-only: reasoning
        // belongs to assistant messages, never user/tool rows.
        const history_has_reasoning = blk: {
            for (params.messages) |m| {
                if (m.reasoning_content != null) break :blk true;
            }
            break :blk false;
        };
        const backfill_empty_reasoning = self.thinkingEnabled or history_has_reasoning;

        const json_messages = try arena_alloc.alloc(JsonMessage, params.messages.len);
        for (params.messages, 0..) |msg, i| {
            var json_tool_calls: ?[]JsonToolCall = null;
            if (msg.tool_calls) |tcs| {
                const tc_slice = try arena_alloc.alloc(JsonToolCall, tcs.len);
                for (tcs, 0..) |tc, j| {
                    // Repair before falling back to "{}": a Windows path
                    // written with raw backslashes is invalid JSON, and
                    // substituting "{}" here would both hide that and echo
                    // the model's own call back to it as an empty object.
                    const normalized_args = blk: {
                        const raw = tc.function.arguments;
                        if (raw.len == 0) break :blk "{}";
                        const repaired = args_repair.repairToolCallArguments(arena_alloc, raw) catch break :blk "{}";
                        break :blk if (repaired) |r| r.slice() else "{}";
                    };
                    tc_slice[j] = .{
                        .id = tc.id,
                        .type = tc.type,
                        .function = .{
                            .name = tc.function.name,
                            .arguments = normalized_args,
                        },
                    };
                }
                json_tool_calls = tc_slice;
            }

            var json_content_parts: ?[]const ContentPart = null;
            if (msg.content_parts) |parts| {
                const parts_copy = try arena_alloc.alloc(ContentPart, parts.len);
                for (parts, 0..) |part, j| {
                    parts_copy[j] = .{
                        .part_type = part.part_type,
                        .text = part.text,
                        .image_url = part.image_url,
                        .video_url = part.video_url,
                    };
                }
                json_content_parts = parts_copy;
            }

            json_messages[i] = .{
                .role = msg.role.to_str(),
                .content = msg.content,
                .content_parts = json_content_parts,
                .tool_calls = json_tool_calls,
                .tool_call_id = msg.tool_call_id,
                // See backfill comment above: null → "" for assistant
                // messages in thinking conversations (satisfies the
                // provider's echo validator); null stays null otherwise
                // so the field is omitted entirely.
                .reasoning_content = msg.reasoning_content orelse (if (backfill_empty_reasoning and msg.role == .assistant) "" else null),
            };
        }

        var json_tools: ?[]JsonTool = null;
        if (params.tools.len > 0) {
            const tool_slice = try arena_alloc.alloc(JsonTool, params.tools.len);
            for (params.tools, 0..) |tool, i| {
                const props = tool.function.parameters.properties;
                const json_props = try arena_alloc.alloc(ToolProperty, props.len);
                for (props, 0..) |prop, j| {
                    json_props[j] = prop;
                }
                tool_slice[i] = .{
                    .type = tool.type,
                    .function = .{
                        .name = tool.function.name,
                        .description = tool.function.description,
                        .parameters = .{
                            .properties = json_props,
                            .required = tool.function.parameters.required,
                        },
                    },
                };
            }
            json_tools = tool_slice;
        }

        const json_request = JsonRequest{
            .model = self.model,
            .enable_thinking = self.thinkingEnabled,
            .thinking = if (!self.thinkingEnabled) .{} else null,
            .messages = json_messages,
            .temperature = params.temperature orelse self.temperature,
            .max_tokens = params.max_tokens orelse self.maxTokens,
            .stream = stream,
            .tools = json_tools,
            .tool_choice = if (json_tools != null) "auto" else null,
            .user = if (self.userIdentifier.len > 0) self.userIdentifier else null,
            // OpenAI reasoning effort (plan 2026-08-23-model-thinking).
            // Borrowed from Agent.reasoningEffort (lifetime tied to
            // the workflow's LlmConfig singleton). The jsonStringify
            // skip-on-empty path means a misconfigured empty value
            // doesn't pollute the wire.
            .reasoning_effort = self.reasoningEffort,
        };

        var aw: std.Io.Writer.Allocating = .init(allocator);
        try aw.writer.print("{f}", .{std.json.fmt(json_request, .{})});
        return aw.toOwnedSlice();
    }

    /// Build JSON body for OpenAI Responses API (`url_style = "openai-response"`).
    /// POST /v1/responses — see https://developers.openai.com/api/reference/resources/responses
    /// Feature parity with `buildJsonOpenAIRequest`: model, instructions (system),
    /// input (user/assistant/tool messages + vision content_parts), max_output_tokens,
    /// temperature, reasoning.effort, tools, tool_choice, store, user. Stateless
    /// (store=false, no previous_response_id) — history is replayed via `input`.
    pub fn buildJsonResponsesRequest(self: Agent, params: AgentCall, stream: bool) ![]u8 {
        const allocator = self.allocator;
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const arena_alloc = arena.allocator();

        var total_content_size: usize = 0;
        for (params.messages) |msg| {
            if (msg.content) |c| total_content_size += c.len;
            if (msg.reasoning_content) |rc| total_content_size += rc.len;
        }
        self.log_fmt(.debug, "RESPONSES_STATS: tools={d}, content={d}", .{ params.tools.len, total_content_size });

        // Join system messages into top-level `instructions`.
        var instructions_buf: std.ArrayList(u8) = .empty;
        for (params.messages) |msg| {
            if (msg.role == .system) {
                if (msg.content) |c| {
                    if (instructions_buf.items.len > 0) try instructions_buf.appendSlice(arena_alloc, "\n\n");
                    try instructions_buf.appendSlice(arena_alloc, c);
                }
            }
        }
        const instructions: ?[]const u8 = if (instructions_buf.items.len > 0) instructions_buf.items else null;

        // Build heterogeneous `input` array. Each AgentMessage can expand to 1..N items:
        //   user        -> 1 message item
        //   assistant+tool_calls -> 1 message (if content) + N function_call items
        //   tool        -> 1 function_call_output item
        //   assistant (no tools) -> 1 message item
        // Worst case: every message spawns 1 + tool_calls, so capacity = messages.len * 2 + total tool_calls.
        var total_tool_calls: usize = 0;
        for (params.messages) |msg| {
            if (msg.tool_calls) |tcs| total_tool_calls += tcs.len;
        }
        const max_input_len = params.messages.len * 2 + total_tool_calls;
        var input_items = try arena_alloc.alloc(ResponsesInputItem, max_input_len);
        var input_count: usize = 0;

        for (params.messages) |msg| {
            if (msg.role == .system) continue; // already in `instructions` (§6)
            if (msg.role == .user) {
                // Build content array from content_parts or plain text.
                const parts = msg.content_parts;
                const has_parts = parts != null and parts.?.len > 0;
                if (has_parts) {
                    const part_count = parts.?.len;
                    var contents = try arena_alloc.alloc(ResponsesInputContent, part_count);
                    for (parts.?, 0..) |part, j| {
                        if (part.image_url) |img| {
                            contents[j] = .{
                                .content_type = "input_image",
                                .image_url = img.url orelse "",
                                .detail = img.detail orelse "auto",
                            };
                        } else if (part.video_url) |vid| {
                            const url_str = vid.url orelse "";
                            if (url_str.len == 0) return error.UnsupportedVideoModel;
                            const mime = videoMimeFromDataUrl(url_str);
                            if (mime) |m| {
                                if (!isSupportedVideoMime(m)) return error.UnsupportedVideoModel;
                            }
                            contents[j] = .{
                                .content_type = "input_video",
                                .video_url = url_str,
                            };
                        } else if (part.text) |t| {
                            contents[j] = .{ .content_type = "input_text", .text = t };
                        } else {
                            return error.UnsupportedContentPart;
                        }
                    }
                    input_items[input_count] = .{
                        .item_type = "message",
                        .role = "user",
                        .content = contents,
                    };
                } else {
                    var contents = try arena_alloc.alloc(ResponsesInputContent, 1);
                    contents[0] = .{ .content_type = "input_text", .text = msg.content orelse "" };
                    input_items[input_count] = .{
                        .item_type = "message",
                        .role = "user",
                        .content = contents,
                    };
                }
                input_count += 1;
            } else if (msg.role == .assistant) {
                // Responses reasoning is a separate top-level `type:"reasoning"`
                // item, NOT merged into the assistant `type:"message"` content.
                // See plan docs/superpowers/plans/2026-09-01-fix-openai-response-reasoning-leak-and-persist.md
                const has_tool_calls = msg.tool_calls != null and msg.tool_calls.?.len > 0;
                const c = msg.content;
                const rc = msg.reasoning_content;
                const has_c = c != null and c.?.len > 0;
                const has_rc = rc != null and rc.?.len > 0;
                const has_rid = msg.reasoning_id != null and msg.reasoning_id.?.len > 0;
                const has_enc = msg.reasoning_encrypted_content != null and msg.reasoning_encrypted_content.?.len > 0;
                const has_reasoning = has_rc or has_rid or has_enc;
                if (has_reasoning) {
                    // Provider (Console Go → upstream) requires `summary` to be present
                    // on every `type:"reasoning"` item. When `reasoning_content` is
                    // NULL (summary was empty or never streamed), we still persist
                    // `id`+`encrypted_content` for `store:false` replay — so we
                    // must emit an empty `summary:[]` to satisfy the schema.
                    // Omitting it produces:
                    //   `input[1]` missing required field `summary`
                    // and the stream terminates with 0 chunks.
                    var summary: ?[]const ResponsesReasoningSummary = null;
                    if (has_rc) {
                        var s = try arena_alloc.alloc(ResponsesReasoningSummary, 1);
                        s[0] = .{ .text = rc.? };
                        summary = s;
                    } else {
                        summary = try arena_alloc.alloc(ResponsesReasoningSummary, 0);
                    }
                    input_items[input_count] = .{
                        .item_type = "reasoning",
                        .id = msg.reasoning_id,
                        .summary = summary,
                        .encrypted_content = msg.reasoning_encrypted_content,
                    };
                    input_count += 1;
                }
                if (has_c) {
                    var contents = try arena_alloc.alloc(ResponsesInputContent, 1);
                    contents[0] = .{ .content_type = "output_text", .text = c.? };
                    input_items[input_count] = .{
                        .item_type = "message",
                        .role = "assistant",
                        .content = contents,
                    };
                    input_count += 1;
                } else if (!has_reasoning and !has_tool_calls) {
                    // Empty assistant message without tools/reasoning — still emit empty message to preserve turn.
                    var contents = try arena_alloc.alloc(ResponsesInputContent, 1);
                    contents[0] = .{ .content_type = "output_text", .text = "" };
                    input_items[input_count] = .{
                        .item_type = "message",
                        .role = "assistant",
                        .content = contents,
                    };
                    input_count += 1;
                }
                if (has_tool_calls) {
                    for (msg.tool_calls.?) |tc| {
                        input_items[input_count] = .{
                            .item_type = "function_call",
                            .call_id = tc.id,
                            .name = tc.function.name,
                            .arguments = tc.function.arguments,
                        };
                        input_count += 1;
                    }
                }
            } else if (msg.role == .tool) {
                // Gateway (Console Go → upstream, url_style="openai-response")
                // validates `function_call_output` strictly: it rejects the
                // request with `input[N].output[0] did not match any supported
                // type` when `output` is not a valid UTF-8 JSON string (e.g. a
                // `bash` tool output containing `cat` of an ELF binary embeds
                // 0x80-0xFF bytes that std.json emits raw) or when `call_id`
                // is empty and can never pair with a `function_call`.
                // Sanitize + truncate HERE (not at persistence) so already
                // poisoned rows in llm_history are fixed on replay.
                // OpenAI Responses reference (POST /v1/responses):
                // `function_call_output.output` is a plain string — keep the
                // string shape, just make it valid + bounded.
                const raw_output = msg.content orelse "";
                const clean_output = helpers.sanitize.sanitizeUtf8(arena_alloc, raw_output) catch raw_output;
                // Bound oversize outputs (ls -R + binary dumps). Cap is
                // approximate: 20k content bytes + short marker suffix.
                const max_tool_output_len: usize = 20_000;
                var final_output = clean_output;
                if (clean_output.len > max_tool_output_len) {
                    var keep: usize = max_tool_output_len;
                    // Back off to a UTF-8 char boundary (clean_output is
                    // valid UTF-8 here, so a start byte is always found).
                    while (keep > 0 and clean_output[keep] & 0xC0 == 0x80) keep -= 1;
                    const dropped = clean_output.len - keep;
                    const suffix = std.fmt.allocPrint(arena_alloc, "\n...[truncated {d} of {d} bytes]", .{ dropped, clean_output.len }) catch "";
                    final_output = std.fmt.allocPrint(arena_alloc, "{s}{s}", .{ clean_output[0..keep], suffix }) catch clean_output[0..keep];
                }
                const cid = msg.tool_call_id orelse "";
                if (cid.len == 0) {
                    // An empty call_id can never pair with a function_call —
                    // emitting it poisons the whole request, so skip + log.
                    self.log_fmt(.err, "[RESPONSES] skipping function_call_output with empty call_id (output len={d})", .{final_output.len});
                    continue;
                }
                input_items[input_count] = .{
                    .item_type = "function_call_output",
                    .call_id = cid,
                    .output = final_output,
                };
                input_count += 1;
            }
        }

        var json_tools: ?[]ResponsesTool = null;
        if (params.tools.len > 0) {
            const tool_slice = try arena_alloc.alloc(ResponsesTool, params.tools.len);
            for (params.tools, 0..) |tool, i| {
                const props = tool.function.parameters.properties;
                const json_props = try arena_alloc.alloc(ToolProperty, props.len);
                for (props, 0..) |prop, j| {
                    json_props[j] = prop;
                }
                tool_slice[i] = .{
                    .name = tool.function.name,
                    .description = tool.function.description,
                    .parameters = .{
                        .properties = json_props,
                        .required = tool.function.parameters.required,
                    },
                };
            }
            json_tools = tool_slice;
        }

        const resolved_max_tokens: usize = params.max_tokens orelse self.maxTokens;

        var reasoning: ?ResponsesReasoning = null;
        if (self.reasoningEffort) |eff| {
            if (eff.len > 0) reasoning = .{ .effort = eff };
        }
        // Do NOT auto-map `thinkingEnabled` → reasoning. Chat's
        // `enable_thinking` is a separate flag; Responses `reasoning`
        // should only be sent when the user explicitly set
        // `reasoning_effort`. Auto-sending `medium` for every
        // `thinking:auto` profile was making muse-spark not call tools.

        const req = ResponsesRequest{
            .model = self.model,
            .input = input_items[0..input_count],
            .instructions = instructions,
            .max_output_tokens = resolved_max_tokens,
            .stream = stream,
            .temperature = params.temperature orelse self.temperature,
            .reasoning = reasoning,
            .tools = json_tools,
            .tool_choice = if (json_tools != null) "auto" else null,
            .store = false,
            .user = if (self.userIdentifier.len > 0) self.userIdentifier else null,
        };

        var aw2: std.Io.Writer.Allocating = .init(allocator);
        try aw2.writer.print("{f}", .{std.json.fmt(req, .{})});
        const out = try aw2.toOwnedSlice();
        if (std.mem.eql(u8, self.UrlStyle, "openai-response")) {
            self.log_fmt(.info, "[RESPONSES DEBUG] input_items={d} tools={d} has_instructions={} json_len={d}", .{ input_items[0..input_count].len, if (json_tools) |t| t.len else 0, instructions != null, out.len });
            // Log a larger preview (2000 chars) so we can see tool definitions in the truncated log.
            const preview_len = @min(out.len, 2000);
            self.log_fmt(.debug, "[RESPONSES BODY] {s}", .{out[0..preview_len]});
        }
        return out;
    }

    pub const CallError = error{
        BuildRequestFailed,
        InvalidUri,
        AuthFailed,
        HttpRequestFailed,
        SendBodyFailed,
        ReceiveFailed,
        ParseJsonFailed,
        ApiError,
        NoChoices,
        AllocFailed,
        WriteFailed,
        OutOfMemory,
        Cancelled,
        /// Overall read deadline (HttpOptions.read_timeout_ms) was exceeded.
        StreamTimeout,
        /// No new bytes for HttpOptions.idle_timeout_ms after readSliceShort returned.
        /// With TCP keepalive, this fires after keepalive detects the dead connection
        /// (~25s) and readSliceShort returns an error, then the idle check triggers.
        StreamIdleTimeout,
        /// Mid-stream transport error (e.g. ConnectionResetByPeer from keepalive).
        StreamInterrupted,
        /// Stream ended with 0 chunks and no clean-end signal.
        StreamEmpty,
    };

    pub fn parse_sse_line(_: Agent, line: []const u8) ?[]const u8 {
        if (line.len == 0) return null;
        if (!std.mem.startsWith(u8, line, "data: ")) return null;
        const data = line[6..];
        if (std.mem.eql(u8, data, "[DONE]")) return null;
        return data;
    }

    pub fn parse_stream_chunk(self: *Agent, data: []const u8, arena: std.mem.Allocator) ?StreamChunk {
        // Anthropic uses a different SSE event shape (`event:` + `data:`
        // pairs with a `type` field, not `choices[0].delta`). Dispatch on
        // UrlStyle so the rest of the pipeline (StreamingAggregator,
        // CallResponse, the workflow loop) sees the same StreamChunk shape
        // regardless of provider.
        // Responses API (openai-response) also uses typed events `response.*`.
        if (std.mem.eql(u8, self.UrlStyle, "openai-response")) {
            return self.parse_responses_stream_chunk(data, arena);
        }
        if (std.mem.eql(u8, self.UrlStyle, "anthropic")) {
            return self.parse_anthropic_stream_chunk(data, arena);
        }
        const parsed = json.parseFromSlice(json.Value, arena, data, .{}) catch |err| {
            const max_data_len = 200;
            const truncated = data.len > max_data_len;
            const data_to_log = if (truncated) data[0..max_data_len] else data;
            if (truncated) {
                self.log_fmt(.err, "JSON parse failed: {s}\nData (truncated): {s}...", .{ @errorName(err), data_to_log });
            } else {
                self.log_fmt(.err, "JSON parse failed: {s}\nData: {s}", .{ @errorName(err), data_to_log });
            }
            return null;
        };
        defer parsed.deinit();
        const root = parsed.value;

        var chunk: StreamChunk = .{};

        if (root.object.get("choices")) |choices| {
            if (choices.array.items.len > 0) {
                const first_choice = choices.array.items[0];

                if (first_choice.object.get("finish_reason")) |fr| {
                    if (fr == .string) {
                        chunk.finish_reason = FinishReason.from_str(fr.string);
                    }
                }

                const msg_field = first_choice.object.get("delta") orelse first_choice.object.get("message");
                if (msg_field) |delta| {
                    if (delta.object.get("content")) |content| {
                        if (content == .string and content.string.len > 0) {
                            chunk.content = content.string;
                        }
                    }
                    if (delta.object.get("reasoning_content")) |rc| {
                        if (rc == .string and rc.string.len > 0) {
                            chunk.reasoning_content = rc.string;
                        }
                    }
                    if (delta.object.get("tool_calls")) |tc_delta| {
                        if (tc_delta == .array and tc_delta.array.items.len > 0) {
                            var deltas = arena.alloc(ToolCallDelta, tc_delta.array.items.len) catch |err| {
                                self.log_fmt(.err, "Error allocating ToolCallDelta: {s}", .{@errorName(err)});
                                return null;
                            };
                            for (tc_delta.array.items, 0..) |tc_item, i| {
                                var delta_item: ToolCallDelta = .{ .index = i };
                                if (tc_item == .object) {
                                    if (tc_item.object.get("index")) |idx| {
                                        if (idx == .integer) delta_item.index = @intCast(idx.integer);
                                    }
                                    if (tc_item.object.get("id")) |id| {
                                        if (id == .string and id.string.len > 0) delta_item.id = id.string;
                                    }
                                    if (tc_item.object.get("function")) |func| {
                                        if (func == .object) {
                                            if (func.object.get("name")) |name| {
                                                if (name == .string and name.string.len > 0) delta_item.function_name = name.string;
                                            }
                                            if (func.object.get("arguments")) |args| {
                                                if (args == .string and args.string.len > 0) delta_item.function_arguments = args.string;
                                            }
                                        }
                                    }
                                }
                                deltas[i] = delta_item;
                            }
                            chunk.tool_calls_delta = deltas;
                        }
                    }
                }
            }
        }

        if (root.object.get("usage")) |usage_val| {
            if (usage_val == .object) {
                var usage: Usage = .{};
                if (usage_val.object.get("prompt_tokens")) |pt| {
                    if (pt == .integer) usage.prompt_tokens = @intCast(pt.integer);
                }
                if (usage_val.object.get("completion_tokens")) |ct| {
                    if (ct == .integer) usage.completion_tokens = @intCast(ct.integer);
                }
                if (usage_val.object.get("total_tokens")) |tt| {
                    if (tt == .integer) usage.total_tokens = @intCast(tt.integer);
                }
                chunk.usage = usage;
            }
        }

        return chunk;
    }

    /// Anthropic streaming-SSE → StreamChunk mapper.
    ///
    /// Anthropic's /v1/messages streams `event:` + `data:` pairs (the wire
    /// shape the OpenAI parser doesn't understand). We translate the events
    /// the workflow cares about into the same `StreamChunk` shape the
    /// OpenAI parser produces, so the rest of the pipeline
    /// (StreamingAggregator, CallResponse, the workflow loop) doesn't need
    /// to know which provider it's talking to.
    ///
    /// Event → StreamChunk mapping (see
    /// docs/superpowers/plans/2026-08-13-anthropic-profile-sse-parsing.md
    /// for the full spec):
    ///   message_start           → caches input_tokens (no chunk emitted)
    ///   content_block_delta     → text_delta|thinking_delta|input_json_delta
    ///   content_block_start     → tool_use → tool_calls_delta[i] with id+name
    ///   message_delta           → finish_reason + output_tokens (usage chunk)
    ///   message_stop            → no-op (signal-only)
    ///   content_block_stop      → no-op (signal-only)
    ///   anything else           → return null
    ///
    /// Per-call scratch state lives on the Agent struct (reset at the top
    /// of `callStreaming`): `_anthropic_input_tokens` (cached from
    /// message_start) and `_anthropic_usage_emitted` (guard so the cached
    /// input_tokens are emitted on the first delta only).
    fn parse_anthropic_stream_chunk(
        self: *Agent,
        data: []const u8,
        arena: std.mem.Allocator,
    ) ?StreamChunk {
        const parsed = json.parseFromSlice(json.Value, arena, data, .{}) catch |err| {
            const max_data_len = 200;
            const truncated = data.len > max_data_len;
            const data_to_log = if (truncated) data[0..max_data_len] else data;
            if (truncated) {
                self.log_fmt(.err, "Anthropic SSE JSON parse failed: {s}\nData (truncated): {s}...", .{ @errorName(err), data_to_log });
            } else {
                self.log_fmt(.err, "Anthropic SSE JSON parse failed: {s}\nData: {s}", .{ @errorName(err), data_to_log });
            }
            return null;
        };
        defer parsed.deinit();

        const root = parsed.value;
        const type_val = root.object.get("type") orelse return null;
        if (type_val != .string) return null;
        const event_type = type_val.string;

        if (std.mem.eql(u8, event_type, "message_start")) {
            // Cache input_tokens from message.message.usage.input_tokens.
            // Emit no chunk — the first delta will carry the usage.
            const message = root.object.get("message") orelse return null;
            if (message != .object) return null;
            const usage = message.object.get("usage") orelse return null;
            if (usage != .object) return null;
            if (usage.object.get("input_tokens")) |it| {
                if (it == .integer) self._anthropic_input_tokens = @intCast(it.integer);
            }
            // Cache the cache-shaped fields too — some relays send them at
            // message_start but not at message_delta, and the first-delta
            // usage chunk below folds both into prompt_tokens.
            if (usage.object.get("cache_read_input_tokens")) |cr| {
                if (cr == .integer) self._anthropic_cache_read_tokens = @intCast(cr.integer);
            }
            if (usage.object.get("cache_creation_input_tokens")) |cc| {
                if (cc == .integer) self._anthropic_cache_creation_tokens = @intCast(cc.integer);
            }
            return null;
        }

        var chunk: StreamChunk = .{};

        if (std.mem.eql(u8, event_type, "content_block_start")) {
            const index = root.object.get("index") orelse return null;
            const cb = root.object.get("content_block") orelse return null;
            if (index != .integer or cb != .object) return null;
            const cb_type = cb.object.get("type") orelse return null;
            if (cb_type != .string) return null;
            // Only tool_use blocks need a tool_calls_delta here (text /
            // thinking blocks just carry content deltas — handled below).
            if (!std.mem.eql(u8, cb_type.string, "tool_use")) return null;

            const id_val = cb.object.get("id") orelse return null;
            const name_val = cb.object.get("name") orelse return null;
            if (id_val != .string or name_val != .string) return null;

            const delta_slice = arena.alloc(ToolCallDelta, 1) catch return null;
            delta_slice[0] = .{
                .index = @intCast(index.integer),
                .id = id_val.string,
                .function_name = name_val.string,
            };
            chunk.tool_calls_delta = delta_slice;
        } else if (std.mem.eql(u8, event_type, "content_block_delta")) {
            const index_val = root.object.get("index") orelse return null;
            const delta = root.object.get("delta") orelse return null;
            if (index_val != .integer or delta != .object) return null;
            const index: usize = @intCast(index_val.integer);

            const delta_type = delta.object.get("type") orelse return null;
            if (delta_type != .string) return null;

            if (std.mem.eql(u8, delta_type.string, "text_delta")) {
                const text = delta.object.get("text") orelse return null;
                if (text != .string) return null;
                chunk.content = text.string;
            } else if (std.mem.eql(u8, delta_type.string, "thinking_delta")) {
                const thinking = delta.object.get("thinking") orelse return null;
                if (thinking != .string) return null;
                chunk.reasoning_content = thinking.string;
            } else if (std.mem.eql(u8, delta_type.string, "input_json_delta")) {
                const partial = delta.object.get("partial_json") orelse return null;
                if (partial != .string) return null;
                const delta_slice = arena.alloc(ToolCallDelta, 1) catch return null;
                delta_slice[0] = .{
                    .index = index,
                    .function_arguments = partial.string,
                };
                chunk.tool_calls_delta = delta_slice;
            } else {
                return null; // unknown delta.type — ignore
            }

            // Emit a usage chunk on the FIRST delta so the aggregator sees
            // the cached input_tokens count. Mirrors the OpenAI parser's
            // use of `stream_options.include_usage=true`. We include the
            // cached cache_creation + cache_read tokens too (from
            // message_start), so the first-delta chunk has the same
            // shape as the final message_delta chunk — which matters when
            // the message_delta never fires (rare but possible on
            // mid-stream death).
            if (self._anthropic_input_tokens > 0 and !self._anthropic_usage_emitted) {
                const cached_creation = self._anthropic_cache_creation_tokens;
                const cached_read = self._anthropic_cache_read_tokens;
                const prompt_first_delta: u32 = self._anthropic_input_tokens + cached_creation + cached_read;
                chunk.usage = .{
                    .prompt_tokens = prompt_first_delta,
                    .completion_tokens = 0,
                    .total_tokens = prompt_first_delta,
                    .cache_creation_input_tokens = cached_creation,
                    .cache_read_input_tokens = cached_read,
                };
                self._anthropic_usage_emitted = true;
            }
        } else if (std.mem.eql(u8, event_type, "message_delta")) {
            const delta = root.object.get("delta") orelse return null;
            if (delta != .object) return null;
            if (delta.object.get("stop_reason")) |sr| {
                if (sr == .string) {
                    chunk.finish_reason = FinishReason.from_str(map_anthropic_stop_reason(sr.string));
                }
            }
            // Anthropic's `message_delta.usage` carries the AUTHORITATIVE
            // token counts for the call. The strict Anthropic API sends
            // `output_tokens` + `cache_creation_input_tokens` here
            // (input_tokens was already cached from `message_start`).
            //
            // Some relays (e.g. api.minimax.io/anthropic) ALSO send
            // `input_tokens` here — and may return 0 at `message_start`
            // before delivering the real value here. Always prefer the
            // `message_delta` value when present, falling back to the
            // cached `message_start` value (via `_anthropic_input_tokens`)
            // otherwise. This makes the parser robust to BOTH the strict
            // API shape and the relay quirk without code branches.
            //
            // `prompt_tokens` includes ALL input-shaped tokens the model
            // processed — input_tokens + cache_creation_input_tokens +
            // cache_read_input_tokens — so that `total_tokens = prompt +
            // completion` matches OpenAI's semantic ("tokens the LLM
            // saw"). Cache reads are billed at a discounted rate (so
            // they're NOT included in any future billing formula that
            // multiplies by the input rate), but they ARE tokens the
            // model still had to attend to — dropping them from
            // `prompt_tokens` made Anthropic totals ~5× lower than
            // equivalent OpenAI calls.
            //
            // We do NOT override `self._anthropic_input_tokens` /
            // `_anthropic_cache_*_tokens` here even when message_delta
            // supplies them — those cached fields are used by the
            // first-delta usage chunk above and would race with this
            // later message_delta usage chunk for the aggregator if
            // mutated. The fresh value wins for the final message_delta
            // usage emission, which is what `CallResponse.usage`
            // actually persists (the aggregator's
            // StreamingAggregator.process_chunk uses the LAST seen usage
            // chunk for `total_tokens` only when total > 0).
            if (root.object.get("usage")) |usage_val| {
                if (usage_val == .object) {
                    var input_tokens: u32 = self._anthropic_input_tokens;
                    var cache_creation_tokens: u32 = self._anthropic_cache_creation_tokens;
                    var cache_read_tokens: u32 = self._anthropic_cache_read_tokens;
                    var output_tokens: u32 = 0;

                    if (usage_val.object.get("input_tokens")) |it| {
                        if (it == .integer) input_tokens = @intCast(it.integer);
                    }
                    if (usage_val.object.get("cache_creation_input_tokens")) |cc| {
                        if (cc == .integer) cache_creation_tokens = @intCast(cc.integer);
                    }
                    if (usage_val.object.get("cache_read_input_tokens")) |cr| {
                        if (cr == .integer) cache_read_tokens = @intCast(cr.integer);
                    }
                    if (usage_val.object.get("output_tokens")) |ot| {
                        if (ot == .integer) output_tokens = @intCast(ot.integer);
                    }

                    if (output_tokens > 0) {
                        const prompt_tokens: u32 = input_tokens + cache_creation_tokens + cache_read_tokens;
                        chunk.usage = .{
                            .prompt_tokens = prompt_tokens,
                            .completion_tokens = output_tokens,
                            .total_tokens = prompt_tokens + output_tokens,
                            .cache_creation_input_tokens = cache_creation_tokens,
                            .cache_read_input_tokens = cache_read_tokens,
                        };
                    }
                }
            }
        } else {
            // message_stop, content_block_stop, ping, anything else — no-op.
            return null;
        }

        return chunk;
    }

    /// Anthropic's stop_reason strings don't match OpenAI's. Map them so
    /// the workflow's finish_reason handling stays provider-agnostic:
    ///   end_turn       → "stop"
    ///   tool_use       → "tool_calls"
    ///   max_tokens     → "length"
    ///   stop_sequence  → "stop"
    ///   refusal        → "content_filter"
    fn map_anthropic_stop_reason(s: []const u8) ?[]const u8 {
        if (std.mem.eql(u8, s, "end_turn")) return "stop";
        if (std.mem.eql(u8, s, "tool_use")) return "tool_calls";
        if (std.mem.eql(u8, s, "max_tokens")) return "length";
        if (std.mem.eql(u8, s, "stop_sequence")) return "stop";
        if (std.mem.eql(u8, s, "refusal")) return "content_filter";
        return null;
    }

    /// OpenAI Responses API streaming-SSE → StreamChunk mapper.
    /// Event types per https://developers.openai.com/api/reference/resources/responses
    /// We translate typed `response.*` events into the same StreamChunk shape the
    /// chat completions parser produces.
    ///   response.output_text.delta           → content
    ///   response.output_text.done            → (ignore, already deltas)
    ///   response.reasoning_text.delta        → reasoning_content
    ///   response.reasoning_summary_text.delta→ reasoning_content
    ///   response.output_item.added (function_call) → tool_calls_delta id+name
    ///   response.function_call_arguments.delta-> tool_calls_delta arguments
    ///   response.function_call_arguments.done  -> (finalized via aggregator)
    ///   response.completed                    → finish_reason + usage
    ///   response.failed / response.incomplete → finish_reason + usage
    ///   others (response.created, in_progress, content_part.added/done, output_item.done, queued) → no-op
    fn parse_responses_stream_chunk(self: *Agent, data: []const u8, arena: std.mem.Allocator) ?StreamChunk {
        const parsed = json.parseFromSlice(json.Value, arena, data, .{}) catch |err| {
            const max_data_len = 200;
            const truncated = data.len > max_data_len;
            const data_to_log = if (truncated) data[0..max_data_len] else data;
            if (truncated) {
                self.log_fmt(.err, "Responses SSE JSON parse failed: {s}\nData (truncated): {s}...", .{ @errorName(err), data_to_log });
            } else {
                self.log_fmt(.err, "Responses SSE JSON parse failed: {s}\nData: {s}", .{ @errorName(err), data_to_log });
            }
            return null;
        };
        defer parsed.deinit();
        const root = parsed.value;
        if (root != .object) return null;
        const type_val = root.object.get("type") orelse return null;
        if (type_val != .string) return null;
        const event_type = type_val.string;

        var chunk: StreamChunk = .{};

        // Text deltas — may appear as `response.output_text.delta` with field `delta`
        if (std.mem.eql(u8, event_type, "response.output_text.delta")) {
            const delta = root.object.get("delta") orelse return null;
            if (delta != .string) return null;
            if (delta.string.len == 0) return null;
            chunk.content = delta.string;
            return chunk;
        }
        if (std.mem.eql(u8, event_type, "response.output_text.annotation.added")) {
            return null;
        }
        if (std.mem.eql(u8, event_type, "response.output_text.done")) {
            return null;
        }
        if (std.mem.eql(u8, event_type, "response.refusal.delta")) {
            const delta = root.object.get("delta") orelse return null;
            if (delta != .string) return null;
            chunk.content = delta.string;
            return chunk;
        }
        if (std.mem.eql(u8, event_type, "response.refusal.done")) {
            return null;
        }
        // Reasoning deltas (Responses reasoning uses several names)
        if (std.mem.eql(u8, event_type, "response.reasoning_text.delta") or
            std.mem.eql(u8, event_type, "response.reasoning_summary_text.delta") or
            std.mem.eql(u8, event_type, "response.reasoning.delta"))
        {
            const delta = root.object.get("delta") orelse root.object.get("text") orelse return null;
            if (delta != .string) return null;
            chunk.reasoning_content = delta.string;
            return chunk;
        }
        if (std.mem.eql(u8, event_type, "response.reasoning_text.done") or
            std.mem.eql(u8, event_type, "response.reasoning_summary_text.done"))
        {
            // `done` carries the final `text` for the part — use it as
            // fallback when deltas were not emitted or were dropped.
            // This complements the terminal `response.completed` summary
            // fallback. Without it, a stream that only emits `done` with
            // no prior `delta` leaves `reasoning_content` NULL (seen on
            // opencode.ai/zen muse-spark via Console Go).
            const text = root.object.get("text") orelse return null;
            if (text != .string) return null;
            if (text.string.len == 0) return null;
            chunk.reasoning_content = text.string;
            return chunk;
        }
        // Reasoning summary part boundaries — `added`/`done` carry `part`
        // with `{type:"summary_text", text:"..."}`.
        if (std.mem.eql(u8, event_type, "response.reasoning_summary_part.added") or
            std.mem.eql(u8, event_type, "response.reasoning_summary_part.done"))
        {
            const part = root.object.get("part") orelse return null;
            if (part != .object) return null;
            const t = part.object.get("text") orelse return null;
            if (t != .string or t.string.len == 0) return null;
            chunk.reasoning_content = t.string;
            return chunk;
        }
        // Tool call start — `response.output_item.added` with item.type == "function_call"
        if (std.mem.eql(u8, event_type, "response.output_item.added")) {
            const item = root.object.get("item") orelse return null;
            if (item != .object) return null;
            const item_type = item.object.get("type") orelse return null;
            if (item_type != .string) return null;
            if (!std.mem.eql(u8, item_type.string, "function_call")) return null;
            const call_id = item.object.get("call_id") orelse item.object.get("id") orelse return null;
            const name_val = item.object.get("name") orelse return null;
            if (call_id != .string or name_val != .string) return null;
            // output_index is the tool index for the aggregator
            var idx: usize = 0;
            if (root.object.get("output_index")) |ov| {
                if (ov == .integer) idx = @intCast(ov.integer);
            }
            const slice = arena.alloc(ToolCallDelta, 1) catch return null;
            slice[0] = .{
                .index = idx,
                .id = call_id.string,
                .function_name = name_val.string,
            };
            chunk.tool_calls_delta = slice;
            return chunk;
        }
        // Tool arguments deltas
        if (std.mem.eql(u8, event_type, "response.function_call_arguments.delta")) {
            const delta = root.object.get("delta") orelse return null;
            if (delta != .string) return null;
            var idx: usize = 0;
            if (root.object.get("output_index")) |ov| {
                if (ov == .integer) idx = @intCast(ov.integer);
            } else if (root.object.get("item_id")) |_| {
                idx = 0;
            }
            const slice = arena.alloc(ToolCallDelta, 1) catch return null;
            slice[0] = .{
                .index = idx,
                .function_arguments = delta.string,
            };
            chunk.tool_calls_delta = slice;
            return chunk;
        }
        if (std.mem.eql(u8, event_type, "response.function_call_arguments.done")) {
            // Final arguments already assembled via deltas; emit one more delta with full arguments so aggregator finalizes
            const args = root.object.get("arguments") orelse return null;
            if (args != .string) return null;
            // If we already streamed deltas, this is duplicate;aggregator appends, so only emit if non-empty and not already covered
            // We emit as a final chunk only if the string is non-empty and we haven't already emitted same length via deltas
            // For safety, return null to avoid double-append — the deltas already built the full JSON.
            return null;
        }
        // Custom tool deltas (future proof)
        if (std.mem.eql(u8, event_type, "response.custom_tool_call_input.delta")) {
            const delta = root.object.get("delta") orelse root.object.get("input") orelse return null;
            if (delta != .string) return null;
            var idx: usize = 0;
            if (root.object.get("output_index")) |ov| {
                if (ov == .integer) idx = @intCast(ov.integer);
            }
            const slice = arena.alloc(ToolCallDelta, 1) catch return null;
            slice[0] = .{ .index = idx, .function_arguments = delta.string };
            chunk.tool_calls_delta = slice;
            return chunk;
        }
        // Reasoning item done — the per-item finalization carries the
        // complete summary + id + encrypted_content for that reasoning
        // item. This fires before `response.completed`, so capturing here
        // gives us the same fallback that `response.completed` uses, but
        // earlier. If the stream never reaches `completed` (e.g. truncated
        // due to max_output_tokens), this is the last chance to capture.
        if (std.mem.eql(u8, event_type, "response.output_item.done")) {
            const item = root.object.get("item") orelse return null;
            if (item != .object) return null;
            const it = item.object.get("type") orelse return null;
            if (it != .string or !std.mem.eql(u8, it.string, "reasoning")) return null;
            var has_summary = false;
            var buf: std.ArrayList(u8) = .empty;
            if (item.object.get("summary")) |sv| {
                if (sv == .array) {
                    for (sv.array.items) |si| {
                        if (si != .object) continue;
                        const tv = si.object.get("text") orelse continue;
                        if (tv != .string or tv.string.len == 0) continue;
                        if (has_summary) buf.appendSlice(arena, "\n") catch continue;
                        buf.appendSlice(arena, tv.string) catch continue;
                        has_summary = true;
                    }
                }
            }
            if (has_summary and buf.items.len > 0) chunk.reasoning_content = buf.items;
            if (item.object.get("id")) |idv| {
                if (idv == .string and idv.string.len > 0) chunk.reasoning_id = idv.string;
            }
            if (item.object.get("encrypted_content")) |ev| {
                if (ev == .string and ev.string.len > 0) chunk.reasoning_encrypted_content = ev.string;
            }
            // Don't return yet if only id/enc without summary — let it
            // flow as terminal-like chunk so aggregator captures id/enc.
            if (chunk.reasoning_content != null or chunk.reasoning_id != null or chunk.reasoning_encrypted_content != null) return chunk;
            return null;
        }

        // Terminal events — carry finish_reason + usage
        if (std.mem.eql(u8, event_type, "response.completed") or
            std.mem.eql(u8, event_type, "response.incomplete") or
            std.mem.eql(u8, event_type, "response.failed"))
        {
            const response = root.object.get("response") orelse root;
            if (response != .object) return null;
            // finish_reason: Responses uses status + incomplete_details.reason
            if (response.object.get("status")) |status_val| {
                if (status_val == .string) {
                    if (std.mem.eql(u8, status_val.string, "completed")) {
                        chunk.finish_reason = .stop;
                    } else if (std.mem.eql(u8, status_val.string, "failed")) {
                        chunk.finish_reason = .content_filter;
                    } else if (std.mem.eql(u8, status_val.string, "incomplete")) {
                        // check reason
                        if (response.object.get("incomplete_details")) |inc| {
                            if (inc == .object) {
                                if (inc.object.get("reason")) |r| {
                                    if (r == .string and std.mem.eql(u8, r.string, "max_output_tokens")) {
                                        chunk.finish_reason = .length;
                                    } else {
                                        chunk.finish_reason = .stop;
                                    }
                                } else chunk.finish_reason = .stop;
                            } else chunk.finish_reason = .stop;
                        } else chunk.finish_reason = .stop;
                    } else {
                        chunk.finish_reason = .stop;
                    }
                }
            } else {
                chunk.finish_reason = .stop;
            }

            // FIX: The Responses API has NO distinct terminal status for
            // tool calls — `status` stays "completed" even when the model
            // emitted one or more function_call items. Chat Completions
            // signals this via `finish_reason: "tool_calls"`, but Responses
            // only tells you via the shape of `response.output[]`. Without
            // this override, `chunk.finish_reason` stays `.stop` even
            // though `CallResponse.tool_calls` is populated — so any
            // workflow logic gated on `finish_reason == .tool_calls` never
            // fires and the model's tool calls are silently dropped.
            if (response.object.get("output")) |output_val| {
                if (output_val == .array) {
                    for (output_val.array.items) |item| {
                        if (item != .object) continue;
                        const item_type = item.object.get("type") orelse continue;
                        if (item_type != .string) continue;
                        if (std.mem.eql(u8, item_type.string, "function_call")) {
                            chunk.finish_reason = .tool_calls;
                            break;
                        }
                    }
                }
            }

            // Capture reasoning metadata from terminal output: id,
            // encrypted_content, and summary[] fallback for reasoning_content.
            if (response.object.get("output")) |output_val| {
                if (output_val == .array) {
                    var first_reasoning_id: ?[]const u8 = null;
                    var first_encrypted: ?[]const u8 = null;
                    var summary_buf: std.ArrayList(u8) = .empty;
                    var has_summary = false;
                    for (output_val.array.items) |item| {
                        if (item != .object) continue;
                        const item_type = item.object.get("type") orelse continue;
                        if (item_type != .string) continue;
                        if (!std.mem.eql(u8, item_type.string, "reasoning")) continue;
                        if (first_reasoning_id == null) {
                            if (item.object.get("id")) |id_val| {
                                if (id_val == .string and id_val.string.len > 0) {
                                    first_reasoning_id = id_val.string;
                                }
                            }
                        }
                        if (first_encrypted == null) {
                            if (item.object.get("encrypted_content")) |enc_val| {
                                if (enc_val == .string and enc_val.string.len > 0) {
                                    first_encrypted = enc_val.string;
                                }
                            }
                        }
                        if (item.object.get("summary")) |summary_val| {
                            if (summary_val == .array) {
                                for (summary_val.array.items) |s_item| {
                                    if (s_item != .object) continue;
                                    const text_val = s_item.object.get("text") orelse continue;
                                    if (text_val != .string) continue;
                                    if (text_val.string.len == 0) continue;
                                    if (has_summary) {
                                        summary_buf.appendSlice(arena, "\n") catch continue;
                                    }
                                    summary_buf.appendSlice(arena, text_val.string) catch continue;
                                    has_summary = true;
                                }
                            }
                        }
                    }
                    if (first_reasoning_id) |rid| chunk.reasoning_id = rid;
                    if (first_encrypted) |enc| chunk.reasoning_encrypted_content = enc;
                    if (has_summary and summary_buf.items.len > 0) {
                        chunk.reasoning_content = summary_buf.items;
                    }
                }
            }

            if (response.object.get("usage")) |usage_val| {
                if (usage_val == .object) {
                    var usage: Usage = .{};
                    if (usage_val.object.get("input_tokens")) |pt| {
                        if (pt == .integer) usage.prompt_tokens = @intCast(pt.integer);
                    } else if (usage_val.object.get("prompt_tokens")) |pt| {
                        if (pt == .integer) usage.prompt_tokens = @intCast(pt.integer);
                    }
                    if (usage_val.object.get("output_tokens")) |ct| {
                        if (ct == .integer) usage.completion_tokens = @intCast(ct.integer);
                    } else if (usage_val.object.get("completion_tokens")) |ct| {
                        if (ct == .integer) usage.completion_tokens = @intCast(ct.integer);
                    }
                    if (usage_val.object.get("total_tokens")) |tt| {
                        if (tt == .integer) usage.total_tokens = @intCast(tt.integer);
                    } else {
                        usage.total_tokens = usage.prompt_tokens + usage.completion_tokens;
                    }
                    // preserve cache fields if relay adds them
                    if (usage_val.object.get("input_tokens_details")) |details| {
                        if (details == .object) {
                            if (details.object.get("cached_tokens")) |ct| {
                                if (ct == .integer) usage.cache_read_input_tokens = @intCast(ct.integer);
                            }
                        }
                    }
                    chunk.usage = usage;
                }
            }
            // If no explicit finish_reason yet but we have usage, default to stop
            if (chunk.finish_reason == null) chunk.finish_reason = .stop;
            return chunk;
        }
        // Ignored lifecycle events: response.created, response.in_progress, response.queued,
        // response.content_part.added/done, response.output_item.done, response.output_text.annotation.*
        return null;
    }
    pub fn callStreaming(
        self: *Agent,
        params: AgentCall,
        ctx: ?*anyopaque,
        callback: StreamCallback,
    ) CallError!CallResponse {
        self.log_fmt(.info, "[STREAM START] model={s} | messages={} | tools={} | streaming=true", .{
            self.model, params.messages.len, params.tools.len,
        });

        // Reset per-call Anthropic parser scratch state. The Agent is reused
        // across many calls; without this reset, the second call would see
        // stale input_tokens + a stuck `_usage_emitted` flag.
        self._anthropic_input_tokens = 0;
        self._anthropic_usage_emitted = false;
        self._anthropic_cache_read_tokens = 0;
        self._anthropic_cache_creation_tokens = 0;

        // 1. Build JSON body — dispatch on UrlStyle.
        var json_body: []u8 = undefined;
        if (std.mem.eql(u8, self.UrlStyle, "openai-response")) {
            json_body = self.buildJsonResponsesRequest(params, true) catch |err| {
                self.log_error("buildJsonResponsesRequest", err, null);
                return error.BuildRequestFailed;
            };
        } else if (std.mem.eql(u8, self.UrlStyle, "openai")) {
            json_body = self.buildJsonOpenAIRequest(params, true) catch |err| {
                self.log_error("buildJsonRequest", err, null);
                return error.BuildRequestFailed;
            };
        } else if (std.mem.eql(u8, self.UrlStyle, "anthropic")) {
            json_body = self.buildJsonAnthropicRequest(params, true) catch |err| {
                self.log_error("buildJsonAnthropicRequest", err, null);
                return error.BuildRequestFailed;
            };
        } else {
            json_body = self.buildJsonOpenAIRequest(params, true) catch |err| {
                self.log_error("buildJsonRequest", err, null);
                return error.BuildRequestFailed;
            };
        }

        defer self.allocator.free(json_body);

        const estimated_tokens = @divFloor(json_body.len + 3, 4);
        self.log_fmt(.info, "[TOKEN ESTIMATE] sending ~{} tokens ({} bytes)", .{ estimated_tokens, json_body.len });

        const json_preview_len = if (json_body.len > 500) 500 else json_body.len;
        const json_ellipsis = if (json_body.len > 500) "..." else "";
        self.log_fmt(.debug, "[STREAM REQUEST] JSON body ({} bytes): {s}{s}", .{ json_body.len, json_body[0..json_preview_len], json_ellipsis });

        // 2. Compose URL: baseUrl + endpoint.
        // Anthropic's correct API path is /v1/messages.
        // const endpoint = if (std.mem.eql(u8, self.UrlStyle, "anthropic"))
        //     "/v1/messages"
        // else
        //     "/chat/completions";
        const uri_str = std.mem.concat(self.allocator, u8, &.{self.baseUrl}) catch |err| {
            self.log_error("concat URI", err, null);
            return error.OutOfMemory;
        };
        defer self.allocator.free(uri_str);

        // Validate the URL scheme BEFORE handing it to libcurl. libcurl
        // returns CURLE_UNSUPPORTED_PROTOCOL (LocalError.UnsupportedProtocol)
        // for any URL it can't parse a scheme out of — which surfaces to
        // the workflow as `scanner.next failed ...: UnsupportedProtocol`
        // with no hint about *why*. Catching it here lets us name the
        // actual misconfiguration (empty base_url, missing scheme, typo
        // like "htttps://") instead of forcing the user to dig through
        // libcurl docs.
        const has_http_scheme = std.mem.startsWith(u8, uri_str, "http://") or
            std.mem.startsWith(u8, uri_str, "https://");
        if (!has_http_scheme) {
            const detail = std.fmt.allocPrint(
                self.allocator,
                "baseUrl+endpoint={s} has no http:// or https:// scheme — check api_key/model/base_url in config",
                .{uri_str},
            ) catch null;
            if (detail) |d| {
                if (self.last_error_message) |prev| self.allocator.free(prev);
                self.last_error_message = d;
            }
            self.log_fmt(.err, "[STREAM] unsupported URL scheme (must start with http:// or https://): {s}", .{uri_str});
            return error.InvalidUri;
        }

        // 3. Compose auth headers per UrlStyle.
        // Anthropic-style endpoints (native Anthropic API, relays like
        // api.minimax.io/anthropic, opencode.ai/zen/go) authenticate with
        // `x-api-key` + `anthropic-version: 2023-06-01`, NOT
        // `Authorization: Bearer` — mirroring the Test probe in
        // llm_test.zig. Sending only Bearer makes the upstream answer
        // `{"type":"error","error":{"type":"AuthError","message":
        // "Missing API key."}}` on the stream with 0 chunks, which the
        // SSE loop below surfaces as StreamInterrupted. OpenAI styles
        // keep the existing Bearer header byte-identical to before.
        const is_anthropic = std.mem.eql(u8, self.UrlStyle, "anthropic");
        var auth_value: ?[]u8 = null;
        defer if (auth_value) |v| self.allocator.free(v);
        if (!is_anthropic) {
            auth_value = std.mem.concat(self.allocator, u8, &.{ "Bearer ", self.apiKey }) catch |err| {
                self.log_error("concat auth", err, null);
                return error.OutOfMemory;
            };
        }

        // 4. Build the custom_http_client.Request.
        // OpenCode Go / Zen routing requires a stable per-conversation
        // `x-opencode-session` header (see Agent.sessionId doc). Without
        // it Console Go returns 200 + `{"type":"error",
        // "error":{"type":"MissingSessionID",...}}`, which the SSE loop
        // below surfaces as "stream ended without finish_reason after
        // 0 chunk(s)". Only emit when non-empty so non-Go providers
        // see a byte-identical request to before.
        var header_buf: [8]custom_http_client.Header = undefined;
        var header_count: usize = 0;
        header_buf[header_count] = .{ .name = "content-type", .value = "application/json" };
        header_count += 1;
        if (is_anthropic) {
            header_buf[header_count] = .{ .name = "anthropic-version", .value = "2023-06-01" };
            header_count += 1;
            if (self.apiKey.len > 0) {
                header_buf[header_count] = .{ .name = "x-api-key", .value = self.apiKey };
                header_count += 1;
            }
        } else {
            header_buf[header_count] = .{ .name = "authorization", .value = auth_value.? };
            header_count += 1;
        }
        header_buf[header_count] = .{ .name = "accept-encoding", .value = "identity" };
        header_count += 1;
        if (self.sessionId.len > 0) {
            header_buf[header_count] = .{ .name = "x-opencode-session", .value = self.sessionId };
            header_count += 1;
        }
        const req = custom_http_client.Request{
            .method = .POST,
            .url = uri_str,
            .headers = header_buf[0..header_count],
            .body = json_body,
        };

        // 5. Build Options. Standard libcurl timeouts — no custom watchdog.
        // CURLOPT_TIMEOUT_MS covers the total deadline; libcurl will fire it
        // when the server stalls without sending bytes.
        // user_agent is our own client id (not the generic
        // "custom_http_client/0.1.0" default) — OpenCode Go asks clients
        // to "identify itself with its own user agent ... rather than a
        // generic SDK or HTTP-library name".
        const options = custom_http_client.Options{
            .timeout_ms = self.httpOptions.read_timeout_ms,
            .connect_timeout_ms = 30_000,
            .follow_redirects = false,
            .verify_ssl = true,
            .user_agent = "nalar/1.0",
        };

        // 6. Open the streaming request.
        var stream = self.client.openStream(self.io, req, options) catch |err| {
            self.log_fmt(.err, "[STREAM] openStream failed: {s}", .{@errorName(err)});
            return error.HttpRequestFailed;
        };
        defer stream.deinit();

        const status = stream.statusCode();
        self.log_fmt(.info, "[STREAM] Connected with HTTP {d}", .{status});

        if (status >= 400) {
            self.log_fmt(.err, "[STREAM] HTTP error status: {d}", .{status});
            // Drain the error body so the workflow catch block can log the
            // server's actual reason (rate limit, auth, model not found,
            // context length, etc.) instead of just `error.ApiError`. Cap at
            // 4 KiB to avoid blowing up logs on a runaway server response;
            // truncated payloads get a trailing "..." marker.
            var body_buf: std.ArrayList(u8) = .empty;
            defer body_buf.deinit(self.allocator);
            const max_body_len: usize = 4096;
            drain_loop: while (body_buf.items.len < max_body_len) {
                const next_chunk = stream.next() catch break :drain_loop;
                if (next_chunk) |chunk| {
                    const remaining = max_body_len - body_buf.items.len;
                    const to_copy = @min(chunk.len, remaining);
                    body_buf.appendSlice(self.allocator, chunk[0..to_copy]) catch break :drain_loop;
                    if (chunk.len > to_copy) break :drain_loop;
                } else break :drain_loop;
            }
            const truncated = body_buf.items.len >= max_body_len;
            if (body_buf.items.len > 0) {
                const msg = std.fmt.allocPrint(
                    self.allocator,
                    "HTTP {d}: {s}{s}",
                    .{ status, body_buf.items, if (truncated) "..." else "" },
                ) catch null;
                if (msg) |m| {
                    if (self.last_error_message) |prev| self.allocator.free(prev);
                    self.last_error_message = m;
                }
            }
            return error.ApiError;
        }

        // 7. SSE scanner for line-by-line reads.
        var scanner = custom_http_client.StreamScanner.init(&stream, false);
        defer scanner.deinit();

        // 8. Aggregator.
        var aggregator = StreamingAggregator.init(self.allocator);
        defer aggregator.deinit();

        var line_arena = std.heap.ArenaAllocator.init(self.allocator);
        defer line_arena.deinit();

        // Raw SSE sample buffer. Populated when parse_stream_chunk returns null
        // AND chunk_count stays at 0 — lets us surface the server's actual
        // payload in the StreamInterrupted error message instead of hiding
        // everything behind "0 chunk(s)". Capped at 2 KiB; we keep the FIRST
        // bytes so the user sees the start of the stream (auth errors and
        // framework-specific envelopes tend to appear there).
        var raw_sse_sample: std.ArrayList(u8) = .empty;
        defer raw_sse_sample.deinit(self.allocator);
        const max_raw_sse_sample_len: usize = 2048;

        var chunk_count: usize = 0;
        var stream_ended_cleanly = false;

        // 9. SSE loop. The scanner's inferred error set is wider than
        // CallError (it includes libcurl's LocalError variants like
        // DnsError / TlsError / OperationTimedOut), so we use a
        // `catch` that maps any scanner error to a CallError variant
        // and returns — instead of `try`, which would fail to propagate
        // errors outside CallError.
        //
        // `scanner.next()` can return null for two reasons:
        //   (a) the worker has finished cleanly (clean EOF); or
        //   (b) the polling budget elapsed without a chunk arriving.
        // `StreamScanner` does NOT distinguish the two — both return
        // null. Reasoning-model LLMs (Claude extended thinking, OpenAI
        // o1/o3, DeepSeek R1) routinely pause 30-60s+ between chunks,
        // so a polling-budget return would otherwise produce a spurious
        // `StreamInterrupted` on a healthy stream.
        //
        // Mitigations:
        //   - `custom_http_client.StreamScanner.next()` was bumped from
        //     5s to 300s in commit `…` (matches libcurl's
        //     CURLOPT_TIMEOUT_MS) — fixes the common case.
        //   - This loop treats a null as "give the worker one more
        //     chance" — call next() again. If the worker has truly
        //     finished, the second call returns null immediately. If
        //     the worker is still going, the second call blocks until
        //     the next chunk or the libcurl timeout.
        var scanner_null_count: u32 = 0;
        while (true) {
            // Cancellation check — the only place a MID-stream stop can be
            // observed. The workflow's loop-top check
            // (`runAgenticMultiStepnew`) runs after this function returns, so
            // without this the cancel is not noticed until the response has
            // finished; that delay is the "Stop still waits ~1s" symptom.
            //
            // `stream.cancel()` is essential, not belt-and-braces: the
            // `defer stream.deinit()` below joins the libcurl worker, and the
            // worker only samples the cancelled flag while it is being handed
            // body bytes. Cancelling here makes the worker abort on the very
            // next chunk instead of after the 64-slot response queue fills.
            if (params.cancel_fn) |should_cancel| {
                if (should_cancel()) {
                    stream.cancel();
                    self.log_fmt(.info, "[STREAM] cancelled by caller after {} chunk(s)", .{chunk_count});
                    return error.Cancelled;
                }
            }
            const next_result = scanner.next() catch |err| {
                // Classify cancellation BEFORE anything else. A cancel aborts
                // the transfer, which libcurl reports as a transport error
                // (CURLE_WRITE_ERROR → WriteError → StreamInterrupted). The
                // workflow's generic catch turns every non-Cancelled error into
                // a RETRY with a fresh request — silently re-running a turn the
                // user explicitly stopped is far worse than the latency being
                // fixed here.
                if (err == error.Cancelled) return error.Cancelled;
                if (params.cancel_fn) |should_cancel| {
                    if (should_cancel()) {
                        stream.cancel();
                        return error.Cancelled;
                    }
                }
                self.log_fmt(.err, "[STREAM] scanner.next failed: {s}", .{@errorName(err)});
                // Surface the underlying scanner error name to the workflow
                // catch block so it can tell apart a parse failure from a
                // network drop from an EOF mid-line, instead of all collapsing
                // into "StreamInterrupted". Special-case `UnsupportedProtocol`
                // when the URL was https:// — the vendored libcurl in
                // kabelweb repo vendor/curl/ is built with
                // --disable-ssl (see scripts/build-vendor-curl.sh:8-18), so
                // the only way an https URL produces CURLE_UNSUPPORTED_PROTOCOL
                // is that the vendored libcurl literally doesn't know the
                // scheme. A bare `UnsupportedProtocol` is otherwise opaque.
                const detail: ?[]u8 = if (err == error.UnsupportedProtocol and
                    std.mem.startsWith(u8, uri_str, "https://"))
                    std.fmt.allocPrint(
                        self.allocator,
                        "scanner.next failed after {d} chunk(s): UnsupportedProtocol — vendored libcurl was built --disable-ssl (see kabelweb/scripts/build-vendor-curl.sh); URL must be http:// until OpenSSL is vendored, or change base_url in ~/.config/nalar/config.json to an http:// endpoint",
                        .{chunk_count},
                    ) catch null
                else
                    std.fmt.allocPrint(
                        self.allocator,
                        "scanner.next failed after {d} chunk(s): {s}",
                        .{ chunk_count, @errorName(err) },
                    ) catch null;
                if (detail) |d| {
                    if (self.last_error_message) |prev| self.allocator.free(prev);
                    self.last_error_message = d;
                }
                return error.StreamInterrupted;
            };
            if (next_result) |line| {
                scanner_null_count = 0;
                if (self.parse_sse_line(line)) |data| {
                    _ = line_arena.reset(.retain_capacity);
                    if (self.parse_stream_chunk(data, line_arena.allocator())) |chunk| {
                        chunk_count += 1;
                        callback(ctx, chunk);
                        aggregator.process_chunk(chunk) catch {};
                    } else {
                        self.log_fmt(.err, "[STREAM] parse_stream_chunk returned null for: {s}", .{data});
                        // Capture the raw SSE data line for the final-error
                        // message — only while chunk_count == 0 (i.e. the
                        // server's first lines are still unparsed). Once we
                        // successfully parse ANY chunk we know the format
                        // is one we understand, so additional raw samples
                        // would just be noise.
                        if (chunk_count == 0 and raw_sse_sample.items.len < max_raw_sse_sample_len) {
                            raw_sse_sample.appendSlice(self.allocator, data) catch {};
                            raw_sse_sample.append(self.allocator, '\n') catch {};
                        }
                    }
                } else {
                    // parse_sse_line returned null: this line isn't a `data: …`
                    // payload. Could be `event: …` (Anthropic) or `id:`/`retry:`
                    // (SSE boilerplate) or — more importantly for diagnosis —
                    // a non-SSE response the server returned anyway (e.g. a
                    // 404 HTML body when the URL was wrong). Capture the full
                    // raw line so the final error message reveals the actual
                    // server output, not just "0 chunk(s)".
                    if (chunk_count == 0 and raw_sse_sample.items.len < max_raw_sse_sample_len) {
                        raw_sse_sample.appendSlice(self.allocator, line) catch {};
                        raw_sse_sample.append(self.allocator, '\n') catch {};
                    }
                }
                continue;
            }
            // next() returned null. The worker MIGHT have finished
            // (clean EOF) OR the polling budget might have elapsed
            // (worker still going). One more call lets us tell apart
            // the two: a clean EOF returns null immediately on the
            // second call, a polling timeout blocks until the next
            // chunk. We cap at 2 nulls in a row to be defensive —
            // if the second call also returns null, the worker
            // definitely finished.
            scanner_null_count += 1;
            if (scanner_null_count >= 2) break;
        }

        // A cancel can also land in the window between the final chunk and the
        // loop exit above. Classify it before the "ended without
        // finish_reason" diagnostics below, which would otherwise turn a
        // user-initiated stop into a StreamEmpty/StreamInterrupted retry.
        if (params.cancel_fn) |should_cancel| {
            if (should_cancel()) {
                stream.cancel();
                return error.Cancelled;
            }
        }

        // 10. The scanner returned null twice in a row, which means
        // the worker has definitively finished (clean EOF) without
        // sending a finish_reason chunk. Treat as a mid-stream death.
        if (aggregator.finish_reason == null) {
            self.log_fmt(.err, "[STREAM] stream ended without finish_reason (chunks={})", .{chunk_count});
            // Tell the workflow catch block HOW the stream died and roughly
            // how far it got, so the user can distinguish "the server cut
            // us off after a few tokens" from "it never started streaming
            // at all" — both surface as StreamInterrupted today.
            //
            // When chunk_count stayed at 0 BUT we received SOME SSE lines,
            // the server is speaking a format we don't understand (most
            // commonly: a profile configured with the wrong `url_style`,
            // e.g. an OpenAI-compatible relay configured as `anthropic`).
            // In that case we fold a truncated raw sample into the error
            // message so the user can SEE what the server actually sent,
            // instead of staring at an opaque "0 chunk(s)".
            const sample_truncated = raw_sse_sample.items.len >= max_raw_sse_sample_len;
            const sample_for_msg: []const u8 = if (raw_sse_sample.items.len > 0)
                if (sample_truncated)
                    raw_sse_sample.items[0 .. max_raw_sse_sample_len - 3] ++ "..."
                else
                    raw_sse_sample.items
            else
                "";
            const detail: ?[]u8 = if (sample_for_msg.len > 0)
                std.fmt.allocPrint(
                    self.allocator,
                    "stream ended without finish_reason after {d} chunk(s); first server lines: {s}{s}",
                    .{
                        chunk_count,
                        sample_for_msg,
                        // Console Go gateway error when `x-opencode-session`
                        // was missing. Point at the fix instead of leaving
                        // the user to decode the raw JSON envelope.
                        if (std.mem.indexOf(u8, sample_for_msg, "MissingSessionID") != null)
                            " [hint: provider requires x-opencode-session header — Agent.sessionId was empty or not sent; see https://opencode.ai/docs/go/#where-can-i-use-it]"
                        else
                            "",
                    },
                ) catch null
            else
                std.fmt.allocPrint(
                    self.allocator,
                    "stream ended without finish_reason after {d} chunk(s)",
                    .{chunk_count},
                ) catch null;
            if (detail) |d| {
                if (self.last_error_message) |prev| self.allocator.free(prev);
                self.last_error_message = d;
            }
            return error.StreamInterrupted;
        }
        stream_ended_cleanly = true;

        callback(ctx, .{ .done = true });

        // 11. Finalize.
        const stream_response = aggregator.finalize() catch |err| {
            self.log_error("finalize streaming response", err, null);
            return error.AllocFailed;
        };

        // 12. Cost tracking (matches Agent.zig's pricing).
        // NOTE (2026-08-13, fix-anthropic-total-tokens plan): this
        // formula treats `prompt_tokens` as if it were billed at the
        // full input rate. After Task 2 of that plan, Anthropic
        // `prompt_tokens` now ALSO includes `cache_read_input_tokens`
        // (billed at ~0.1× input rate) and `cache_creation_input_tokens`
        // (billed at ~1.25× input rate), so this formula overcharges
        // Anthropic cached-read calls by ~10× and undercharges cache
        // writes by ~25%. The breakdown is preserved on
        // `Usage.cache_*_input_tokens` so a future PR can fix the
        // formula properly. OUT OF SCOPE for this plan.
        const prompt_cost = @as(f64, @floatFromInt(stream_response.usage.prompt_tokens)) * 0.000003;
        const completion_cost = @as(f64, @floatFromInt(stream_response.usage.completion_tokens)) * 0.000015;
        const total_cost = prompt_cost + completion_cost;
        self.log_fmt(.info, "[STREAM] Complete - Prompt: {} | Completion: {} | Total: {} | Est. cost: ${d:.4}", .{
            stream_response.usage.prompt_tokens,
            stream_response.usage.completion_tokens,
            stream_response.usage.total_tokens,
            total_cost,
        });

        return stream_response;
    }

    pub fn deinit(self: *Agent) void {
        if (self.last_error_message) |msg| {
            self.allocator.free(msg);
            self.last_error_message = null;
        }
        self.client.deinit();
    }
};

test "VideoUrl jsonStringify emits video_url url" {
    const alloc = std.testing.allocator;
    const part = ContentPart{ .part_type = "video_url", .video_url = .{ .url = "data:video/mp4;base64,AAAA" } };
    const s = try std.json.Stringify.valueAlloc(alloc, part, .{});
    defer alloc.free(s);
    try std.testing.expect(std.mem.indexOf(u8, s, "video_url") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "data:video/mp4;base64,AAAA") != null);
}

test "isSupportedVideoMime allowlists full video set" {
    try std.testing.expect(isSupportedVideoMime("video/mp4"));
    try std.testing.expect(isSupportedVideoMime("video/webm"));
    try std.testing.expect(isSupportedVideoMime("video/quicktime"));
    try std.testing.expect(isSupportedVideoMime("video/x-msvideo"));
    try std.testing.expect(isSupportedVideoMime("video/x-matroska"));
    try std.testing.expect(!isSupportedVideoMime("video/ogg"));
    try std.testing.expect(!isSupportedVideoMime("image/png"));
}

test "videoMimeFromDataUrl extracts mime" {
    const m = videoMimeFromDataUrl("data:video/mp4;base64,AAAA");
    try std.testing.expect(m != null);
    try std.testing.expectEqualStrings("video/mp4", m.?);
    try std.testing.expect(videoMimeFromDataUrl("data:image/png;base64,AAAA") == null);
    try std.testing.expect(videoMimeFromDataUrl("data:video/mp4,AAAA") == null);
}

test "ResponsesInputContent input_video serializes video_url" {
    const alloc = std.testing.allocator;
    const c = ResponsesInputContent{ .content_type = "input_video", .video_url = "data:video/webm;base64,GkXf" };
    const s = try std.json.Stringify.valueAlloc(alloc, c, .{});
    defer alloc.free(s);
    try std.testing.expect(std.mem.indexOf(u8, s, "input_video") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "data:video/webm") != null);
}

test "AnthropicContentBlock video serializes type video" {
    const alloc = std.testing.allocator;
    const b = AnthropicContentBlock{ .video = .{ .source_type = "url", .url_or_data = "data:video/mp4;base64,AAAA" } };
    const s = try std.json.Stringify.valueAlloc(alloc, b, .{});
    defer alloc.free(s);
    try std.testing.expect(std.mem.indexOf(u8, s, "\"video\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "data:video/mp4") != null);
}
