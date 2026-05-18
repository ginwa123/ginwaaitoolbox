---
 name: desktop-frontend-build
 description: "Frontend Vue/TypeScript development for nalar desktop app"
---

# Desktop Frontend Build Skill

## Project Structure
- **Location:** `/src/apps/desktop`
- **Framework:** Vue 3 + TypeScript + Vite + Bun
- **State:** Pinia stores with localStorage persistence

## Build Commands
```bash
cd src/apps/desktop
bun run build      # Full build with type-check
bun run dev        # Development server
bun run type-check # TypeScript only (vue-tsc)
```

## Common Issues & Fixes

### 1. TypeScript Errors Blocking Build

**Problem:** `error TS2339` or `error TS2304` during `vue-tsc --build`

**Common Causes:**
- Missing variable declarations (vars used without being defined)
- Type mismatches (e.g., `timestamp` vs `created_at`)
- Property doesn't exist on type (e.g., `worker_id` vs `id`)

**Debugging:**
```bash
# Run type-check only to see all errors
cd src/apps/desktop && bun run type-check 2>&1 | head -n 100
```

### 2. Missing Variable Declarations

**Symptom:** `Cannot find name 'X'` errors

**Fix:** Variables used in template but defined elsewhere (e.g., in child components) need to be lifted to parent or passed via props/emits.

**Example - Sidebar.vue:**
```typescript
// Sidebar.vue needed these for template, but they were defined in ChatsList.vue
const navItems = ref<Array<{...}>>([])
const chatsLoading = ref(false)
const chatsHasMore = ref(false)
const chatsNextCursor = ref<string | null>(null)
const chatsSortDirection = ref<'asc' | 'desc'>('desc')
const handleSessionEvent = (event: api.SessionEvent) => { ... }
```

### 3. API Type Mismatches

**Symptom:** `Property 'X' does not exist on type 'Y'`

**Common fixes:**

| Backend Field | Frontend Expected | Fix |
|---------------|-------------------|-----|
| `id` (Worker) | `worker_id` | Use `worker.id` or `worker.session_id` |
| `created_at` (Message) | `timestamp` | Use `new Date(msg.created_at * 1000)` |
| `created_at` (Message) | `msg.timestamp` | Use `created_at` since API sends `created_at` |

**Debugging API types:**
1. Check backend handler response in Zig code
2. Check `src/api/index.ts` for `export interface` definitions
3. Compare with actual usage in `.vue` files

### 4. Import Path Issues

**Symptom:** Module not found or wrong path

**Fix:** Check `tsconfig.app.json` for path aliases:
```json
{
  "compilerOptions": {
    "paths": {
      "@/*": ["./src/*"]
    }
  }
}
```

Usage: `import { something } from '@/stores/workspaces'`

## Workflow for Fixing Build Errors

### Step 1: Identify Error Type
```bash
cd src/apps/desktop && bun run type-check 2>&1
```

### Step 2: Find Source File
- Read the `.vue` file where error occurs
- Check referenced imports (api, stores)

### Step 3: Check API Types
```bash
# Look at api/index.ts interface definitions
grep -A 20 "export interface Message" src/apps/desktop/src/api/index.ts
grep -A 20 "export interface Worker" src/apps/desktop/src/api/index.ts
```

### Step 4: Apply Minimal Fix
- Match field names to API types
- Add missing variable declarations
- Don't refactor unrelated code

### Step 5: Verify Build
```bash
cd src/apps/desktop && bun run build
```

## Key Files

| File | Purpose |
|------|---------|
| `src/api/index.ts` | All API types and fetch functions |
| `src/stores/` | Pinia stores (workspaces, sidebar, navigation) |
| `src/components/Sidebar.vue` | Main navigation sidebar |
| `src/components/ChatView.vue` | Chat message display |
| `src/components/ChatsList.vue` | Chat list with pagination |
| `src/App.vue` | Root component with SSE polling |

## State Management Pattern

Uses Pinia with localStorage persistence:
```typescript
// stores/sidebar.ts example
import { defineStore } from 'pinia'
import { ref } from 'vue'

const STORAGE_KEY = 'some-key'

export const useSidebarStore = defineStore('sidebar', () => {
  const loadFromStorage = (): type => {
    const saved = localStorage.getItem(STORAGE_KEY)
    return saved ? JSON.parse(saved) : defaultValue
  }
  
  const state = ref(loadFromStorage())
  
  return { state }
})
```

## SSE (Server-Sent Events) Pattern

```typescript
// Create connection
const eventSource = api.createSseConnection(sessionId, 
  (event) => { /* handle event */ },
  (error) => { /* handle error */ },
  () => { /* on connected */ }
)

// Cleanup on unmount
onUnmounted(() => {
  if (eventSource) eventSource.close()
})
```

## Testing Changes

```bash
# Type check only (faster)
cd src/apps/desktop && bun run type-check

# Full build
cd src/apps/desktop && bun run build

# Development with hot reload
cd src/apps/desktop && bun run dev
```

## Lessons Learned (2025-01-20)

### Issue: Missing Variables in Sidebar.vue
- `navItems`, `chatsLoading`, `chatsHasMore`, `chatsNextCursor`, `chatsSortDirection`, `handleSessionEvent`
- These were used in template but declared in child component `ChatsList.vue`
- **Fix:** Moved declarations to parent `Sidebar.vue` since template references them directly

### Issue: Wrong field name in App.vue
- Used `worker.worker_id` but `Worker` interface has `id` not `worker_id`
- **Fix:** Changed to `worker.id || worker.session_id`

### Issue: Wrong field name in ChatView.vue  
- Used `msg.timestamp` but Message interface has `created_at`
- **Fix:** Changed to `msg.created_at` with proper multiplication for date conversion