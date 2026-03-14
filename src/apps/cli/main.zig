const std = @import("std");
const tree1 = @import("nalarcore");
const parseArgs = @import("args.zig").parseArgs;

/// Get the database path: ~/.config/zigginagentic/agent.db
fn getDbPath(allocator: std.mem.Allocator) ![:0]const u8 {
    const home = std.posix.getenv("HOME") orelse {
        return error.HomeNotFound;
    };

    const config_dir = try std.fs.path.join(allocator, &[_][]const u8{
        home,
        ".config",
        "zigginagentic",
    });
    defer allocator.free(config_dir);

    std.fs.makeDirAbsolute(config_dir) catch |err| {
        if (err != error.PathAlreadyExists) {
            return err;
        }
    };

    const db_path = try std.fs.path.join(allocator, &[_][]const u8{
        config_dir,
        "agent.db",
    });
    defer allocator.free(db_path);

    return try allocator.dupeZ(u8, db_path);
}

/// Explain the current project using LLM
fn explainProject(allocator: std.mem.Allocator, llm_config: *tree1.config.LlmConfig) !void {
    // Get current working directory to explain
    const cwd_dir = std.fs.cwd();
    const cwd_path = try cwd_dir.realpathAlloc(allocator, ".");
    defer allocator.free(cwd_path);

    // Build a prompt asking the LLM to explain the project
    const prompt = try std.fmt.allocPrint(allocator,
        \\Explain this project in detail. I need to understand:
        \\1. What is this project about?
        \\2. What are the main components and their purposes?
        \\3. How is the code organized?
        \\4. What technologies/frameworks are used?
        \\
        \\Project directory: {s}
        \\
        \\Please provide a comprehensive explanation.
    , .{cwd_path});
    defer allocator.free(prompt);

    std.debug.print("Calling LLM to explain project...\n", .{});

    // Initialize agent directly without global logger
    var http_client = std.http.Client{ .allocator = allocator };
    defer http_client.deinit();
    
    // We need a logger - create minimal one inline
    var logger = tree1.logger.Logger.init(allocator, .{
        .min_level = .info,
        .output_mode = .stdout,
        .include_location = false,
        .include_request_id = false,
        .include_timestamp = false,
    });
    defer logger.deinit();

    var agent = tree1.agent.Agent{
        .allocator = allocator,
        .httpClient = http_client,
        .logger = &logger,
    };
    agent.apiKey = llm_config.api_key;
    agent.baseUrl = llm_config.base_url;
    agent.model = llm_config.model;
    agent.thinkingEnabled = true;

    // Create messages array
    const messages = try allocator.alloc(tree1.agent.AgentMessage, 2);
    defer allocator.free(messages);

    messages[0] = .{
        .role = .system,
        .content = "You are a helpful code assistant.",
    };
    messages[1] = .{
        .role = .user,
        .content = prompt,
    };

    // Call LLM (non-streaming for CLI output)
    const response = try agent.call(tree1.agent.AgentCall{
        .messages = messages,
        .tools = &.{},
        .temperature = 0.4,
        .max_tokens = 4096,
    });

    // Print the response - content is optional so handle that
    const content = response.content orelse "(no content)";
    std.debug.print("\n=== Project Explanation ===\n", .{});
    std.debug.print("{s}\n", .{content});
    std.debug.print("===========================\n", .{});
}

/// Send a message to an existing session
fn sendToSession(
    allocator: std.mem.Allocator,
    session_id: []const u8,
    message: []const u8,
    llm_config: *tree1.config.LlmConfig,
    db: *tree1.sqlite.SqliteBackend,
) !void {
    std.debug.print("Sending message to session {s}: {s}\n", .{ session_id, message });

    // TODO: Load session history from database and continue conversation
    _ = db;

    std.debug.print("Calling LLM...\n", .{});

    // Initialize agent directly without global logger
    var http_client = std.http.Client{ .allocator = allocator };
    defer http_client.deinit();
    
    // Create minimal logger - init() returns Logger directly, not error union
    var logger = tree1.logger.Logger.init(allocator, .{
        .min_level = .info,
        .output_mode = .stdout,
        .include_location = false,
        .include_request_id = false,
        .include_timestamp = false,
    });
    defer logger.deinit();

    var agent = tree1.agent.Agent{
        .allocator = allocator,
        .httpClient = http_client,
        .logger = &logger,
    };
    agent.apiKey = llm_config.api_key;
    agent.baseUrl = llm_config.base_url;
    agent.model = llm_config.model;
    agent.thinkingEnabled = true;

    // Create messages array
    const messages = try allocator.alloc(tree1.agent.AgentMessage, 2);
    defer allocator.free(messages);

    messages[0] = .{
        .role = .system,
        .content = "You are a helpful AI assistant continuing a conversation.",
    };
    messages[1] = .{
        .role = .user,
        .content = message,
    };

    // Call LLM
    const response = try agent.call(tree1.agent.AgentCall{
        .messages = messages,
        .tools = &.{},
        .temperature = 0.4,
        .max_tokens = 4096,
    });

    // Print the response - content is optional so handle that
    const content = response.content orelse "(no content)";
    std.debug.print("\n=== Response ===\n", .{});
    std.debug.print("{s}\n", .{content});
    std.debug.print("=================\n", .{});
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const allocator = gpa.allocator();

    // Parse command line arguments (skip program name)
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    // Convert to slice of null-terminated strings for parseArgs
    const args_slice = try allocator.alloc([:0]const u8, args.len - 1);
    defer allocator.free(args_slice);

    for (args[1..], 0..) |arg, i| {
        args_slice[i] = try allocator.dupeZ(u8, arg);
    }
    defer {
        for (args_slice) |arg| {
            allocator.free(arg);
        }
    }

    // Parse the arguments
    const cmd = parseArgs(args_slice) catch {
        std.debug.print("Error parsing arguments\n", .{});
        std.debug.print("Usage:\n", .{});
        std.debug.print("  nalarcore-cli \"explain-this-project\"\n", .{});
        std.debug.print("  nalarcore-cli \"session_id\" \"message\"\n", .{});
        return error.InvalidArgs;
    };

    // Load LLM config
    var llm_config = try tree1.config.LlmConfig.init(allocator, null);
    defer llm_config.deinit();

    // Validate config - returns void on success, error on failure
    llm_config.validate() catch {
        std.debug.print("Error: LLM config not valid. Please check your config file.\n", .{});
        std.debug.print("Please set up ~/.config/zigginagentic/config.json\n", .{});
        std.debug.print("Required fields: api_key, model, base_url\n", .{});
        return error.InvalidConfig;
    };

    // Get database path
    const db_path = try getDbPath(allocator);
    defer allocator.free(db_path);

    // Initialize database (for future session support)
    var db: tree1.sqlite.SqliteBackend = .{};
    defer db.deinit();
    try db.init(db_path);

    // Handle the command
    switch (cmd.mode) {
        .explain_project => {
            try explainProject(allocator, &llm_config);
        },
        .session => {
            try sendToSession(allocator, cmd.session_id, cmd.message, &llm_config, &db);
        },
    }
}
