# Session Messages Lazy Scroll Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement cursor-based lazy scroll for session messages — load latest first when clicking a session, lazy load older messages when scrolling up.

**Architecture:** Backend enhances existing session messages API with proper cursor pagination (`has_more`, `next_cursor`). Frontend uses TanStack Query for infinite data fetching + TanStack Virtual for high-performance list rendering with prepend scroll-up-to-load-more pattern.

**Tech Stack:** Zig 0.15.2 (backend), SolidJS + TanStack Query + TanStack Virtual (frontend), Bun runtime.

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────┐
│                          User Interaction                           │
│                                                                      │
│  Click Session ─────────────────────────────────────────────────┐   │
│       │                                                          │   │
│       ▼                                                          ▼   │
│  ┌─────────────┐    ┌─────────────┐    ┌─────────────────────────────┐
│  │ Fetch Latest│    │ Show Latest │    │ Scroll to Bottom            │
│  │ (direction= │───▶│  Messages   │───▶│ (scrollTop = scrollHeight)  │
│  │  desc)      │    │             │    │                             │
│  └─────────────┘    └─────────────┘    └─────────────────────────────┘
│                           │                                        │
│                           │                                        │
│                           ▼                                        │
│  ┌──────────────────────────────────────────────────────────────┐  │
│  │ User Scrolls UP ──▶ ScrollTop < 200px ──▶ Trigger Load More  │  │
│  │                              │                                 │  │
│  │                              ▼                                 │  │
│  │  ┌──────────────────┐  ┌───────────────────────────────────┐  │  │
│  │  │ Store scrollHeight│  │ Fetch older (cursor = oldest ID) │  │  │
│  │  │ before prepend    │  │ direction=asc                      │  │  │
│  │  └──────────────────┘  └───────────────────────────────────┘  │  │
│  │                              │                                 │  │
│  │                              ▼                                 │  │
│  │  ┌──────────────────────────────────────────────────────────┐│  │
│  │  │ PREPEND older messages to beginning of array             ││  │
│  │  │ Calculate delta = newScrollHeight - prevScrollHeight     ││  │
│  │  │ Restore scrollTop += delta (keeps view position stable)  ││  │
│  │  └──────────────────────────────────────────────────────────┘│  │
│  └──────────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────┘
```

---

## Backend Enhancement

### Modify: `src/ai_workflow/tui/session_db.zig`

**Changes:**
1. Enhance `get_session_messages_sorted()` to return `has_more` and `next_cursor`
2. Fix cursor logic: use `id < cursor` (not `id > cursor`) for ascending order pagination
3. Return `next_cursor` as the last message ID in the result set

**New Response Format:**

```zig
// Add to SessionMessageResponse
has_more: bool,
next_cursor: ?[:0]const u8,
```

**Modified Function:**
```zig
pub fn get_session_messages_sorted(
    allocator: std.mem.Allocator,
    db: *sqlite.Db,
    session_id: []const u8,
    limit: usize,
    cursor: ?[]const u8,
    sort_spec: SortSpec,
    direction: Direction,
) !SessionMessageResponse {
    // Build query with proper cursor logic
    // direction=asc: WHERE id < cursor ORDER BY created_at ASC, id DESC LIMIT ?
    // direction=desc: WHERE id > cursor ORDER BY created_at DESC, id ASC LIMIT ?
    
    // After fetching, determine has_more
    const actual_count = try stmt.count(allocator, ...);
    const has_more = actual_count > limit;
    
    // next_cursor = last message ID if has_more
    const next_cursor = if (has_more) last_message_id else null;
    
    return SessionMessageResponse{
        .messages = messages,
        .has_more = has_more,
        .next_cursor = next_cursor,
    };
}
```

### Modify: `src/ai_workflow/tui/http_handlers.zig`

**Changes:**
1. Accept `direction=desc` for fetching latest messages first
2. Parse `cursor` parameter
3. Return `has_more` and `next_cursor` in JSON/XML responses

---

## Frontend Enhancement

### Modify: `src/apps/desktop-bun/src/shared/rpc.ts`

**Add Types:**
```typescript
interface SessionMessagesResponse {
  messages: ChatMessage[];
  has_more: boolean;
  next_cursor: string | null;
}
```

### Modify: `src/apps/desktop-bun/src/mainview/pages/SessionChat.tsx`

**Changes:**
1. Import TanStack Query and Virtual
2. Replace `createEffect` message fetching with `useInfiniteQuery`
3. Implement prepend scroll pattern
4. Add virtualized message list

**New Component Structure:**
```typescript
import { createSignal, createMemo, For, Show, onMount } from 'solid-js';
import { createInfiniteQuery } from '@tanstack/solid-query';
import { createVirtualizer } from '@tanstack/solid-virtual';

// Fetch messages with cursor pagination
const messagesQuery = createInfiniteQuery(() => ({
  queryKey: ['session-messages', params.sessionId],
  queryFn: async ({ pageParam }) => {
    const cursor = pageParam ?? '';
    const direction = pageParam === undefined ? 'desc' : 'asc';
    const res = await fetch(
      `${baseUrl}/api/session/${params.sessionId}/messages?format=json&limit=50&cursor=${cursor}&direction=${direction}`
    );
    return res.json() as Promise<SessionMessagesResponse>;
  },
  initialPageParam: undefined as string | undefined,
  getNextPageParam: (lastPage) => lastPage.next_cursor ?? undefined,
}));

// Virtualized list
const allMessages = createMemo(() => 
  messagesQuery.data?.pages.flatMap(p => p.messages) ?? []
);

const virtualizer = createVirtualizer({
  get count() { return allMessages().length; },
  getScrollElement: () => scrollRef,
  estimateSize: () => 80,
  overscan: 5,
});

// Prepend scroll pattern
let prevScrollHeight = 0;
const handlePrepend = () => {
  if (scrollRef) {
    prevScrollHeight = scrollRef.scrollHeight;
  }
  // After setMessages with prepend...
  requestAnimationFrame(() => {
    if (scrollRef) {
      const delta = scrollRef.scrollHeight - prevScrollHeight;
      scrollRef.scrollTop += delta;
    }
  });
};

// Scroll detection for lazy load
const handleScroll = () => {
  if (!scrollRef) return;
  if (scrollRef.scrollTop < 200 && 
      messagesQuery.hasNextPage && 
      !messagesQuery.isFetchingNextPage) {
    messagesQuery.fetchNextPage();
  }
};
```

---

## Chunk 1: Backend API Enhancement

### Task 1.1: Update SessionMessageResponse struct

**Files:**
- Modify: `src/ai_workflow/tui/session_db.zig:1-50`

- [ ] **Step 1: Add has_more and next_cursor fields to SessionMessageResponse**

```zig
pub const SessionMessageResponse = struct {
    messages: []const SessionMessage,
    has_more: bool,
    next_cursor: ?[:0]const u8,
};
```

- [ ] **Step 2: Run test to verify compilation**

Run: `timeout 60 zig build 2>&1 | head -n 50`
Expected: Compiles without errors

---

### Task 1.2: Fix cursor pagination logic

**Files:**
- Modify: `src/ai_workflow/tui/session_db.zig:268-335` (`get_session_messages_sorted`)

- [ ] **Step 1: Write failing test for cursor pagination**

```zig
test "cursor pagination returns has_more when more items exist" {
    // Setup: Insert 10 messages
    // Query with limit=5
    // Assert: has_more == true
    // Assert: next_cursor == 5th message id
}
```

Run: `timeout 60 zig build test 2>&1 | head -n 100`
Expected: FAIL - has_more field not returned

- [ ] **Step 2: Implement cursor pagination**

```zig
pub fn get_session_messages_sorted(
    allocator: std.mem.Allocator,
    db: *sqlite.Db,
    session_id: []const u8,
    limit: usize,
    cursor: ?[]const u8,
    sort_spec: SortSpec,
    direction: Direction,
) !SessionMessageResponse {
    // Query with limit+1 to check for more
    const query_limit = limit + 1;
    
    // Build query based on direction and cursor
    // direction=asc with cursor: WHERE id < cursor
    // direction=desc without cursor: ORDER BY created_at DESC
    // direction=asc without cursor: ORDER BY created_at ASC
    
    // Fetch query_limit rows
    // If rows == query_limit, has_more = true
    // If rows == query_limit, next_cursor = last row's id
    
    // Slice to limit if has_more
    const actual_messages = if (messages.len > limit) messages[0..limit] else messages;
    
    return SessionMessageResponse{
        .messages = actual_messages,
        .has_more = messages.len > limit,
        .next_cursor = if (messages.len > limit) messages[limit - 1].id else null,
    };
}
```

- [ ] **Step 3: Run test to verify it passes**

Run: `timeout 60 zig build test 2>&1 | head -n 100`
Expected: PASS

- [ ] **Step 4: Commit**

```bash
git add src/ai_workflow/tui/session_db.zig
git commit -m "feat: add cursor pagination has_more and next_cursor to session messages"
```

---

### Task 1.3: Update HTTP handler to return new fields

**Files:**
- Modify: `src/ai_workflow/tui/http_handlers.zig:308-370`

- [ ] **Step 1: Update JSON response builder**

```zig
// In buildSessionMessagesJson
try writer.print(
    \\{{"messages":{s},"has_more":{},"next_cursor":{}
, .{
    messages_json,
    if (response.has_more) "true" else "false",
    if (response.next_cursor) |c| try json.escapeString(c) else "null",
});
```

- [ ] **Step 2: Update XML response builder**

```xml
<messages>
  {s}
  <has_more>{s}</has_more>
  <next_cursor>{s}</next_cursor>
</messages>
```

- [ ] **Step 3: Test with curl**

Run: `curl 'http://localhost:8081/api/session/test/messages?limit=5&format=json'`
Expected: Response includes `has_more` and `next_cursor`

---

## Chunk 2: Frontend Lazy Scroll Implementation

### Task 2.1: Update RPC types

**Files:**
- Modify: `src/apps/desktop-bun/src/shared/rpc.ts`

- [ ] **Step 1: Add SessionMessagesResponse type**

```typescript
export interface SessionMessagesResponse {
  messages: ChatMessage[];
  has_more: boolean;
  next_cursor: string | null;
}
```

- [ ] **Step 2: Commit**

```bash
git add src/apps/desktop-bun/src/shared/rpc.ts
git commit -m "feat: add SessionMessagesResponse type with has_more and next_cursor"
```

---

### Task 2.2: Implement lazy scroll hook

**Files:**
- Create: `src/apps/desktop-bun/src/mainview/hooks/useMessagesInfiniteScroll.ts`

- [ ] **Step 1: Write failing test**

```typescript
import { render } from '@testing-library/solid-js';
import { createSignal } from 'solid-js';
import { useMessagesInfiniteScroll } from './useMessagesInfiniteScroll';

test('calculates correct scroll delta for prepend', async () => {
  const [messages, setMessages] = createSignal(['a', 'b', 'c']);
  const scrollHeight = 300;
  
  const { handlePrepend } = useMessagesInfiniteScroll({
    messages,
    setMessages,
    scrollHeight,
  });
  
  handlePrepend(['x', 'y']);
  
  expect(messages()).toEqual(['x', 'y', 'a', 'b', 'c']);
});
```

Run: `cd src/apps/desktop-bun && bun test 2>&1`
Expected: FAIL - file doesn't exist

- [ ] **Step 2: Implement hook**

```typescript
import { Accessor, Setter } from 'solid-js';
import { createSignal } from 'solid-js';
import { ChatMessage } from '../../shared/rpc';

interface UseMessagesInfiniteScrollOptions {
  messages: Accessor<ChatMessage[]>;
  setMessages: Setter<ChatMessage[]>;
  scrollHeight: Accessor<number>;
}

export function useMessagesInfiniteScroll(options: UseMessagesInfiniteScrollOptions) {
  let prevScrollHeight = 0;
  let scrollRef: HTMLDivElement | undefined;
  
  const { messages, setMessages, scrollHeight } = options;

  // Call before prepending new messages
  const storeScrollPosition = () => {
    prevScrollHeight = scrollHeight();
  };

  // Call after prepending to restore scroll position
  const restoreScrollPosition = () => {
    requestAnimationFrame(() => {
      if (scrollRef) {
        const newHeight = scrollRef.scrollHeight;
        const delta = newHeight - prevScrollHeight;
        scrollRef.scrollTop += delta;
      }
    });
  };

  const prependMessages = (newMessages: ChatMessage[]) => {
    storeScrollPosition();
    setMessages(prev => [...newMessages, ...prev]);
    restoreScrollPosition();
  };

  return {
    prependMessages,
    setScrollRef: (el: HTMLDivElement) => { scrollRef = el; },
  };
}
```

- [ ] **Step 3: Run test to verify it passes**

Run: `cd src/apps/desktop-bun && bun test`
Expected: PASS

- [ ] **Step 4: Commit**

```bash
git add src/apps/desktop-bun/src/mainview/hooks/useMessagesInfiniteScroll.ts
git commit -m "feat: implement useMessagesInfiniteScroll hook"
```

---

### Task 2.3: Integrate with SessionChat component

**Files:**
- Modify: `src/apps/desktop-bun/src/mainview/pages/SessionChat.tsx`

- [ ] **Step 1: Write failing test for lazy scroll**

```typescript
import { render, screen, fireEvent } from '@testing-library/solid-js';
import SessionChat from './SessionChat';

test('loads latest messages on mount, lazy loads on scroll up', async () => {
  // Mock fetch to return messages
  // Render SessionChat with sessionId
  // Assert latest messages shown
  
  // Simulate scroll to top
  fireEvent.scroll(container, { target: { scrollTop: 0 } });
  
  // Assert older messages fetched and prepended
});
```

Run: `cd src/apps/desktop-bun && bun test 2>&1`
Expected: FAIL - lazy scroll not implemented

- [ ] **Step 2: Implement lazy scroll in SessionChat**

```typescript
import { createSignal, createMemo, onMount, Show } from 'solid-js';
import { createInfiniteQuery } from '@tanstack/solid-query';
import { createVirtualizer } from '@tanstack/solid-virtual';

export default function SessionChat(params: { sessionId: string }) {
  let scrollRef: HTMLDivElement | undefined;
  const [scrollHeight, setScrollHeight] = createSignal(0);

  // Infinite query for messages
  const messagesQuery = createInfiniteQuery(() => ({
    queryKey: ['session-messages', params.sessionId],
    queryFn: async ({ pageParam }) => {
      const direction = pageParam === undefined ? 'desc' : 'asc';
      const url = new URL(`${baseUrl}/api/session/${params.sessionId}/messages`);
      url.searchParams.set('format', 'json');
      url.searchParams.set('limit', '50');
      if (pageParam !== undefined) {
        url.searchParams.set('cursor', pageParam);
      }
      url.searchParams.set('direction', direction);
      
      const res = await fetch(url.toString());
      return res.json() as Promise<SessionMessagesResponse>;
    },
    initialPageParam: undefined as string | undefined,
    getNextPageParam: (lastPage) => lastPage.next_cursor ?? undefined,
  }));

  // Flatten all pages into single messages array
  const allMessages = createMemo(() => 
    messagesQuery.data?.pages.flatMap(p => p.messages) ?? []
  );

  // Virtualizer for performance
  const virtualizer = createVirtualizer({
    get count() { return allMessages().length; },
    getScrollElement: () => scrollRef ?? null,
    estimateSize: () => 80,
    overscan: 5,
  });

  // Scroll handler for lazy loading
  const handleScroll = () => {
    if (!scrollRef) return;
    setScrollHeight(scrollRef.scrollHeight);
    
    // Trigger load more when scrolled near top
    if (scrollRef.scrollTop < 200 && 
        messagesQuery.hasNextPage && 
        !messagesQuery.isFetchingNextPage) {
      messagesQuery.fetchNextPage();
    }
  };

  // Scroll to bottom on new latest messages (first load)
  onMount(() => {
    if (scrollRef) {
      scrollRef.scrollTop = scrollRef.scrollHeight;
    }
  });

  return (
    <div class="flex flex-col h-full">
      <div 
        ref={scrollRef}
        class="flex-1 overflow-y-auto"
        onScroll={handleScroll}
      >
        <div 
          style={{ height: `${virtualizer.getTotalSize()}px`, position: 'relative' }}
        >
          <For each={virtualizer.getVirtualItems()}>
            {(virtualRow) => (
              <div
                data-index={virtualRow.index}
                ref={virtualizer.measureElement}
                style={{
                  position: 'absolute',
                  top: 0,
                  left: 0,
                  width: '100%',
                  height: `${virtualRow.size}px`,
                  transform: `translateY(${virtualRow.start}px)`,
                }}
              >
                <MessageRow message={allMessages()[virtualRow.index]} />
              </div>
            )}
          </For>
        </div>
      </div>

      {/* Loading indicator */}
      <Show when={messagesQuery.isFetchingNextPage}>
        <div class="p-2 text-center text-sm text-gray-500">
          Loading older messages...
        </div>
      </Show>

      <ChatInput sessionId={params.sessionId} />
    </div>
  );
}
```

- [ ] **Step 3: Run test to verify it passes**

Run: `cd src/apps/desktop-bun && bun test`
Expected: PASS

- [ ] **Step 4: Commit**

```bash
git add src/apps/desktop-bun/src/mainview/pages/SessionChat.tsx
git commit -m "feat: implement lazy scroll with TanStack Query and Virtual"
```

---

## Chunk 3: Testing & Verification

### Task 3.1: Integration test with real API

- [ ] **Step 1: Start server and test cursor pagination**

```bash
# Start server
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
timeout 300 zig build run &
sleep 5

# Test 1: Get latest messages (direction=desc, no cursor)
curl 'http://localhost:8081/api/session/session_1774900538/messages?format=json&limit=5&direction=desc' | jq .

# Test 2: Get older messages with cursor
curl 'http://localhost:8081/api/session/session_1774900538/messages?format=json&limit=5&direction=asc&cursor=<last_message_id>' | jq .

# Test 3: XML format
curl 'http://localhost:8081/api/session/session_1774900538/messages?format=xml&limit=5'
```

Expected:
- `has_more: true` when more messages exist
- `next_cursor` returns the last message ID
- XML response includes `<has_more>` and `<next_cursor>` elements

---

### Task 3.2: End-to-end browser test

- [ ] **Step 1: Test lazy scroll flow**

1. Open browser dev tools
2. Navigate to session detail page
3. Open Network tab, filter by `messages`
4. Verify initial request: `direction=desc`
5. Scroll to top
6. Verify second request: `direction=asc&cursor=<id>`
7. Verify messages prepended, scroll position maintained

---

## File Summary

| File | Action | Purpose |
|------|--------|---------|
| `src/ai_workflow/tui/session_db.zig` | Modify | Add `has_more`, `next_cursor` to response |
| `src/ai_workflow/tui/http_handlers.zig` | Modify | Include new fields in JSON/XML |
| `src/apps/desktop-bun/src/shared/rpc.ts` | Modify | Add `SessionMessagesResponse` type |
| `src/apps/desktop-bun/src/mainview/hooks/useMessagesInfiniteScroll.ts` | Create | Scroll position tracking hook |
| `src/apps/desktop-bun/src/mainview/pages/SessionChat.tsx` | Modify | Integrate lazy scroll |

---

## Verification Checklist

- [ ] Backend returns `has_more` and `next_cursor`
- [ ] Backend works with `direction=desc` for latest first
- [ ] Frontend loads latest messages on session select
- [ ] Frontend lazy loads older messages on scroll up
- [ ] Scroll position maintained after prepend
- [ ] TanStack Virtual renders efficiently
- [ ] Loading indicator shows during fetch
- [ ] No duplicate messages on repeated scrolls
