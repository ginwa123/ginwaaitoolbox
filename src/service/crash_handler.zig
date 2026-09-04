// src/service/crash_handler.zig
//
// Crash signal/exception handler — the missing sibling to root.zig's
// `panicHandler`. The panic handler catches Zig-level panics (unreachable,
// index OOB, slice OOB, explicit @panic). This file catches the OS-level
// crash signals that the panic handler cannot reach:
//
//   POSIX:
//     SIGSEGV  — null deref, use-after-free, bad pointer arithmetic
//     SIGBUS   — misaligned access on platforms where it matters
//     SIGABRT  — debug allocator's `Invalid free`, libc abort()
//     SIGILL   — execute of invalid instruction bytes
//     SIGFPE   — divide by zero, integer overflow traps
//
//   Windows:
//     EXCEPTION_ACCESS_VIOLATION     (signal 11 analogue)
//     EXCEPTION_ILLEGAL_INSTRUCTION  (signal 4  analogue)
//     EXCEPTION_INT_DIVIDE_BY_ZERO   (signal 8  analogue)
//     EXCEPTION_STACK_OVERFLOW       (delivered as a UEF)
//     EXCEPTION_BREAKPOINT, etc.
//
// ## What the handler does
//
// 1. Restore the OS default handler for the signal BEFORE attempting any
//    logging. If our own logging code crashes (e.g. fopen fails inside the
//    signal context), the kernel re-delivers the signal to the default
//    handler which terminates the process with a core dump. Without this
//    step, a recursive crash loops forever.
// 2. Capture the fault context: signal number + human-readable signal
//    description + fault address (`si_addr` via SA_SIGINFO) + `si_code`
//    meaning (e.g. SEGV_MAPERR vs SEGV_ACCERR) + fault-address
//    classification (NULL deref vs near-NULL vs wild pointer).
// 3. Capture the current stack trace via
//    `std.debug.captureCurrentStackTrace`, then symbolicate it with
//    `std.debug.writeStackTrace` (function name + file:line via the
//    binary's own debug info). If symbolication fails (stripped binary,
//    missing debug info, OOM in signal context), fall back to raw hex
//    addresses AND always emit the raw addresses alongside the symbolicated
//    frames so post-mortem `addr2line -e <exe> <addr>` still works.
// 4. Format the trace + signal/exception metadata and append it to the
//    panic log file (the same file `panicHandler` writes to — see
//    `root.zig::setPanicLogPath`). Best-effort: any allocation failure
//    or fopen failure is silently swallowed.
// 5. Mirror the same content to stderr so the launching terminal sees
//    it.
// 6. Re-raise the signal (POSIX `std.c.raise`) or return
//    `EXCEPTION_EXECUTE_HANDLER` (Windows) so the OS default action
//    runs: terminate the process. Core dumps (if enabled) still happen.
//
// ## Async-signal-safety caveat
//
// Per POSIX.1, only a small set of libc functions are guaranteed
// async-signal-safe (write, _exit, etc.). `fopen` / `fwrite` / `fclose`
// — and especially `std.debug.writeStackTrace` (which parses the binary's
// own DWARF + may take internal locks on first use) — are NOT in that
// list. We use them anyway — same compromise as
// `root.zig::panicHandler` — because:
//   * Best-effort logging is better than no logging. A crash report with
//     function names + file:line is what turns "0x1f35630" into an
//     actionable bug; raw hex alone (the pre-2026-09-03 behaviour) forced
//     every crash through a manual `addr2line` round-trip.
//   * On glibc / macOS libc, fopen's internal locks are typically
//     uncontended from a single-threaded signal handler context.
//   * If the log attempt crashes, the default-handler restoration in
//     step 1 catches the recursion.
//   * If symbolication fails for any reason, the raw-hex fallback still
//     produces exactly what the old handler produced — never less.
//
// For a production-grade signal-safe log you'd switch to a pre-opened
// fd + `write(2)` + lock-free ring buffer with out-of-band symbolication
// (e.g. a supervisor process running `llvm-symbolizer` on the raw
// addresses). That's a follow-up; this implementation matches the
// existing pattern in panicHandler while maximising debuggability.
//
// ## Setup
//
// Call `installCrashHandlers()` once during startup, AFTER
// `nalarcore.setPanicLogPath()` has been called. The handler reads the
// path via `getCrashLogPath()` — a module-level global set by
// `setCrashLogPath()`. Two globals (the panic handler's and this one)
// avoid a circular `root.zig` ↔ `crash_handler.zig` import.
//
// ## Cross-platform behaviour
//
// Both branches are guarded by `comptime switch (builtin.os.tag)` so
// the unused platform's code is fully eliminated at compile time. The
// test suite's "installCrashHandlers is callable cross-platform"
// contract pins this — taking the function's address forces the
// materialised body on every target.

const std = @import("std");
const builtin = @import("builtin");

// =============================================================================
// Module-level panic log path
// =============================================================================

/// Path to the panic log file. Set by `setCrashLogPath(path)` BEFORE
/// `installCrashHandlers()` is called. Mirrors `root.zig::panic_log_path`
/// but kept separate to avoid a circular import.
var crash_log_path: ?[]const u8 = null;

pub fn setCrashLogPath(path: []const u8) void {
    crash_log_path = path;
}

pub fn getCrashLogPath() ?[]const u8 {
    return crash_log_path;
}

// =============================================================================
// Public entry point
// =============================================================================

/// Install crash signal/exception handlers. Idempotent — calling twice
/// has the same effect as calling once (the second sigaction call
/// overwrites the first handler with the same function pointer).
///
/// On unsupported platforms (anything other than Linux/macOS/Windows)
/// this is a no-op.
pub fn installCrashHandlers() void {
    switch (builtin.os.tag) {
        .linux, .macos => installCrashHandlersPosix(),
        .windows => installCrashHandlersWindows(),
        else => {}, // unsupported — silently no-op
    }
}

// =============================================================================
// Shared helpers (pure, testable outside signal context)
// =============================================================================

/// Human-readable one-liner for each crash signal — the "why did my
/// process die" line. Shown directly under the `=== CRASH ===` header so
/// the most likely cause is visible without decoding anything else.
pub fn signalDescription(sig: std.c.SIG) []const u8 {
    if (sig == std.c.SIG.SEGV) return "invalid memory reference (null deref, use-after-free, bad pointer, stack overflow)";
    // SIGBUS is POSIX-only — std.c.SIG has no BUS member on Windows,
    // so the reference must live behind a comptime gate (untaken
    // branches of `if (comptime ...)` are never analyzed).
    if (comptime builtin.os.tag != .windows) {
        if (sig == std.c.SIG.BUS) return "bus error (misaligned access, truncated mmap'd file, hardware fault)";
    }
    if (sig == std.c.SIG.ABRT) return "abort (explicit abort(), failed assertion, debug-allocator error such as Invalid free)";
    if (sig == std.c.SIG.ILL) return "illegal instruction (corrupt code, bad JIT emit, wrong-arch binary)";
    if (sig == std.c.SIG.FPE) return "arithmetic exception (divide by zero, integer overflow trap)";
    return "unknown crash signal";
}

/// Decode `si_code` (the kernel's sub-reason) for the given signal into a
/// human-readable string. Numeric codes follow the Linux `siginfo_t`
/// convention (SEGV_MAPERR=1, SEGV_ACCERR=2, …); on other platforms the
/// numbers may differ but the text still reads sensibly. Unknown codes
/// fall through to a generic label — the numeric code is always printed
/// alongside so nothing is lost.
pub fn siCodeMeaning(sig: std.c.SIG, code: i32) []const u8 {
    // Non-positive codes are sender identities (SI_USER=0, SI_QUEUE=-1,
    // SI_TIMER=-2, SI_MESGQ=-3, SI_ASYNCIO=-4, SI_SIGIO=-5, SI_TKILL=-6),
    // not hardware sub-reasons — typical when the signal was sent via
    // kill()/raise()/abort() rather than a real CPU fault. Say so
    // explicitly: otherwise "si_code: -6 (unknown SEGV code)" reads like
    // a decoder gap when it's actually "no hardware fault happened".
    if (code <= 0) {
        if (sig == std.c.SIG.ABRT) return "sender code (abort() / raise() — no fault address by design)";
        return "sender code (sent via kill()/raise() — no hardware fault; the address above is the sender, not a fault address)";
    }
    if (sig == std.c.SIG.SEGV) {
        return switch (code) {
            1 => "SEGV_MAPERR (address not mapped to any object)",
            2 => "SEGV_ACCERR (invalid permissions for mapped object)",
            3 => "SEGV_BNDERR (failed address bounds check)",
            4 => "SEGV_PKUERR (protection-key violation)",
            else => "unknown SEGV code",
        };
    }
    // Same POSIX-only gate as signalDescription above.
    if (comptime builtin.os.tag != .windows) {
        if (sig == std.c.SIG.BUS) {
            return switch (code) {
                1 => "BUS_ADRALN (invalid address alignment)",
                2 => "BUS_ADRERR (nonexistent physical address)",
                3 => "BUS_OBJERR (object-specific hardware error)",
                else => "unknown BUS code",
            };
        }
    }
    if (sig == std.c.SIG.ILL) {
        return switch (code) {
            1 => "ILL_ILLOPC (illegal opcode)",
            2 => "ILL_ILLOPN (illegal operand)",
            3 => "ILL_ILLADR (illegal addressing mode)",
            4 => "ILL_ILLTRP (illegal trap)",
            5 => "ILL_PRVOPC (privileged opcode)",
            6 => "ILL_PRVREG (privileged register)",
            7 => "ILL_COPROC (coprocessor error)",
            8 => "ILL_BADSTK (internal stack error)",
            else => "unknown ILL code",
        };
    }
    if (sig == std.c.SIG.FPE) {
        return switch (code) {
            1 => "FPE_INTDIV (integer divide by zero)",
            2 => "FPE_INTOVF (integer overflow)",
            3 => "FPE_FLTDIV (floating-point divide by zero)",
            4 => "FPE_FLTOVF (floating-point overflow)",
            5 => "FPE_FLTUND (floating-point underflow)",
            6 => "FPE_FLTRES (floating-point inexact result)",
            7 => "FPE_FLTINV (invalid floating-point operation)",
            8 => "FPE_FLTSUB (subscript out of range)",
            else => "unknown FPE code",
        };
    }
    // SIGABRT and friends: si_code is typically SI_USER/SI_TKILL (the
    // sender's identity), not a crash sub-reason — just label it.
    return "sender code (not a crash sub-reason)";
}

/// Classify a fault address into the bucket that matters for debugging:
/// NULL, near-NULL (null struct-field access), low (null-derived), or a
/// wild/unmapped pointer. Pure function — unit-testable.
pub fn classifyFaultAddr(addr: usize) []const u8 {
    if (addr == 0) return "NULL dereference";
    if (addr < 0x1000) return "near-NULL (null pointer + small offset — likely a null struct-field access)";
    if (addr < 0x10000) return "low address (likely a null-derived pointer)";
    return "wild/unmapped pointer (use-after-free, buffer overflow, bad cast?)";
}

/// Extract the faulting address from a POSIX `siginfo_t` in a portable
/// way. Linux fills `fields.sigfault.addr`; Darwin/libc exposes a
/// top-level `si_addr`; other libcs vary. Every shape is probed with
/// `@hasField` so a platform without any known shape yields 0 instead of
/// a compile error. Callers should only display the address for signals
/// where the kernel actually fills it (SEGV/BUS/ILL/FPE) — for SIGABRT
/// the union holds sender info and the reinterpreted bytes are
/// meaningless (we still return them; the caller labels the line).
pub fn faultAddrFromSiginfo(info: *const std.posix.siginfo_t) usize {
    const Info = @TypeOf(info.*);
    // Darwin/libc shape: top-level si_addr.
    if (@hasField(Info, "si_addr")) {
        const p = info.si_addr;
        switch (@typeInfo(@TypeOf(p))) {
            .pointer => return @intFromPtr(p),
            .optional => {
                if (p) |nonnull| return @intFromPtr(nonnull);
                return 0;
            },
            .int => return @as(usize, @intCast(p)),
            else => return 0,
        }
    }
    // Linux shape: fields.sigfault.addr (*allowzero anyopaque).
    if (@hasField(Info, "fields")) {
        const Fields = @TypeOf(info.fields);
        if (@hasField(Fields, "sigfault")) {
            const sf = info.fields.sigfault;
            if (@hasField(@TypeOf(sf), "addr")) {
                return @intFromPtr(sf.addr);
            }
        }
        if (@hasField(Fields, "addr")) {
            return @intFromPtr(info.fields.addr);
        }
    }
    return 0;
}

/// Extract `si_code` portably (Linux: `.code`, Darwin/libc: `.si_code`).
pub fn siCodeFromSiginfo(info: *const std.posix.siginfo_t) i32 {
    const Info = @TypeOf(info.*);
    if (@hasField(Info, "code")) return info.code;
    if (@hasField(Info, "si_code")) return info.si_code;
    return 0;
}

/// Symbolicate a captured stack trace into `function (file:line)` form
/// using the binary's own debug info. Returns an owned slice on success.
///
/// On ANY failure (stripped binary, missing DWARF, OOM inside the signal
/// handler, stack tracing disabled) returns `null` — the caller must fall
/// back to raw hex addresses. Never calls `std.debug.print` / locks
/// stderr itself; the output goes into the caller-provided allocator so
/// the caller decides where it lands (log file + stderr mirror).
pub fn symbolicateStack(
    allocator: std.mem.Allocator,
    stack: *const std.debug.StackTrace,
) ?[]const u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    const term: std.Io.Terminal = .{ .writer = &aw.writer, .mode = .no_color };
    std.debug.writeStackTrace(stack, term) catch return null;
    const out = aw.writer.buffered();
    if (out.len == 0) return null;
    // writeStackTrace prints a "Cannot print stack trace: ..." notice
    // instead of frames when debug info is unavailable — treat that as
    // "no symbolication" so the caller prints the fallback line instead
    // of a misleading almost-empty section.
    if (std.mem.indexOf(u8, out, "Cannot print stack trace") != null) return null;
    if (std.mem.indexOf(u8, out, "(empty stack trace)") != null) return null;
    return allocator.dupe(u8, out) catch null;
}

/// Format raw return addresses, one `0x…` per line — the addr2line
/// fallback. Always succeeds on a best-effort basis (empty string on
/// OOM). The caller prints the `addr2line -e <exe>` hint above it.
pub fn formatRawAddrs(
    allocator: std.mem.Allocator,
    addrs: []const usize,
) []const u8 {
    var buf: std.ArrayList(u8) = .empty;
    var line: [32]u8 = undefined;
    for (addrs) |ra| {
        const s = std.fmt.bufPrint(&line, "  0x{x:0>16}\n", .{ra}) catch continue;
        buf.appendSlice(allocator, s) catch break;
    }
    // Ownership transfer: toOwnedSlice shrinks the buffer to the exact
    // length so the caller can free it with a plain allocator.free.
    // Returning buf.items directly would be an "Invalid free" — the
    // ArrayList over-allocates (capacity > len) and free() requires the
    // exact allocation block.
    const owned = buf.toOwnedSlice(allocator) catch {
        buf.deinit(allocator);
        return "";
    };
    return owned;
}

// =============================================================================
// POSIX (Linux + macOS)
// =============================================================================

fn installCrashHandlersPosix() void {
    // The set of crash signals we want to log. Order doesn't matter.
    const signals = [_]std.c.SIG{
        std.c.SIG.SEGV,
        std.c.SIG.BUS,
        std.c.SIG.ABRT,
        std.c.SIG.ILL,
        std.c.SIG.FPE,
    };

    for (signals) |sig| {
        // SA_SIGINFO: deliver siginfo_t + ucontext so the handler can log
        // the fault address and si_code — the two fields that answer "WHY
        // did it crash", not just "WHERE". The handler therefore uses the
        // 3-arg `.sigaction` variant, not the 1-arg `.handler` variant.
        var sa: std.c.Sigaction = .{
            .handler = .{ .sigaction = handleCrashSignalSiginfo },
            .mask = std.mem.zeroes(std.c.sigset_t),
            .flags = std.c.SA.SIGINFO | std.c.SA.RESTART,
        };
        // std.posix.sigaction returns void in Zig 0.16 — do NOT wrap in try.
        // The 2nd arg is `?*const Sigaction`; we have a mutable pointer.
        std.posix.sigaction(sig, &sa, null);
    }
}

/// POSIX crash handler (SA_SIGINFO 3-arg form). Runs in signal context —
/// only async-signal-safe (or best-effort) operations allowed. See file
/// header for caveats.
///
/// Lifetime contract: this function returns normally to the kernel,
/// which then dispatches the re-raised signal via the default handler
/// (SIG_DFL), terminating the process and (if enabled) producing a
/// core dump. We do NOT use `noreturn` + `unreachable` after `raise` —
/// that combination makes Zig's safety machinery treat the unreachable
/// as a panic, which calls `std.c.abort()` → SIGABRT → re-enters this
/// handler for SIGABRT → loop (the secondary crash visible in the
/// original bug report).
///
/// Why a plain return terminates the process:
///   1. The signal that triggered this handler is implicitly blocked
///      in the thread's signal mask for the duration of the handler.
///   2. `raise(sig)` is therefore synchronous-but-queued: it returns
///      0 after queuing the signal, because delivering it inline would
///      recurse into the same handler context.
///   3. When this function returns, the kernel's sigreturn restores
///      the original signal mask (unblocking the signal), checks the
///      pending mask, sees the queued signal, and dispatches it via
///      SIG_DFL (terminate + core dump) — which we installed in STEP 1.
///
/// If `raise` itself fails (returns non-zero), we call `_Exit` directly
/// to ensure the process still terminates (without a core dump, but at
/// least without spinning forever).
fn handleCrashSignalSiginfo(
    sig: std.c.SIG,
    info: *const std.posix.siginfo_t,
    ucontext: ?*anyopaque,
) callconv(.c) void {
    _ = ucontext;
    // STEP 1 — restore the OS default handler BEFORE logging. If our
    // logger crashes inside this handler, the kernel re-delivers the
    // signal to the default action (terminate + core dump) instead of
    // re-entering us. Critical: do this BEFORE any allocation / I/O.
    var sa: std.c.Sigaction = .{
        .handler = .{ .handler = std.c.SIG.DFL },
        .mask = std.mem.zeroes(std.c.sigset_t),
        .flags = 0,
    };
    std.posix.sigaction(sig, &sa, null);

    // STEP 2 — build the report. Uses page_allocator (best-effort — OOM
    // is silently dropped, each section degrades independently).
    const alloc = std.heap.page_allocator;
    const signal_name = @tagName(sig);
    const desc = signalDescription(sig);
    const si_code = siCodeFromSiginfo(info);
    const si_meaning = siCodeMeaning(sig, si_code);
    const has_fault_addr = sig == std.c.SIG.SEGV or sig == std.c.SIG.BUS or
        sig == std.c.SIG.ILL or sig == std.c.SIG.FPE;
    const fault_addr = if (has_fault_addr) faultAddrFromSiginfo(info) else 0;

    const header = std.fmt.allocPrint(alloc,
        \\=== CRASH: received signal {s} (signal number {d}) ===
        \\Why: {s}
        \\
    , .{ signal_name, @intFromEnum(sig), desc }) catch "=== CRASH: received signal (name unavailable) ===\n";
    defer alloc.free(header);

    // Fault line: address + classification + si_code meaning. For SIGABRT
    // there is no fault address — say so explicitly instead of printing a
    // meaningless reinterpreted-union value.
    const fault_line = if (has_fault_addr)
        std.fmt.allocPrint(alloc,
            "Fault address: 0x{x} ({s})\nsi_code: {d} ({s})\nBuild: {s}, {s}-{s}\n",
            .{ fault_addr, classifyFaultAddr(fault_addr), si_code, si_meaning, @tagName(builtin.mode), @tagName(builtin.cpu.arch), @tagName(builtin.os.tag) },
        ) catch ""
    else
        std.fmt.allocPrint(alloc,
            "Fault address: n/a (abort-style signal carries sender info, not a fault address)\nsi_code: {d} ({s})\nBuild: {s}, {s}-{s}\n",
            .{ si_code, si_meaning, @tagName(builtin.mode), @tagName(builtin.cpu.arch), @tagName(builtin.os.tag) },
        ) catch "";
    defer if (fault_line.len > 0) alloc.free(fault_line);

    var addr_buf: [64]usize = undefined;
    const stack = std.debug.captureCurrentStackTrace(.{}, &addr_buf);

    // Symbolicated frames (best-effort — null when debug info is missing).
    const sym = symbolicateStack(alloc, &stack);
    defer if (sym) |s| alloc.free(s);

    const sym_section = if (sym) |s|
        std.fmt.allocPrint(alloc,
            "Symbolicated stack trace ({d} frames — function + file:line):\n{s}",
            .{ stack.return_addresses.len, s },
        ) catch ""
    else
        std.fmt.allocPrint(alloc,
            "Symbolicated stack trace: UNAVAILABLE (stripped binary or no debug info — see raw addresses below)\n",
            .{},
        ) catch "";
    defer if (sym_section.len > 0) alloc.free(sym_section);

    // Raw addresses are ALWAYS emitted — they are the addr2line fallback
    // when symbolication fails, and a cross-check when it succeeds.
    const raw = formatRawAddrs(alloc, stack.return_addresses);
    defer alloc.free(raw);
    const raw_section = std.fmt.allocPrint(alloc,
        \\Raw addresses ({d} frames — post-mortem: addr2line -e <exe> <addr>):
        \\{s}
    , .{ stack.return_addresses.len, raw }) catch "";
    defer if (raw_section.len > 0) alloc.free(raw_section);

    const footer = "\n=============\n";

    // STEP 3 — append to the panic log file (best-effort). If we
    // can't open the file we still try stderr, then re-raise.
    if (crash_log_path) |path| {
        // std.c.fopen requires a NUL-terminated string ([*:0]const u8),
        // but our path is just []const u8. Copy into a stack buffer
        // and append a NUL — no heap allocation in signal context.
        var path_z: [std.Io.Dir.max_path_bytes + 1]u8 = undefined;
        if (path.len < path_z.len) {
            @memcpy(path_z[0..path.len], path);
            path_z[path.len] = 0;
            // @ptrCast from *fixed-u8 to [*:0]const u8 — safe because we
            // just wrote the NUL sentinel at path_z[path.len].
            const path_z_ptr: [*:0]const u8 = @ptrCast(&path_z);
            if (std.c.fopen(path_z_ptr, "a")) |file| {
                defer _ = std.c.fclose(file);
                _ = std.c.fwrite(header.ptr, 1, header.len, file);
                _ = std.c.fwrite(fault_line.ptr, 1, fault_line.len, file);
                _ = std.c.fwrite(sym_section.ptr, 1, sym_section.len, file);
                _ = std.c.fwrite(raw_section.ptr, 1, raw_section.len, file);
                _ = std.c.fwrite(footer.ptr, 1, footer.len, file);
            }
        }
    }

    // STEP 4 — mirror to stderr for terminal visibility.
    std.debug.print("{s}{s}{s}{s}{s}", .{ header, fault_line, sym_section, raw_section, footer });

    // STEP 5 — re-raise so the OS default action runs (terminate +
    // core dump). std.c.raise returns c_int (0 on success, -1 on
    // failure). The signal is queued (the triggering signal is
    // implicitly blocked in the thread's mask while the handler runs),
    // not delivered inline — see the function doc above for why
    // returning from this handler is what terminates the process.
    _ = std.c.raise(sig);
    // Either the signal is queued and will be delivered via SIG_DFL on
    // handler return (the normal path — produces a core dump), or
    // raise() itself failed; in that case fall through to _Exit which
    // is async-signal-safe and ensures we still terminate.
    std.c._Exit(128 + @as(c_int, @intCast(@intFromEnum(sig))));
}

// =============================================================================
// Windows
// =============================================================================

/// Bind the Win32 SetUnhandledExceptionFilter API. The filter callback
/// receives a pointer to `EXCEPTION_POINTERS` (exception record +
/// context) for the crash.
const win32_apis = if (builtin.os.tag == .windows) struct {
    /// EXCEPTION_EXECUTE_HANDLER is the value the UEF returns to tell
    /// the kernel "I've handled it; unwind and terminate". NOT exposed
    /// by `std.os.windows` in Zig 0.16 — declared here per WinNT.h.
    pub const EXCEPTION_EXECUTE_HANDLER: c_long = 1;

    /// Function pointer type for SetUnhandledExceptionFilter's callback.
    /// Returns LONG (c_long); WINAPI = __stdcall on x86 = callconv(.winapi)
    /// in Zig 0.16.
    pub const UnhandledExceptionFilterFn = *const fn (
        exception_info: *std.os.windows.EXCEPTION_POINTERS,
    ) callconv(.winapi) c_long;

    extern "kernel32" fn SetUnhandledExceptionFilter(
        filter: ?UnhandledExceptionFilterFn,
    ) callconv(.winapi) ?UnhandledExceptionFilterFn;
} else struct {};

fn installCrashHandlersWindows() void {
    _ = win32_apis.SetUnhandledExceptionFilter(handleWindowsException);
}

/// Human-readable one-liner for a Win32 exception code.
pub fn windowsExceptionDescription(code: u32) []const u8 {
    return switch (code) {
        0xC0000005 => "EXCEPTION_ACCESS_VIOLATION (invalid memory reference — SIGSEGV equivalent)",
        0xC000001D => "EXCEPTION_ILLEGAL_INSTRUCTION (SIGILL equivalent)",
        0xC0000094 => "EXCEPTION_INT_DIVIDE_BY_ZERO (SIGFPE equivalent)",
        0xC00000FD => "EXCEPTION_STACK_OVERFLOW (exhausted stack — check for unbounded recursion)",
        0xC0000409 => "EXCEPTION_STACK_BUFFER_OVERRUN / FAIL_FAST (buffer overrun or /GS cookie check)",
        0xC0000374 => "EXCEPTION_HEAP_CORRUPTION (heap metadata damaged — use-after-free / overflow)",
        0x80000003 => "EXCEPTION_BREAKPOINT (debug breakpoint hit outside a debugger)",
        0xC000008C => "EXCEPTION_ARRAY_BOUNDS_EXCEEDED (out-of-bounds access trap)",
        0xC0000090 => "EXCEPTION_FLT_INVALID_OPERATION (invalid floating-point operation)",
        0xC0000091 => "EXCEPTION_FLT_OVERFLOW (floating-point overflow)",
        0xC0000093 => "EXCEPTION_FLT_UNDERFLOW (floating-point underflow)",
        0xC0000092 => "EXCEPTION_FLT_DIVIDE_BY_ZERO (floating-point divide by zero)",
        0xC0000096 => "EXCEPTION_INT_OVERFLOW (integer overflow trap)",
        else => "unknown Windows exception",
    };
}

/// Windows unhandled exception filter. Runs in exception-dispatch
/// context — equivalent to a signal handler for crash purposes.
///
/// Returns `EXCEPTION_EXECUTE_HANDLER` (1) so the kernel unwinds
/// handlers and terminates the process. We can't "re-raise" on Windows
/// (the UEF is the last filter in the chain) — returning 0
/// (EXCEPTION_CONTINUE_SEARCH) would hand control to WER / the
/// debugger, which is rarely what the user wants from a server.
fn handleWindowsException(exception_info: *std.os.windows.EXCEPTION_POINTERS) callconv(.winapi) c_long {
    const alloc = std.heap.page_allocator;
    const rec = exception_info.ExceptionRecord;
    const code: u32 = @bitCast(rec.ExceptionCode);
    const addr = @intFromPtr(rec.ExceptionAddress);

    const header = std.fmt.allocPrint(alloc,
        \\=== CRASH: Windows exception 0x{x:0>8} at address 0x{x} ===
        \\Why: {s}
        \\Build: {s}, {s}-{s}
        \\
    , .{ code, addr, windowsExceptionDescription(code), @tagName(builtin.mode), @tagName(builtin.cpu.arch), @tagName(builtin.os.tag) }) catch "=== CRASH: Windows exception (details unavailable) ===\n";
    defer alloc.free(header);

    // For ACCESS_VIOLATION the record carries 2 info words:
    //   [0] = 0 read / 1 write / 8 DEP violation, [1] = fault address.
    var access_line: []const u8 = "";
    if (code == 0xC0000005 and rec.NumberParameters >= 2) {
        const rw = rec.ExceptionInformation[0];
        const fault: usize = @intCast(rec.ExceptionInformation[1]);
        const rw_txt: []const u8 = switch (rw) {
            0 => "read",
            1 => "write",
            8 => "DEP/execute (data-execution-prevention)",
            else => "unknown access kind",
        };
        access_line = std.fmt.allocPrint(alloc,
            "Access: {s} at fault address 0x{x} ({s})\n",
            .{ rw_txt, fault, classifyFaultAddr(fault) },
        ) catch "";
    }
    defer if (access_line.len > 0) alloc.free(access_line);

    var addr_buf: [64]usize = undefined;
    const stack = std.debug.captureCurrentStackTrace(.{}, &addr_buf);

    const sym = symbolicateStack(alloc, &stack);
    defer if (sym) |s| alloc.free(s);

    const sym_section = if (sym) |s|
        std.fmt.allocPrint(alloc,
            "Symbolicated stack trace ({d} frames — function + file:line):\n{s}",
            .{ stack.return_addresses.len, s },
        ) catch ""
    else
        std.fmt.allocPrint(alloc,
            "Symbolicated stack trace: UNAVAILABLE (stripped binary or no debug info — see raw addresses below)\n",
            .{},
        ) catch "";
    defer if (sym_section.len > 0) alloc.free(sym_section);

    const raw = formatRawAddrs(alloc, stack.return_addresses);
    defer alloc.free(raw);
    const raw_section = std.fmt.allocPrint(alloc,
        \\Raw addresses ({d} frames):
        \\{s}
    , .{ stack.return_addresses.len, raw }) catch "";
    defer if (raw_section.len > 0) alloc.free(raw_section);

    const footer = "\n=============\n";

    if (crash_log_path) |path| {
        var path_z: [std.Io.Dir.max_path_bytes + 1]u8 = undefined;
        if (path.len < path_z.len) {
            @memcpy(path_z[0..path.len], path);
            path_z[path.len] = 0;
            const path_z_ptr: [*:0]const u8 = @ptrCast(&path_z);
            if (std.c.fopen(path_z_ptr, "a")) |file| {
                defer _ = std.c.fclose(file);
                _ = std.c.fwrite(header.ptr, 1, header.len, file);
                _ = std.c.fwrite(access_line.ptr, 1, access_line.len, file);
                _ = std.c.fwrite(sym_section.ptr, 1, sym_section.len, file);
                _ = std.c.fwrite(raw_section.ptr, 1, raw_section.len, file);
                _ = std.c.fwrite(footer.ptr, 1, footer.len, file);
            }
        }
    }

    std.debug.print("{s}{s}{s}{s}{s}", .{ header, access_line, sym_section, raw_section, footer });

    return win32_apis.EXCEPTION_EXECUTE_HANDLER;
}
