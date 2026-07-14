# Zig — Function Parameters Cannot Have Default Values

Unlike Rust, Swift, C++, and many other modern languages, Zig does NOT support
default values for function parameters. A function declaration like:

```zig
pub fn buildMessages(
    allocator: std.mem.Allocator,
    ...
    inherited_context_mode: []const u8 = "",  // ❌ compile error
) ![]agent.AgentMessage {
```

fails to compile with `error: expected ',' after parameter` pointing at the
`=`. The Zig language spec has no syntax for default parameter values.

## Workarounds

1. **Make all callers pass the value explicitly.** The standard idiom in
   nalar — every internal call site is updated, no extra logic needed.
   Works for small numbers of call sites.

2. **Split into a public function (with the param) + a wrapper (without).**
   The wrapper has a default-friendly signature that calls the public
   function with the default value baked in:

   ```zig
   pub fn buildMessages(
       ...,
       inherited_context_mode: []const u8,
   ) ![]agent.AgentMessage { ... }

   pub fn buildMessagesDefault(
       ...,
   ) ![]agent.AgentMessage {
       return buildMessages(..., "");
   }
   ```

3. **Use sentinel values + check inside the function body.** Less idiomatic;
   pollutes the parameter's value space with a magic constant.

## Symptom

`error: expected ',' after parameter` at the `=` sign of a function
parameter. The error message is misleading — it suggests a syntax issue
with the comma before, when actually the whole "= value" is rejected.

## How to verify

If you see "expected ',' after parameter" in a function declaration and
you have `param: T = value` syntax, switch to one of the workarounds
above. There's no fix for the language; it's by design.
