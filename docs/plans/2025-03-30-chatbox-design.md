# Chatbox Design — SessionChat Page

**Date:** 2025-03-30
**Status:** Approved

## Overview

A modern chat input bar integrated at the bottom of the existing SessionChat page, allowing users to type and send messages to the AI agent backend.

---

## Design Decisions

### Placement
- **Location:** Bottom of SessionChat page only
- **Scope:** SessionChat-specific, not global

### Aesthetic
- **Style:** Modern chat with gradient accents
- **Theme:** Dark mode (matches existing `#0a0a0a` base)
- **Accent:** Yellow/Gold gradient (`#facc15` → `#f59e0b`)

---

## Component: ChatInputBar

### Visual Design

| Property | Value |
|----------|-------|
| Position | Fixed at bottom |
| Background | `#141414` |
| Border | `1px solid #2a2a2a` |
| Border Radius | `12px` |
| Shadow | `0 4px 12px rgba(0,0,0,0.3)` |
| Padding | `12px 16px` |
| Margin | `16px` from edges |

### Textarea

| Property | Value |
|----------|-------|
| Font | JetBrains Mono, 14px |
| Text Color | `#e5e5e5` |
| Placeholder | "Type a message..." in `#525252` |
| Min Height | 1 line |
| Max Height | 4 lines |
| Auto-expand | Yes |
| Resize | None |
| Focus Glow | `0 0 0 2px rgba(250,204,21,0.3)` |

### Send Button

| Property | Value |
|----------|-------|
| Size | 40x40px |
| Border Radius | `10px` |
| Background | Linear gradient (`#facc15` → `#f59e0b`) |
| Icon Color | `#0a0a0a` |
| Icon | Arrow/send |
| Disabled State | Grayed out when input empty |
| Hover | Scale 1.05, brighter gradient |

---

## Layout Structure

```
┌─────────────────────────────────────────────────┐
│  Session Chat (messages area - scrollable)      │
│  ...                                            │
│  ...                                            │
│                                                 │
├─────────────────────────────────────────────────┤
│  ┌─────────────────────────────────┐  ┌────┐  │
│  │ Type a message...               │  │ ➤  │  │
│  └─────────────────────────────────┘  └────┘  │
└─────────────────────────────────────────────────┘
```

---

## Behavior (Phase 2 - Not Implemented)

The following are out of scope for initial implementation:

- Backend integration (HTTP/RPC calls)
- Streaming response display
- Typing indicators
- Message persistence

---

## Files to Create/Modify

1. **Create:** `src/mainview/components/ChatInput.tsx`
   - ChatInputBar component with textarea and send button

2. **Modify:** `src/mainview/pages/SessionChat.tsx`
   - Import and place ChatInput at bottom
   - Wrap messages area with flex layout

---

## Acceptance Criteria

- [ ] ChatInput appears at bottom of SessionChat page
- [ ] Textarea auto-expands up to 4 lines
- [ ] Send button is disabled when input is empty
- [ ] Send button has gradient styling and hover effect
- [ ] Focus state shows yellow glow
- [ ] Design matches dark theme aesthetic
- [ ] Component is responsive
