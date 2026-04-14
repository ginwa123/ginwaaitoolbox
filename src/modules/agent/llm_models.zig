pub const LLMModels = struct {
    name: []const u8,
    description: []const u8,
    token_count: u32,
};

pub const MINIMAX_2_7 = LLMModels{
    .name = "MiniMax-M2.7",
    .description = "Minimax-M2.7 is a large language model trained by Anthropic. It is a variant of the MiniMax model, which is a transformer-based language model. It is trained on a diverse range of text sources, including books, articles, and websites.",
    .token_count = 2000000,
};

fn is_do_compact(token_count: u32, max_capicity_token: u32) bool {
    // auto compact 80% of tokens
    const threshold = max_capicity_token * 8 / 10; // 80%
    return token_count >= threshold;
}
