const std = @import("std");
const httpz = @import("httpz");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Create the module with httpz import
    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Add httpz dependency
    const http_dep = b.dependency("http", .{
        .target = target,
        .optimize = optimize,
    });
    mod.addImport("httpz", http_dep.module("httpz"));

    // Create executable
    const exe = b.addExecutable(.{
        .name = "desktop-backend",
        .root_module = mod,
    });
    exe.linkLibC();

    // Install executable
    b.installArtifact(exe);
}

test {
    _ = @import("src/main.zig");
}