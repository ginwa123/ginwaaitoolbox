// src/apps/desktop_app/platform/webview_linux.c
//
// C source file that pulls in the GTK / WebKitGTK / libsoup headers
// so the system C compiler (cc) validates them at build time. This
// file is added to desktop_exe via build.zig's `addCSourceFile`.
//
// Why this exists
// ----------------
// Zig's `@cImport` parser (a libclang-based tool) mis-tokenizes the
// C99 `_Pragma` operator when it appears inside a macro body. GLib
// uses `_Pragma` inside `G_GNUC_BEGIN_IGNORE_DEPRECATIONS` and friends,
// which in turn are expanded by `G_DECLARE_FINAL_TYPE` for nearly every
// GObject type in glib / gtk / libsoup / webkit. @cImport chokes with
// ~7,000 cascading "unknown type name 'diagnostic'" errors.
//
// We work around this by skipping @cImport entirely. The .c file
// (this file) is compiled with cc, which handles `_Pragma` correctly
// and has no trouble with any of the GLib / GTK / WebKitGTK headers.
// The corresponding Zig implementation in linux.zig declares each
// GTK / WebKit symbol it uses as an `extern "c"` declaration — the
// linker resolves the symbols against the linked system libraries
// (libgtk-3, libwebkit2gtk-4.1, libsoup-3.0, libglib-2.0).
//
// This file deliberately does NOT define any of the `nalar_webview_*`
// ABI functions — those are implemented in linux.zig (the Zig side
// has clearer control flow for asset lookup, signal wiring, and the
// GBytes stream ownership dance). The .c file is just a header
// "compile test" that runs through cc: if the GTK/WebKit headers
// change in a way that breaks the C compilation, the build fails
// here, which is the right place to catch that regression.
//
// Header subset
// -------------
// We include only the GTK + WebKitGTK headers needed by the Zig
// extern declarations in linux.zig. Pulling in the full GTK 3
// umbrella header (gtk/gtk.h) would also work, but the unused
// declarations would slow the build for no benefit.

#include <gtk/gtk.h>
#include <webkit2/webkit2.h>
