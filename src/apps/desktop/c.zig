// Shared C imports for Clay and Raylib
// This ensures all modules use the SAME type definitions

pub const clay = @cImport(@cInclude("clay.h"));
pub const raylib = @cImport(@cInclude("raylib.h"));
