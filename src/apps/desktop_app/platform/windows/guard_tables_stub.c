// src/apps/desktop_app/platform/windows/guard_tables_stub.c
//
// Provides the 5 CFG/XFG guard symbols that NOTHING in the link
// otherwise defines — see the `guard_support.obj` saga in build.zig
// (MSVC's defining member also defines the `__guard_*_icall_fptr`
// tables that collide with mingw's, so it stays pruned out of the
// staged msvcrt.lib and these 5 are left undefined):
//
//   - `__guard_dispatch_icall_dummy` — no-op fallback dispatch
//     referenced by mingw's `mingw_cfguard_support.obj`. Mirrors
//     Microsoft's own dummy (a bare `ret`).
//   - `__guard_xfg_{check,dispatch,table_dispatch}_icall_fptr` and
//     `__castguard_check_failure_os_handled_fptr` — loader-consumed
//     DATA pointers referenced by MSVC's `loadcfg.obj`
//     (`_load_config_used`). NULL = "feature not configured", which
//     is exactly right: this binary doesn't opt into XFG/CastGuard,
//     so the loader must see absent tables, not garbage.
//
// Compiled with the normal Zig CC path (plain C, no includes) and
// linked as an object — deterministic, no archive ordering games.
// x64 has no leading-underscore decoration, so these names match the
// references exactly.

void *__guard_xfg_check_icall_fptr = 0;
void *__guard_xfg_dispatch_icall_fptr = 0;
void *__guard_xfg_table_dispatch_icall_fptr = 0;
void *__castguard_check_failure_os_handled_fptr = 0;

void __guard_dispatch_icall_dummy(void) {}
