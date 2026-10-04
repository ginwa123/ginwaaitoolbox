---
name: openssl-c-bindings-from-zig016
description: "How to call OpenSSL (libssl/libcrypto) from Zig 0.16 in this repo without @cImport — the hand-declared extern recipe, the macro-vs-symbol traps that bite at link time, and how to verify every hardcoded constant against /usr/include/openssl before trusting it."
---
---
name: openssl-c-bindings-from-zig016
description: How to call OpenSSL (libssl/libcrypto) from Zig 0.16 in this repo without @cImport — the hand-declared extern recipe, the macro-vs-symbol traps that bite at link time, and how to verify every hardcoded constant against /usr/include/openssl before trusting it.
tags: [zig, openssl, ffi, environment, pattern]
---

## When to Use

Adding or extending native TLS/crypto in this repo (the h2-over-TLS listener,
cert generation, any future client-side TLS). Trigger phrases: "OpenSSL",
"libssl", "ALPN", "X509", "self-signed certificate", "call a C library from Zig".

## Context

* Zig 0.16 + OpenSSL 3.6.4 on this box. Headers `/usr/include/openssl/*.h`,
  shared libs `/usr/lib/libssl.so.3` + `/usr/lib/libcrypto.so.3`
  (`/usr/lib/libssl.so` → `.so.3` symlinks exist, so `-lssl -lcrypto` resolves).
* No build.zig change is needed to verify: `zig test -lc -lssl -lcrypto <file>`
  is enough (the human wires the real build).
* House style is **no `@cImport`** — declare exactly the symbols you call, by
  hand, as `extern fn`, with `opaque {}` types for the OpenSSL structs and a
  doc comment citing the header. A ~30-line extern block is self-reviewable; a
  generated 9000-line X509 binding is not.
* Zig 0.16's own `std.crypto.tls` is **client-only** with **no ALPN** (zero
  `alpn` hits under `/usr/lib/zig/std`), which is usually *why* you are here.

## Procedure

1. **Grep the header for the real prototype** (never type it from memory — the
   const-ness and the parameter order are load-bearing):
   `search(pattern="X509_add_ext\(|PEM_write_bio_PrivateKey|SSL_CTX_set_alpn_select_cb", path="/usr/include/openssl")`
   Read a few lines of context; multi-line prototypes hide trailing params.
2. **Check whether the symbol exists at all.** Many "functions" are macros:
   * `SSL_CTX_set_min_proto_version(ctx, v)` → `SSL_CTX_ctrl(ctx, 123, v, NULL)`
   * `BIO_get_mem_data(b, pp)` → `BIO_ctrl(b, 3, 0, (char **)(pp))`
   * `X509_get_notBefore` → `X509_getm_notBefore` (a *real* symbol, non-const)
   Using a macro name as an `extern fn` compiles and then fails at link time
   with an undefined symbol. Declare the underlying function and call it with
   the macro's own constant.
3. **Copy numeric constants out of the headers, with the header as the source
   of truth.** Put the derivation in the comment. Known-good for 3.6.4:
   * `SSL_OP_BIT(n) = (uint64_t)1 << n` → NO_COMPRESSION `1<<17`,
     CIPHER_SERVER_PREFERENCE `1<<22` (via SSL_OP_SERVER_PREFERENCE),
     NO_RENEGOTIATION `1<<30`.
   * `SSL_TLSEXT_ERR_OK = 0`, `ALERT_WARNING = 1`, `ALERT_FATAL = 2`,
     `NOACK = 3` — these live in **tls1.h**, not ssl.h.
   * `SSL_ERROR_SSL = 1`, `WANT_READ = 2`, `WANT_WRITE = 3`, `SYSCALL = 5`,
     `ZERO_RETURN = 6`.
   * `X509_FILETYPE_PEM = 1`, `MBSTRING_UTF8 = 0x1000`, `BIO_CTRL_INFO = 3`,
     `SSL_CTRL_SET_MIN_PROTO_VERSION = 123`, `TLS1_2_VERSION = 0x0303`,
     `GEN_DNS = 2`, `GEN_IPADD = 7`.
   Prefer a **runtime name lookup** over a magic NID where one exists:
   `OBJ_txt2nid("subjectAltName")` beats hardcoding `NID_subject_alt_name()`.
4. **Variadic entry points** (e.g. the 3.x one-shot keygen) are declared as:
   ```zig
   extern fn EVP_PKEY_Q_keygen(libctx: ?*anyopaque, propq: ?[*:0]const u8, key_type: [*:0]const u8, ...) ?*EVP_PKEY;
   // EVP_PKEY_Q_keygen(null, null, "EC", "P-256")   <- curve name is a vararg
   ```
5. **C string arguments**: OpenSSL takes `[*:0]const u8`. Convert a slice with
   `alloc.dupeZ(u8, path)` into a temp owned by the call — never assume the
   caller's slice is NUL-terminated.
6. **Callback ABIs** (ALPN select callback):
   ```zig
   extern fn SSL_CTX_set_alpn_select_cb(ctx: *SSL_CTX,
       cb: *const fn (?*SSL, *[*]const u8, *u8, [*]const u8, c_uint, ?*anyopaque) callconv(.c) c_int,
       arg: ?*anyopaque) void;
   ```
   `*[*]const u8` is `const unsigned char **`; pass `@ptrCast(self)` for `arg`
   and `@ptrCast(@alignCast(arg))` to recover it. Return the selected protocol
   by pointing `out` **into `in`** (OpenSSL keeps the ClientHello for the
   handshake) — no allocation, no static buffer to race.
7. **Error strings**: there is no static-string API. Format on demand:
   ```zig
   const code = ERR_get_error();          // 0 == queue empty (pops one entry)
   ERR_error_string_n(code, &buf, buf.len); // NUL-terminates; memset first
   ```
   Keep the buffer in your context object so `lastError() []const u8` can return
   a slice with no allocation.
8. **Acceptance-test the output with both sides.** For certificates: parse the
   bytes with `std.crypto.Certificate.parse` (proves real DER) **and** load them
   with `SSL_CTX_use_certificate_chain_file` + `SSL_CTX_use_PrivateKey_file` +
   `SSL_CTX_check_private_key` (proves the pair the handshake will actually use).

## Pitfalls

* **Macro masquerading as function** → "undefined symbol: SSL_CTX_set_min_proto_version".
  See step 2.
* **`X509_get0_notBefore` returns `const ASN1_TIME *`** while `X509_gmtime_adj`
  wants non-const. Use `X509_getm_notBefore`/`X509_getm_notAfter` (non-const,
  real symbols) instead of casting away const.
* **`SSL_set_fd` and fds**: OpenSSL wraps the fd in a `BIO_NOCLOSE` BIO — it
  never closes it, so the caller must close the fd on every path, including
  after a failed handshake.
* **SIGPIPE**: OpenSSL writes with plain `write(2)` (no `MSG_NOSIGNAL`), so a
  peer that vanished can raise SIGPIPE and kill the process. A server embedding
  this must ignore SIGPIPE process-wide or set `SO_NOSIGPIPE`. Document it at
  the call site; you cannot suppress it from inside `SSL_write`.
* **`BIO_get_mem_data` returns a pointer into the BIO's own buffer** — copy the
  bytes out before `BIO_free`.
* **`SSL_CTX_set_alpn_protos` returns 0 on success** (opposite of most of the
  library's "1 == ok" predicates).
* **`X509_add_ext` deep-copies**, so the temporary `X509_EXTENSION` must be
  freed by you (`X509_EXTENSION_free`).
* **`--test-no-exec -target x86_64-windows-gnu`** will fail at *link* ("undefined
  symbol: X509_new") on this Linux box. That is expected and still proves the
  Zig code compiled — see the `zig-cross-platform-verification` skill and report
  it as link-only, not as "builds on Windows".

## Verification

* `zig test -lc -lssl -lcrypto <file>` green on Linux.
* Cross-target compile check per the `zig-cross-platform-verification` skill:
  only `undefined symbol` / library-lookup diagnostics, zero source-line `error:`.
* The generated material is accepted by a *second* reader (std's parser for DER,
  OpenSSL's loader for PEM pairs) — not just by the code that wrote it.

