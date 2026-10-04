# Electrobun RPC Guide — Finally Makes Sense! 🎯

**TL;DR:** RPC lets your Bun (main process) and Webview (browser) talk to each other with **type safety**.

---

## The Two Sides

| Side | Where Code Runs | Key Files |
|------|-----------------|-----------|
| **Bun** | Main process (your server/backend) | `src/bun/index.ts` |
| **Webview** | Browser UI (React/Solid/etc) | `src/mainview/main.tsx` |

---

## Step 1: Define Your Shared RPC Schema

Create a **shared** file that both sides import:

```typescript
// src/shared/rpc.ts
import { RPCSchema } from 'electrobun/bun';

// This defines WHAT can be called from each side
export type MyRPCType = {
  bun: RPCSchema<{
    // What the BUN side handles (webview calls these)
    requests: {
      getUserData: {
        params: { userId: string };
        response: { name: string; email: string };
      };
    };
    // One-way messages FROM webview TO bun
    messages: {
      notifyBun: { message: string };
    };
  }>;
  webview: RPCSchema<{
    // What the WEBVIEW side handles (bun calls these)
    requests: {
      calculateTotal: {
        params: { items: number[] };
        response: number;
      };
    };
    // One-way messages FROM bun TO webview
    messages: {
      notifyWebview: { event: string };
    };
  }>;
};
```

### Key Concept: Who Handles What?

```
┌─────────────────┐                              ┌─────────────────┐
│      BUN        │                              │    WEBVIEW      │
│   (Server)      │                              │   (Browser)     │
├─────────────────┤                              ├─────────────────┤
│  Handlers for:  │                              │  Handlers for:  │
│  - bun.requests │ ◄──── request/response ────► │ - webview.      │
│  - bun.messages │                              │   requests      │
│                 │                              │                 │
│  Call via:      │                              │  Call via:      │
│  - webview.     │                              │  - bun.          │
│    requests     │ ────── one-way ────────────► │    requests     │
│  - webview.     │                              │  - bun.          │
│    messages     │                              │    messages     │
└─────────────────┘                              └─────────────────┘
```

---

## Step 2: Bun Side — Define Handlers

```typescript
// src/bun/index.ts
import { BrowserView } from 'electrobun/bun';
import type { MyRPCType } from '../shared/rpc';

// Define WHAT Bun can handle when called from webview
const myRPC = BrowserView.defineRPC<MyRPCType>({
  maxRequestTime: 5000, // 5 second timeout
  handlers: {
    // These run in BUN when webview calls them
    requests: {
      getUserData: ({ userId }) => {
        console.log('Webview wants user data for:', userId);
        return { name: 'Alice', email: 'alice@example.com' };
      },
    },
    // One-way messages from webview
    messages: {
      notifyBun: ({ message }) => {
        console.log('Message from webview:', message);
      },
    },
  },
});

// Pass RPC to the window
const mainWindow = new BrowserView({
  title: 'My App',
  url: 'http://localhost:5173',
  rpc: myRPC, // ✅ THIS IS CRITICAL
});
```

---

## Step 3: Webview Side — Call Bun Functions

```tsx
// src/mainview/main.tsx
import { Electroview } from 'electrobun/view';
import type { MyRPCType } from '../shared/rpc';

const App = () => {
  // 1. Create RPC instance
  const rpc = Electroview.defineRPC<MyRPCType>({
    handlers: {
      // What WEBVIEW handles when BUN calls it
      requests: {
        calculateTotal: ({ items }) => {
          return items.reduce((sum, n) => sum + n, 0);
        },
      },
      messages: {
        notifyWebview: ({ event }) => {
          console.log('Event from bun:', event);
        },
      },
    },
  });

  // 2. Wrap in Electroview
  const electroview = new Electroview({ rpc });

  // 3. NOW you can call BUN functions!
  const callBun = async () => {
    // Call a BUN function and get response
    const user = await electroview.rpc.request.getUserData({ 
      userId: '123' 
    });
    console.log('Got user from bun:', user);
    
    // Send a one-way message to bun (no response)
    electroview.rpc.send.notifyBun({ message: 'Hello from webview!' });
  };

  return <button onClick={callBun}>Call Bun</button>;
};
```

---

## The Four Ways to Communicate

### 1. Webview → Bun: `request.someFunction()` — Call & Wait for Response
```typescript
// In Webview (browser)
const result = await electroview.rpc.request.getUserData({ userId: '123' });
// result = { name: 'Alice', email: 'alice@example.com' }
```

### 2. Webview → Bun: `send.someMessage()` — Fire & Forget
```typescript
// In Webview (browser) - no response needed
electroview.rpc.send.notifyBun({ message: 'Done!' });
```

### 3. Bun → Webview: `webview.rpc.request.someFunction()` — Call & Wait
```typescript
// In Bun (server) - call webview function
const answer = await win.webview.rpc.request.someWebviewFunction({ a: 4, b: 6 });
console.log(answer); // 10
```

### 4. Bun → Webview: `webview.rpc.send.someMessage()` — Fire & Forget
```typescript
// In Bun (server) - send message to webview
win.webview.rpc.send.logToWebview({ msg: "Hello from Bun!" });
```

---

## Common Mistakes & Fixes

### ❌ Mistake 1: Forgetting to pass `rpc` to window
```typescript
// WRONG
const mainWindow = new BrowserView({ title: 'App', url: '...' });

// CORRECT
const mainWindow = new BrowserView({ title: 'App', url: '...', rpc: myRPC });
```

### ❌ Mistake 2: Schema mismatch
```typescript
// BUN says:
requests: {
  getUserData: { params: { userId: string }, response: User }
}

// WEBVIEW must call with matching params:
electroview.rpc.request.getUserData({ userId: '123' }) // ✅
electroview.rpc.request.getUserData({ id: '123' })     // ❌ Wrong param name!
```

### ❌ Mistake 3: Importing Electroview in Bun
```typescript
// WRONG - Electroview is for BROWSER only
import { Electroview } from 'electrobun/view'; // in bun/index.ts ❌

// CORRECT
import { BrowserView } from 'electrobun/bun'; // in bun/index.ts ✅
```

### 💡 Pro Tip: Wildcard Message Handler `*`
```typescript
// Catch ALL messages with a single handler
messages: {
  "*": (messageName, payload) => {
    console.log("Received:", messageName, payload);
  },
  // Also can have specific handlers
  logToBun: ({ msg }) => console.log(msg),
}
```

### 💡 Built-in: `evaluateJavascriptWithResponse`
Electrobun has a built-in way to run ANY JavaScript in the webview and get the result back — no custom RPC handler needed!

```typescript
// In Bun - run arbitrary JS in webview
const title = await win.webview.rpc.request.evaluateJavascriptWithResponse({
  script: "document.title"
});

// Works with expressions
const sum = await win.webview.rpc.request.evaluateJavascriptWithResponse({
  script: "2 + 2"
});

// Async code is automatically awaited!
const data = await win.webview.rpc.request.evaluateJavascriptWithResponse({
  script: "fetch('/api/user').then(r => r.json())"
});
```

---

## Quick Reference: Imports

| Location | Import From |
|----------|-------------|
| Bun side | `import { BrowserView } from 'electrobun/bun'` |
| Webview side | `import { Electroview } from 'electrobun/view'` |
| Shared types | `import type { RPCSchema } from 'electrobun/bun'` |

---

## Working Example (from desktop-bun app)

### Shared Schema (`src/shared/rpc.ts`):
```typescript
import { RPCSchema } from 'electrobun/bun';

export type MyWebviewRPCType = {
  bun: RPCSchema<{
    requests: {
      someBunFunction: { params: { a: number; b: number }; response: number };
    };
    messages: {
      logToBun: { msg: string };
    };
  }>;
  webview: RPCSchema<{
    requests: {
      someWebviewFunction: { params: { a: number; b: number }; response: number };
    };
    messages: {
      logToWebview: { msg: string };
    };
  }>;
};
```

### Bun Handler (`src/bun/index.ts`):
```typescript
import { BrowserView, BrowserWindow } from 'electrobun/bun';
import type { MyWebviewRPCType } from '../shared/rpc';

const myWebviewRPC = BrowserView.defineRPC<MyWebviewRPCType>({
  handlers: {
    requests: {
      // What BUN handles when WEBVIEW calls it
      someBunFunction: ({ a, b }) => a + b,  // Returns to webview
    },
    messages: {
      // What BUN handles when WEBVIEW sends it
      logToBun: ({ msg }) => console.log('From browser:', msg),
    },
  },
});

// Pass RPC to window
const win = new BrowserWindow({ url: '...', rpc: myWebviewRPC });

// BUN can also CALL WEBVIEW functions!
const result = await win.webview.rpc.request.someWebviewFunction({ a: 4, b: 6 });
console.log(result); // e.g., 24 (if webview returns a * b)

// BUN can also SEND messages to WEBVIEW
win.webview.rpc.send.logToWebview({ msg: "Hello from Bun!" });
```

### Webview Caller (`src/mainview/main.tsx`):
```typescript
import { Electroview } from 'electrobun/view';
import type { MyWebviewRPCType } from '../shared/rpc';

const rpc = Electroview.defineRPC<MyWebviewRPCType>({
  handlers: {
    requests: {
      someWebviewFunction: ({ a, b }) => a * b,
    },
    messages: {
      logToWebview: ({ msg }) => console.log('From bun:', msg),
    },
  },
});

const electroview = new Electroview({ rpc });

// Call bun's function
const result = await electroview.rpc.request.someBunFunction({ a: 5, b: 3 });
console.log(result); // 8

// Send message to bun
electroview.rpc.send.logToBun({ msg: 'Hello!' });
```

---

## Debugging Tips

1. **Check the console** — Both Bun and Webview logs show RPC calls
2. **Timeout errors** — Increase `maxRequestTime` if functions take long
3. **Type errors** — Ensure schema params match exactly (names and types)
4. **"Cannot send" errors** — Means transport not set up (check `rpc` passed to window)

---

## Summary

```
1. Define shared schema (what each side can call)
2. Bun: BrowserView.defineRPC({ handlers: { requests: {...}, messages: {...} } })
3. Bun: Pass rpc to BrowserWindow
4. Webview: Electroview.defineRPC({ handlers: {...} })
5. Webview: new Electroview({ rpc })

--- Communication ---

Webview → Bun:
  electroview.rpc.request.someFunction({ params })  // call & wait
  electroview.rpc.send.someMessage({ data })         // fire & forget

Bun → Webview:
  win.webview.rpc.request.someFunction({ params })  // call & wait
  win.webview.rpc.send.someMessage({ data })          // fire & forget
```

That's it! 🎉
