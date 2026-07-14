# Zig 0.16 — `extern "c"` Functions Accept `?*T` Return Types

`extern "c"` function declarations in Zig 0.16 support a **nullable C pointer**
return type written as `?*T`. The wrapper code uses the standard `orelse`
unwrapping idiom, which Zig compiles to a NULL check at the call site.

## The pattern

```zig
const Webview = opaque{};

extern "c" fn nalar_webview_create(
    cfg: *const Config,
    url: [*:0]const u8,
) ?*Webview;

extern "c" fn nalar_webview_run(wv: *Webview) void;
extern "c" fn nalar_webview_destroy(wv: *Webview) void;

// Call site — `orelse` propagates null as an error
const wv = nalar_webview_create(&cfg, url_z) orelse return error.CreateFailed;
defer nalar_webview_destroy(wv);
nalar_webview_run(wv);
```

## `extern "c"` struct field type rules

- `[*:0]const u8` for `const char*` (null-terminated, no length)
- `[*]const u8` for `const char*` carrying bytes that may contain NULs
  (length carried separately as `usize`)
- `c_int` for C `int` fields (NOT bare `i32` — they usually match on Linux
  but the convention is `c_int` for portability)
- `usize` for `size_t`
- `bool` works directly (Zig marshals to C `bool`)
- `?[*:0]const u8` for `const char*` parameters that are nullable

## `extern "c"` functions default to module-private

Unlike regular Zig functions, `extern "c"` declarations at the top of a
`.zig` file are **not implicitly `pub`**. They are accessible from inside
the same file (and from the same `extern "c"` block scope) but NOT from
other files that `@import` the file. This is the OPPOSITE of the
"root file symbols are public" rule for normal files.

To use an `extern "c"` symbol from outside its declaring file, prefix it
with `pub`:

```zig
pub extern "c" fn nalar_webview_create(...) ?*Webview;
```

For the nalar-desktop webview wrapper, the 3 `extern "c"` symbols are
intentionally NOT `pub` because the public Zig API is `webview.run()`,
which is the only thing `main.zig` calls. The extern "c" functions are
implementation details of `webview.run()`.

## Linker doesn't see unused function pointers

When verifying "the extern 'c' symbols are undefined at link time", using
`_ = webview.run;` (taking the function's address) does NOT force the
linker to resolve the symbols — Zig 0.16's compiler can inline away the
unused reference. Use an actual CALL (`try webview.run(allocator, .{}, url)`)
to force the link step to try to resolve the symbols.

Symptom: `_ = webview.run;` compiles and links cleanly even when the
extern "c" symbols are undefined. `_ = webview.run;` is a no-op for the
linker.

## When this bites

- Any code that wraps a C library in Zig with `extern "c"` declarations
- Verifying that the C ABI skeleton produces the expected link errors
  when the C implementation is not yet provided (Chunks 5-7 of
  nalar-desktop)
- Porting C interop code from older Zig to 0.16 — `?*T` in `extern "c"`
  has always worked but the "private by default" rule may surprise
  people coming from Rust `extern "C"` blocks
