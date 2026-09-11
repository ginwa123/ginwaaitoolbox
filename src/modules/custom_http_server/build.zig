const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Executable
    const exe = b.addExecutable(.{
        .name = "custom_http_server",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.root_module.linkSystemLibrary("c", .{});
    // TLS (`http2/tls.zig`, `http2/tls_cert.zig`) uses OpenSSL directly: Zig 0.16
    // ships no TLS *server* (std.crypto.tls is client-only, and its client has no
    // ALPN support), so a browser-facing HTTP/2 needs a real TLS stack. This adds
    // no new product dependency — the app already links ssl/crypto for libpq and
    // libcurl — it only makes this module's standalone build self-contained.
    exe.root_module.linkSystemLibrary("ssl", .{});
    exe.root_module.linkSystemLibrary("crypto", .{});
    b.installArtifact(exe);

    // Importable module for sibling packages (e.g. custom_http_client's
    // TestServer fixtures do `@import("custom_http_server")` and use
    // GinwaServer / Address / HttpContext / HttpRequest / HttpResponse —
    // all re-exported by src/http_server.zig, whose transitive closure
    // is self-contained: std + builtin + relative *.zig siblings only).
    const server_mod = b.addModule("custom_http_server", .{
        .root_source_file = b.path("src/http_server.zig"),
        .target = target,
        .optimize = optimize,
    });
    server_mod.linkSystemLibrary("c", .{});
    server_mod.linkSystemLibrary("ssl", .{});
    server_mod.linkSystemLibrary("crypto", .{});
    server_mod.link_libc = true;

    // Run step
    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // Test module - test_runner.zig imports root and all test files
    const test_mod = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/test_runner.zig"),
            .target = target,
        }),
    });
    test_mod.root_module.linkSystemLibrary("c", .{});
    test_mod.root_module.linkSystemLibrary("ssl", .{});
    test_mod.root_module.linkSystemLibrary("crypto", .{});
    // `linkSystemLibrary` resolves against the linker search path; on Linux the
    // system libssl/libcrypto live in /usr/lib, which Zig does not add by default
    // for a glibc target (the root build.zig does the same for its test module).
    if (target.result.os.tag == .linux) {
        test_mod.root_module.addLibraryPath(.{ .cwd_relative = "/usr/lib" });
    }
    const run_test_mod = b.addRunArtifact(test_mod);

    // Test step runs test module
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_test_mod.step);
}
