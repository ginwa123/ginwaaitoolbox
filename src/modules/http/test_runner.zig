test {
    // Inline `HttpClient.zig` tests were removed due to API changes in
    // Zig 0.16 (see the prior `// Tests removed...` comment below). The
    // static-contract regression checks for the FD-leak fix live in
    // `http_client_fd_leak_test.zig` — they grep the source for the
    // required `defer { ... close(self.io) ... }` blocks so future
    // refactors can't accidentally remove them.
    _ = @import("http_client_fd_leak_test.zig");
}