# Chatbox Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Create a modern chat input bar at the bottom of SessionChat page with gradient send button and auto-expanding textarea.

**Architecture:** Single component (ChatInput) integrated into existing SessionChat layout. Flexbox layout with scrollable message area and fixed input bar at bottom.

**Tech Stack:** SolidJS, Tailwind CSS v4, TypeScript

---

## File Structure

| File | Action | Responsibility |
|------|--------|---------------|
| `src/mainview/components/ChatInput.tsx` | Create | ChatInputBar component with textarea + send button |
| `src/mainview/pages/SessionChat.tsx` | Modify | Import ChatInput, restructure layout for fixed bottom input |

---

## Chunk 1: Create ChatInput Component

### Task 1: Create ChatInput.tsx Component

**Files:**
- Create: `src/mainview/components/ChatInput.tsx`

---

- [ ] **Step 1: Write ChatInput component**

```tsx
import { type Component, createSignal } from 'solid-js';

interface ChatInputProps {
  onSend?: (message: string) => void;
}

const ChatInput: Component<ChatInputProps> = (props) => {
  const [message, setMessage] = createSignal('');
  let textareaRef: HTMLTextAreaElement | undefined;

  const handleSubmit = () => {
    const text = message().trim();
    if (!text) return;
    props.onSend?.(text);
    setMessage('');
    // Reset textarea height
    if (textareaRef) {
      textareaRef.style.height = 'auto';
    }
  };

  const handleKeyDown = (e: KeyboardEvent) => {
    if (e.key === 'Enter' && !e.shiftKey) {
      e.preventDefault();
      handleSubmit();
    }
  };

  const handleInput = () => {
    if (textareaRef) {
      // Auto-expand up to 4 lines (approx 96px with 24px line-height)
      textareaRef.style.height = 'auto';
      textareaRef.style.height = Math.min(textareaRef.scrollHeight, 96) + 'px';
    }
  };

  const canSend = () => message().trim().length > 0;

  return (
    <div class="flex items-end gap-3 px-4 pb-4 bg-neutral-950">
      <div class="flex-1 relative">
        <textarea
          ref={textareaRef}
          value={message()}
          onInput={(e) => {
            setMessage(e.currentTarget.value);
            handleInput();
          }}
          onKeyDown={handleKeyDown}
          placeholder="Type a message..."
          rows={1}
          class={`
            w-full
            bg-neutral-900
            border border-neutral-800
            rounded-xl
            px-4 py-3
            text-sm text-neutral-200
            font-mono
            placeholder:text-neutral-600
            resize-none
            outline-none
            transition-all
            duration-200
            focus:border-yellow-400/50
            focus:shadow-[0_0_0_2px_rgba(250,204,21,0.15)]
            disabled:opacity-50
            disabled:cursor-not-allowed
            max-h-24
          `}
          style={{ "min-height": "48px", "max-height": "96px" }}
        />
      </div>

      <button
        onClick={handleSubmit}
        disabled={!canSend()}
        class={`
          w-12 h-12
          flex items-center justify-center
          rounded-xl
          transition-all
          duration-200
          disabled:opacity-40 disabled:cursor-not-allowed
          ${canSend()
            ? 'bg-gradient-to-br from-yellow-400 to-amber-500 hover:from-yellow-300 hover:to-amber-400 hover:scale-105 active:scale-95 shadow-lg shadow-amber-500/20'
            : 'bg-neutral-800'
          }
        `}
        title="Send message"
      >
        <svg
          width="20"
          height="20"
          viewBox="0 0 24 24"
          fill="none"
          stroke={canSend() ? '#0a0a0a' : '#525252'}
          stroke-width="2"
          stroke-linecap="round"
          stroke-linejoin="round"
        >
          <line x1="22" y1="2" x2="11" y2="13" />
          <polygon points="22 2 15 22 11 13 2 9 22 2" />
        </svg>
      </button>
    </div>
  );
};

export default ChatInput;
```

- [ ] **Step 2: Verify component syntax**

Run: `cd src/apps/desktop-bun && bun run lint`
Expected: No errors

- [ ] **Step 3: Commit**

```bash
git add src/apps/desktop-bun/src/mainview/components/ChatInput.tsx
git commit -m "feat(desktop-bun): create ChatInput component"
```

---

## Chunk 2: Integrate ChatInput into SessionChat

### Task 2: Modify SessionChat to include ChatInput

**Files:**
- Modify: `src/mainview/pages/SessionChat.tsx:1-50` (imports)
- Modify: `src/mainview/pages/SessionChat.tsx:180-250` (return JSX structure)

---

- [ ] **Step 1: Add ChatInput import at top of file**

Find (around line 5):
```tsx
import { baseUrl } from '../utils/baseUrl';
import { type XmlMessage, decodeXmlEntities, parseMessages } from '../utils/xmlParser';
```

Add after:
```tsx
import ChatInput from '../components/ChatInput';
```

---

- [ ] **Step 2: Restructure the return JSX**

Find the return statement (around line 180):
```tsx
return (
    <div class="h-full flex flex-col bg-neutral-950 font-mono">
      {/* Session Header */}
      <div class="border-b border-neutral-800 pb-6 mb-6 flex-shrink-0">
        ...
      </div>

      {/* Messages */}
      <div class="flex-1 min-h-0">
        ...
      </div>
    </div>
  );
```

Replace with:
```tsx
return (
    <div class="h-full flex flex-col bg-neutral-950 font-mono">
      {/* Session Header */}
      <div class="border-b border-neutral-800 pb-6 mb-6 flex-shrink-0 px-4 pt-4">
        ...
      </div>

      {/* Messages */}
      <div class="flex-1 min-h-0 overflow-hidden">
        ...
      </div>

      {/* Chat Input */}
      <ChatInput onSend={(msg) => console.log('Send:', msg)} />
    </div>
  );
```

**Note:** Remove `px-4` from main div if needed, and adjust padding on messages area to ensure proper spacing.

---

- [ ] **Step 3: Verify build**

Run: `cd src/apps/desktop-bun && bun run build 2>&1 | head -n 30`
Expected: Build succeeds without errors

- [ ] **Step 4: Test in development mode**

Run: `cd src/apps/desktop-bun && bun run dev`
Expected: App starts, navigate to session page to see chat input at bottom

- [ ] **Step 5: Commit**

```bash
git add src/apps/desktop-bun/src/mainview/pages/SessionChat.tsx
git commit -m "feat(desktop-bun): integrate ChatInput into SessionChat page"
```

---

## Verification Checklist

After implementation, verify:

- [ ] ChatInput appears at bottom of SessionChat page
- [ ] Textarea auto-expands up to 4 lines when typing
- [ ] Send button disabled when input is empty
- [ ] Send button has yellow gradient when active
- [ ] Pressing Enter sends message (Shift+Enter for newline)
- [ ] Focus shows yellow glow border
- [ ] Dark theme matches existing app aesthetic
- [ ] No console errors
