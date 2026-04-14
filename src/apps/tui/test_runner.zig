test {
    _ = @import("network/sse_test.zig");
    _ = @import("display/response_test.zig");
    _ = @import("display/tool_results_change_agent_test.zig");
    // streaming_test.zig tests the response.zig module with streaming context
    // It validates that extract_content_result correctly handles plain text vs XML
    _ = @import("network/streaming_test.zig");
}
