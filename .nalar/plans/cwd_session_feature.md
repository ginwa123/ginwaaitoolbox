# Plan: Send cwd_session from desktop-bun to Zig backend

## Context

The Zig backend already supports `cwd_session` in:
- `http_handlers.zig` - accepts `cwd_session` when creating sessions
- `main.zig` - processes `cwd_session` from XML messages

The Bun frontend needs to:
1. Get the current working directory (cwd) from the Bun process
2. Send `cwd_session` when creating sessions
3. Send `cwd_session` when sending messages to existing sessions

## Files to Modify

### 1. `src/apps/desktop-bun/src/shared/rpc.ts`
- Add `getCwd` request to the RPC schema
- Type: `{ params: undefined, response: string }`

### 2. `src/apps/desktop-bun/src/bun/index.ts`
- Add `getCwd` handler that returns `process.cwd()`

### 3. `src/apps/desktop-bun/src/mainview/pages/SessionChat.tsx`
- Import electroview RPC
- Get cwd via `electrobun.rpc.request.getCwd()` before creating sessions
- Send `cwd_session` in the create session request body
- Send `cwd_session` when sending messages to existing sessions (the TODO at line 157)

## Tests to Write

### `src/apps/desktop-bun/src/bun/rpc.test.ts`
- Test `getCwd` RPC handler returns a valid path string
- Test that the path is absolute

## Verification

```bash
# Run Bun tests
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/src/apps/desktop-bun && bun test

# Run Zig build to ensure no breaking changes
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox && zig build
```

## Implementation Order

1. Write test for `getCwd` RPC handler
2. Add `getCwd` to RPC schema
3. Implement `getCwd` handler in Bun
4. Update SessionChat to send `cwd_session`

## Risks

- Webview may not have direct access to Bun's cwd - use RPC to get it
- Need to handle RPC failure gracefully (use empty string as fallback)
