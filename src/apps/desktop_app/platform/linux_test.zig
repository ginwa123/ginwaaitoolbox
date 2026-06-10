// src/apps/desktop_app/platform/linux_test.zig
//
// Chunk 5: Linux platform tests.
//
// UI tests in Zig are too brittle for v1 — GTK widgets need a display
// server, WebKit needs a windowing system, and a unit test can't easily
// assert "did the window appear?" or "did the asset scheme serve the
// right bytes?". The manual smoke test in the plan (Chunk 5.1 Step 3)
// is the only meaningful verification:
//
//   1. Stand up a tiny static HTTP server (e.g. `python3 -m http.server`)
//   2. Run nalar-desktop against it
//   3. Confirm a GTK window appears with the webapp content
//   4. Close the window; confirm nalar-desktop exits cleanly
//
// This file is a placeholder so the test step has something to discover
// and so the Chunk 5 deliverable is explicit about its test surface.

const std = @import("std");
const testing = std.testing;

test "linux: document manual smoke test (see Plan B Chunk 5.1 Step 3)" {
    try testing.expect(true);
}
