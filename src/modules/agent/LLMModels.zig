const std = @import("std");

pub const LLMModels = struct {
    name: []const u8,
    description: []const u8,
    token_count: u32,
};

pub const MINIMAX_2_7 = LLMModels{
    .name = "MiniMax-M2.7",
    .description = "Minimax-M2.7 is a large language model trained by Anthropic. It is a variant of the MiniMax model, which is a transformer-based language model. It is trained on a diverse range of text sources, including books, articles, and websites.",
    .token_count = 200000,
};

pub const MINIMAX_3 = LLMModels{
    .name = "MiniMax-M3",
    .description = "Minimax-M3 is a large language model trained by Anthropic. It is a variant of the MiniMax model, which is a transformer-based language model. It is trained on a diverse range of text sources, including books, articles, and websites.",
    .token_count = 500000,
};

/// Get model token count by model name string
pub fn getModelTokenCount(model_name: []const u8) u32 {
    if (std.mem.eql(u8, model_name, MINIMAX_2_7.name)) {
        return MINIMAX_2_7.token_count;
    }

    if (std.mem.eql(u8, model_name, MINIMAX_3.name)) {
        return MINIMAX_3.token_count;
    }
    // Default fallback (e.g., 128k tokens)
    return 200000;
}

pub fn isDoCompact(token_count: u32, max_capicity_token: u32) bool {
    // auto compact 80% of tokens
    const threshold = max_capicity_token * 8 / 10; // 80%
    return token_count >= threshold;
}
