//! Test root for the PRIBRIK functional suite.
//!
//! Every `*_test.zig` in this package is listed in `suites` below.
//! Zig only compiles `test` blocks the analysis REACHES from the root
//! source file, so a ported suite that is neither imported nor
//! referenced here simply does not run — silently. That is the whole
//! reason this list is explicit rather than globbed: it is the single
//! place where "this suite exists" is asserted, so a forgotten suite
//! fails loudly (empty `suites`) instead of vanishing.
//!
//! The Python suite relied on pytest's directory auto-discovery; Zig
//! has no equivalent, so when you port a file, add it here.

const std = @import("std");

pub const harness = @import("harness.zig");

// ─── Suites ───────────────────────────────────────────────────────────────
// One `const` per ported suite. A bare `@import` expression on its own
// does NOT pull the file's file-scope `test` blocks into the build;
// naming it as a `const` and referencing that const inside a `test`
// block is what makes the file's tests reachable.
const smoke_boot_test = @import("smoke_boot_test.zig");
const auth_test = @import("auth_test.zig");

pub const suites = .{
    smoke_boot_test,
    auth_test,
};

test {
    // Referencing each suite here is what pulls its `test` blocks in.
    inline for (suites) |suite| {
        _ = suite;
    }
    // Plus the harness module's own decls, so a helper added to
    // `harness.zig` is analyzed even before a suite uses it.
    std.testing.refAllDecls(harness);
}
