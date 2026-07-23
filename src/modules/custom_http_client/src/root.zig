//! Public API surface for the custom_http_client module.
//!
//! Consumers import this file as `@import("custom_http_client")` and
//! reach `Client`, `Request`, `Response`, etc. directly.
//!
//! Naming style matches `std.http.Client` and the existing
//! `modules/http/HttpClient.zig` so this module is a drop-in shape.

const client_mod = @import("client.zig");
const request_mod = @import("request.zig");
const response_mod = @import("response.zig");
const options_mod = @import("options.zig");
const methods_mod = @import("methods.zig");

pub const Client = client_mod.Client;
pub const Request = request_mod.Request;
pub const Response = response_mod.Response;
pub const Method = request_mod.Method;
pub const Header = request_mod.Header;
pub const Options = options_mod.Options;
pub const Error = client_mod.Error;

// Convenience verb wrappers (declared in methods.zig).
pub const get = methods_mod.get;
pub const post = methods_mod.post;
pub const put = methods_mod.put;
pub const patch = methods_mod.patch;
pub const delete = methods_mod.delete;

// ----- Tests -----
//
// We keep the test discovery block in `root.zig` (not `test_runner.zig`)
// because the test target's `root_module` is rooted at this file. Zig's
// test walker only descends into modules reachable from the root, so a
// `test_runner.zig` would be invisible.
//
// Mirrors the convention in `src/modules/http/test_runner.zig` but
// colocates the imports with the module's public surface so they
// always get discovered. Each `*_test.zig` file is a named compile unit
// that also compiles in the production `install` build (cheap, ~1ms).

test {
    _ = @import("client_test.zig");
    _ = @import("options_test.zig");
    _ = @import("static_contract_test.zig");
}
