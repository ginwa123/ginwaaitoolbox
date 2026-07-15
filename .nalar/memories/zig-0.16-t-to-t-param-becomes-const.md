# Zig 0.16 — Function parameter with matching return type is implicitly const

In Zig 0.16, when a function's parameter type exactly matches its return type
(e.g. `fn(messages: std.ArrayList(T)) !std.ArrayList(T)`), the parameter is
**implicitly treated as `const` inside the function body**. This is a
behavior of the Zig 0.16 compiler that bit the nalar `compactMessageInMemoryNew`
refactor — `messages.deinit(allocator)` (where `deinit` takes `*Self`, not
`*const Self`) failed with:

```
src/.../workflow.zig:1024:13: error: expected type '*T', found '*const T'
    messages.deinit(allocator);
    ~~~~~~~~^~~~~~~
src/.../workflow.zig:1024:13: note: T = array_list.Aligned(modules.agent.Agent.AgentMessage,null)
src/.../workflow.zig:1024:13: note: cast discards const qualifier
```

## Symptom

A method call on a parameter that takes `*Self` (mutable) fails with
`expected type '*T', found '*const T'` — the compiler has silently
const-qualified the parameter. This breaks calls like:
- `param.deinit(allocator)` (ArrayList's `deinit(self: *Self, ...)`)
- `param.append(allocator, x)` (some `append` overloads)
- Any method that takes `*Self` rather than `*const Self`

## Why

In Zig 0.16, the type system treats a function whose parameter and return
type are the same `T` (e.g. `T → T` or `T → !T`) as moving the parameter
into the return value. To enforce "moved" semantics, the parameter is
implicitly const inside the function body. This is intentional and
invisible to the developer — there is no `const` keyword on the
parameter declaration.

## The fix — introduce a mutable local copy

```zig
pub fn compactMessageInMemoryNew(
    allocator: std.mem.Allocator,
    messages: std.ArrayList(T),     // implicitly const inside this fn
    ...
) !std.ArrayList(T) {
    // Copy to a fresh mutable local — local variables don't have the
    // T → T const constraint.
    var messages_owned = messages;

    // Now method calls that need `*Self` work:
    for (messages_owned.items) |*msg| { ... }
    messages_owned.deinit(allocator);

    return new_messages;
}
```

The `var messages_owned = messages;` line:
- Creates a fresh `std.ArrayList(T)` on the stack
- Copies the (ptr, len, cap) fields from the parameter
- The local is mutable, so `&messages_owned` is `*T` (not `*const T`)
- The original `messages` parameter is left untouched (we read `items` from it for the early-return case)

## What does NOT work as alternatives

- `(&messages).deinit(allocator)` — fails with the same error; `&messages`
  is `*const T` because `messages` itself is const.
- `messages.deinit(allocator)` — fails with the same error.
- `const messages: ... = messages;` — does not help; re-binding to a new
  variable doesn't change the const-ness of the source.
- Renaming the parameter — does not help; the constraint is structural.

## Why this is invisible to `zig build test` but breaks `zig build install`

This is a known lazy-analysis pitfall in Zig 0.16:

- The test target compiles a separate module graph rooted at the test
  runner. If no test references `compactMessageInMemoryNew` (it's an
  internal function), the test build never type-checks the offending
  line. The test build reports "628/631 tests passed" while the install
  build fails.

- The install target compiles the full `src/main.zig → nalarcore` graph,
  which DOES reach `compactMessageInMemoryNew` via `runAgenticMultiStepnew`
  → `maybeCompactMessagesNew` → `compactMessageInMemoryNew`. The install
  build then sees the const-cast error and fails.

The two builds compile different module graphs and can disagree on
whether a code path is well-typed. **Always run BOTH `zig build test`
AND `zig build install:linux:system` (or `zig build`) to verify changes.**

## When this bites

- Any function refactored from `messages: *std.ArrayList(T)` (in-place
  mutation via pointer) to `messages: std.ArrayList(T)` (by-value,
  return new list). This is the **"Option B" refactor pattern** in
  this codebase, applied to:
  - `compactMessageInMemoryNew` (workflow.zig:950) — needed the local-copy fix
  - `maybeCompactMessagesNew` (workflow.zig:742) — does NOT call
    `messages.deinit()`, so the const constraint doesn't break it
    (only reads `messages.items`).

- Any new T → T (or T → !T) function that calls methods on the parameter
  which require `*Self`.

- Existing functions like `callCompactAgentNew` that already use the
  `T → !T` pattern: they only READ the parameter, so const is fine
  for them. The bug only manifests if the body tries to mutate.

## How to verify after the fix

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
timeout 180 zig build install:linux:system 2>&1 | tail -n 10
# Expected: "Build Summary: 4/6 steps succeeded" — the cp step fails
# harmlessly with "Permission denied" on /usr/local/bin/nalar.
# The crucial step "compile exe nalar" must succeed (no "1 errors" line).

timeout 180 zig build test --summary all 2>&1 | tail -n 5
# Expected: "test success" and the same 628/631 baseline.
```

## Concrete precedent in this repo

`src/ai_workflow/tui/workflow.zig:1019-1028` — the fix for
`compactMessageInMemoryNew` after the T → T refactor:

```zig
// Free ALL old messages (including ones we "kept" - we have copies now).
// The old list is consumed; the caller must use the returned list.
// Use a mutable local copy because the `messages` parameter is treated
// as `const` in Zig 0.16 when the function signature has matching
// parameter and return types (T → !T), and ArrayList.deinit requires
// `*Self` (not `*const Self`).
var messages_owned = messages;
for (messages_owned.items) |*msg| {
    msg.deinit(allocator);
}
messages_owned.deinit(allocator);
```

## Related

- `custom-http-server-per-request-arena.md` — different Zig 0.16 memory
  ownership pattern (arena per request).
- `zig-0.16-borrowed-sse-slice-ownership.md` — different ownership
  pattern (borrowed slices for SSE payloads).
- `zig-migration-tests-three-pitfalls.md` — related "lazy analysis hides
  bugs until install target compiles" pattern, but for SQL migrations.
- `zig-anonymous-struct-type-identity.md` — different Zig 0.16 structural
  typing gotcha.
