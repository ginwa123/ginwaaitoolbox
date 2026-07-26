// src/service/mod.zig
//
// Re-exports every module in the `nalar service {start,stop,status,restart}`
// lifecycle + crash reporting cluster.
//
// ## Why a single mod.zig
//
// All five modules exist for one purpose: make `nalar` runnable as a
// cross-platform background service. `daemon.zig` and `signal_handlers.zig`
// are the POSIX+Windows plumbing; `state_file.zig` is the on-disk
// coordination channel between `service start` and `service stop`;
// `main_service.zig` wires them into the CLI verbs; `crash_handler.zig`
// catches SIGSEGV/SIGBUS/SIGABRT/SIGILL/SIGFPE (POSIX) and
// EXCEPTION_* (Windows) so a crashing daemon leaves a forensic log.
//
// Callers usually reach these through `nalarcore.service.<module>`:
//   nalarcore.service.daemon.daemonize()
//   nalarcore.service.signal_handlers.installSigtermHandler(cb)
//   nalarcore.service.state_file.writeStateFile(...)
//   nalarcore.service.main_service.serviceStart(...)
//   nalarcore.service.crash_handler.installCrashHandlers()
//
// For backward compatibility, `src/root.zig` also re-exports each of
// these at the top level (`nalarcore.state_file`, etc.). New code should
// prefer the `service.*` namespace.

pub const daemon = @import("daemon.zig");
pub const signal_handlers = @import("signal_handlers.zig");
pub const state_file = @import("state_file.zig");
pub const main_service = @import("main_service.zig");
pub const crash_handler = @import("crash_handler.zig");