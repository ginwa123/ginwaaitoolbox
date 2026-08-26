// src/apps/desktop_app/platform/linux_gfx_test.zig
//
// Static-contract tests for the Linux WebKitGTK graphics environment
// pinning (desktop scroll-perf plan, Task 1).
//
// Why static tests: GTK/WebKit need a display server to actually run,
// so we can't unit-test "did the compositor come up accelerated?".
// What we CAN lock in is the source-level contract:
//
//   1. linux.zig defines an `applyLinuxGfxEnv` helper that sets the
//      WebKitGTK acceleration env vars.
//   2. The helper is CALLED inside `nalar_webview_create` BEFORE
//      `gtk_init` — env vars read at GLib/WebKit init are useless if
//      set after init has already consumed them.
//   3. The helper respects user overrides (checks getenv before setenv).
//   4. webview.Config carries a `gfx_preset` field so callers can pick
//      auto / compat / debug without editing platform code.
//
// Pattern follows git_pr_create_test.zig: read the source file as text
// and assert on its content. Brittle to refactors, but exactly right
// for "this call must exist above that call" ordering contracts.

const std = @import("std");
const testing = std.testing;
const text_normalize = @import("helpers").text_normalize;

const LINUX_PATH = "src/apps/desktop_app/platform/linux.zig";
const CONFIG_PATH = "src/apps/desktop_app/webview.zig";

fn readSource(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const raw = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        path,
        allocator,
        .limited(256 * 1024),
    );
    const normalized = try text_normalize.normalizeLineEndings(allocator, raw);
    allocator.free(raw);
    return normalized;
}

test "linux.zig defines applyLinuxGfxEnv with WebKitGTK accel vars" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, LINUX_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "fn applyLinuxGfxEnv") == null) {
        std.debug.print("!! linux.zig missing applyLinuxGfxEnv helper !!\n", .{});
        return error.GfxHelperMissing;
    }
    // The two WebKitGTK renderer/compositing pins. Without these,
    // WebKitGTK silently falls back to software rendering on many
    // drivers -> slow scrolling vs Chrome.
    inline for (.{
        "WEBKIT_DISABLE_DMABUF_RENDERER",
        "WEBKIT_FORCE_COMPOSITING_MODE",
    }) |var_name| {
        if (std.mem.indexOf(u8, source, var_name) == null) {
            std.debug.print("!! linux.zig does not reference {s} !!\n", .{var_name});
            return error.GfxVarMissing;
        }
    }
}

test "applyLinuxGfxEnv is called BEFORE gtk_init in nalar_webview_create" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, LINUX_PATH);
    defer allocator.free(source);

    const call_site = std.mem.indexOf(u8, source, "applyLinuxGfxEnv(cfg.gfx_preset)") orelse {
        std.debug.print("!! nalar_webview_create never calls applyLinuxGfxEnv(preset) !!\n", .{});
        return error.GfxCallMissing;
    };
    const gtk_init_site = std.mem.indexOf(u8, source, "gtk_init(null, null);") orelse {
        std.debug.print("!! linux.zig lost its gtk_init call !!\n", .{});
        return error.GtkInitMissing;
    };
    if (call_site > gtk_init_site) {
        std.debug.print(
            "!! applyLinuxGfxEnv called AFTER gtk_init (offset {d} > {d}) — env vars would be read too late !!\n",
            .{ call_site, gtk_init_site },
        );
        return error.GfxCallAfterGtkInit;
    }
}

test "gfx env application respects existing user environment" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, LINUX_PATH);
    defer allocator.free(source);

    // The override check: only set a var when it isn't already present
    // in the process environ. Users debugging driver issues must be able
    // to launch with their own values.
    if (std.mem.indexOf(u8, source, "getenv") == null) {
        std.debug.print("!! applyLinuxGfxEnv does not consult getenv for user overrides !!\n", .{});
        return error.GfxOverrideCheckMissing;
    }
}

test "webview.Config exposes gfx_preset enum with auto default" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, CONFIG_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "gfx_preset") == null) {
        std.debug.print("!! webview.Config missing gfx_preset field !!\n", .{});
        return error.GfxPresetFieldMissing;
    }
    if (std.mem.indexOf(u8, source, "GfxPreset") == null) {
        std.debug.print("!! webview.zig missing GfxPreset enum type !!\n", .{});
        return error.GfxPresetEnumMissing;
    }
}

test "GfxPreset exposes an x11 variant that forces GDK_BACKEND=x11" {
    // The Linux 99% CPU bug (task_1787683960703_0, 2026-08-25) was a
    // WebKitGPUProcess silent failure on NVIDIA+Wayland. The fix is
    // `GDK_BACKEND=x11` set BEFORE gtk_init; this regression guard
    // locks in (a) the enum variant exists, (b) linux.zig's
    // applyLinuxGfxEnv sets GDK_BACKEND=x11 when the preset is .x11,
    // (c) the env var is set BEFORE gtk_init (else GDK ignores it),
    // and (d) the user can still override GDK_BACKEND via their own
    // environ (the helper must consult getenv first).
    const allocator = testing.allocator;
    const cfg_src = try readSource(allocator, CONFIG_PATH);
    defer allocator.free(cfg_src);
    const linux_src = try readSource(allocator, LINUX_PATH);
    defer allocator.free(linux_src);

    // (a) .x11 variant exists in the enum.
    if (std.mem.indexOf(u8, cfg_src, ".x11 = 3") == null and
        std.mem.indexOf(u8, cfg_src, ".x11,") == null)
    {
        std.debug.print(
            "!! webview.zig GfxPreset missing .x11 variant — add it to the enum !!\n",
            .{},
        );
        return error.X11GfxPresetMissing;
    }

    // (b) applyLinuxGfxEnv sets GDK_BACKEND=x11 in the .x11 branch.
    if (std.mem.indexOf(u8, linux_src, "\"GDK_BACKEND\"") == null or
        std.mem.indexOf(u8, linux_src, "\"x11\"") == null)
    {
        std.debug.print(
            "!! linux.zig applyLinuxGfxEnv does not setenv GDK_BACKEND=x11 !!\n",
            .{},
        );
        return error.GdkX11SetenvMissing;
    }

    // (c) GDK_BACKEND=x11 is set BEFORE gtk_init — GDK reads it once
    // at init and ignores subsequent changes. ApplyLin's setenv calls
    // happen in applyLinuxGfxEnv, which nalar_webview_create calls
    // before gtk_init. Lock in the file-level ordering the same way
    // the earlier WebKit pin tests do.
    const gdk_setenv_site = std.mem.indexOf(u8, linux_src, "\"GDK_BACKEND\"") orelse {
        return error.GdkX11SetenvMissing;
    };
    const gtk_init_site = std.mem.indexOf(u8, linux_src, "gtk_init(null, null);") orelse {
        std.debug.print("!! linux.zig lost its gtk_init call !!\n", .{});
        return error.GtkInitMissing;
    };
    if (gdk_setenv_site > gtk_init_site) {
        std.debug.print(
            "!! GDK_BACKEND=x11 set AFTER gtk_init (offset {d} > {d}) — GDK would ignore it !!\n",
            .{ gdk_setenv_site, gtk_init_site },
        );
        return error.GdkX11AfterGtkInit;
    }

    // (d) User override honored: must consult getenv before setenv.
    // Substring-check is sufficient (the existing `gfx env application
    // respects existing user environment` test already guards the
    // .auto/.compat/.debug paths; .x11 goes through the same helper
    // and reuses the same getenv-then-setenv pattern).
    if (std.mem.indexOf(u8, linux_src, "\"GDK_BACKEND\"").? <
        std.mem.indexOf(u8, linux_src, "getenv(\"GDK_BACKEND\")").?)
    {
        std.debug.print(
            "!! GDK_BACKEND setenv appears before its getenv guard !!\n",
            .{},
        );
        return error.GdkX11NoOverrideCheck;
    }
}
