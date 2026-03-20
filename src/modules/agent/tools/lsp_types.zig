const std = @import("std");

// =============================================================================
// LSP Definition Tool Types
// =============================================================================

pub const LspDefinitionInput = struct {
    lsp: []const u8, // LSP binary name (e.g., "zls", "pyls") or absolute path
    root_dir: []const u8, // Absolute path to project root directory
    file_path: []const u8, // Absolute path to file
    line: u32, // 0-indexed line number
    character: u32, // 0-indexed character position
    max_output: ?u32 = 100, // Maximum number of results to return (default: 100)
};

/// Represents a single LSP Location or LocationLink
pub const LspLocation = struct {
    file_path: []u8, // Absolute path to definition file
    line: u32, // 0-indexed line number (start position)
    character: u32, // 0-indexed character position (start position)
    // Optional fields for LocationLink
    origin_line: ?u32 = null, // Line where cursor was (for LocationLink)
    origin_character: ?u32 = null, // Character where cursor was (for LocationLink)
    end_line: ?u32 = null, // End line of the definition range
    end_character: ?u32 = null, // End character of the definition range
};

/// LSP definition response can contain multiple locations
/// Result can be: null, single Location, Location[], or LocationLink[]
pub const LspDefinitionOutput = struct {
    definitions: []LspLocation, // Array of definition locations (empty if not found)
    found: bool, // true if at least one definition found

    /// Free all allocated memory in definitions array
    pub fn deinit(self: *const LspDefinitionOutput, allocator: std.mem.Allocator) void {
        for (self.definitions) |loc| {
            allocator.free(loc.file_path);
        }
        allocator.free(self.definitions);
    }
};

// =============================================================================
// LSP References Tool Types
// =============================================================================

pub const LspReferencesInput = struct {
    lsp: []const u8, // LSP binary name (e.g., "zls", "pyls") or absolute path
    root_dir: []const u8, // Absolute path to project root directory
    file_path: []const u8, // Absolute path to file
    line: u32, // 0-indexed line number
    character: u32, // 0-indexed character position
    include_declaration: bool = true, // Include declaration in results
    max_output: ?u32 = 100, // Maximum number of results to return (default: 100)
};

/// LSP references response is always Location[]
/// Reuse LspDefinitionOutput since structure is identical
pub const LspReferencesOutput = LspDefinitionOutput;

// =============================================================================
// LSP Workspace/Symbol Tool Types
// =============================================================================

pub const LspWorkspaceSymbolInput = struct {
    lsp: []const u8, // LSP binary name (e.g., "zls", "pyls") or absolute path
    root_dir: []const u8, // Absolute path to project root directory
    query: []const u8, // Search query string
    max_output: ?u32 = 100, // Maximum number of results to return (default: 100)
};

/// Represents a single workspace symbol
pub const LspWorkspaceSymbol = struct {
    name: []u8, // Symbol name
    kind: u32, // Symbol kind (LSP SymbolKind enum value)
    file_path: []u8, // Absolute path to file
    line: u32, // 0-indexed line number
    character: u32, // 0-indexed character position
    container_name: ?[]u8 = null, // Optional parent container name

    /// Free all allocated memory
    pub fn deinit(self: *const LspWorkspaceSymbol, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.file_path);
        if (self.container_name) |cn| {
            allocator.free(cn);
        }
    }
};

/// LSP workspace/symbol response
pub const LspWorkspaceSymbolOutput = struct {
    symbols: []LspWorkspaceSymbol, // Array of symbols (empty if not found)
    found: bool, // true if at least one symbol found

    /// Free all allocated memory in symbols array
    pub fn deinit(self: *const LspWorkspaceSymbolOutput, allocator: std.mem.Allocator) void {
        for (self.symbols) |sym| {
            sym.deinit(allocator);
        }
        allocator.free(self.symbols);
    }
};

// =============================================================================
// LSP Document Symbol Tool Types
// =============================================================================

pub const LspDocumentSymbolInput = struct {
    lsp: []const u8, // LSP binary name (e.g., "zls", "pyls") or absolute path
    root_dir: []const u8, // Absolute path to project root directory
    file_path: []const u8, // Absolute path to file
    max_output: ?u32 = 100, // Maximum number of results to return (default: 100)
};

/// Represents a single document symbol (can be hierarchical)
pub const LspDocumentSymbol = struct {
    name: []u8, // Symbol name
    kind: u32, // Symbol kind (LSP SymbolKind enum value)
    detail: ?[]u8 = null, // Optional detail (e.g., function signature)
    line: u32, // 0-indexed line number (start of range)
    character: u32, // 0-indexed character position (start of range)
    end_line: ?u32 = null, // End line of the range
    end_character: ?u32 = null, // End character of the range
    selection_line: ?u32 = null, // Line of selection range
    selection_character: ?u32 = null, // Character of selection range
    children: ?[]LspDocumentSymbol = null, // Nested symbols

    /// Free all allocated memory recursively
    pub fn deinit(self: *const LspDocumentSymbol, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        if (self.detail) |d| {
            allocator.free(d);
        }
        if (self.children) |children| {
            for (children) |child| {
                child.deinit(allocator);
            }
            allocator.free(children);
        }
    }
};

/// LSP document/symbol response
pub const LspDocumentSymbolOutput = struct {
    symbols: []LspDocumentSymbol, // Array of symbols (empty if not found)
    found: bool, // true if at least one symbol found

    /// Free all allocated memory in symbols array
    pub fn deinit(self: *const LspDocumentSymbolOutput, allocator: std.mem.Allocator) void {
        for (self.symbols) |sym| {
            sym.deinit(allocator);
        }
        allocator.free(self.symbols);
    }
};

// =============================================================================
// LSP Hover Tool Types
// =============================================================================

pub const LspHoverInput = struct {
    lsp: []const u8, // LSP binary name (e.g., "zls", "pyls") or absolute path
    root_dir: []const u8, // Absolute path to project root directory
    file_path: []const u8, // Absolute path to file
    line: u32, // 0-indexed line number
    character: u32, // 0-indexed character position
};

/// Represents hover information
pub const LspHoverOutput = struct {
    contents: ?[]u8 = null, // Hover contents (markdown or plain text)
    line: ?u32 = null, // Start line of hover range
    character: ?u32 = null, // Start character of hover range
    end_line: ?u32 = null, // End line of hover range
    end_character: ?u32 = null, // End character of hover range
    found: bool, // true if hover info was found

    /// Free all allocated memory
    pub fn deinit(self: *const LspHoverOutput, allocator: std.mem.Allocator) void {
        if (self.contents) |c| {
            allocator.free(c);
        }
    }
};
