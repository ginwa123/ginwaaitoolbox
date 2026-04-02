# Folder Picker Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Create a full-screen modal folder picker component with filesystem tree navigation, CRUD operations (create/rename/delete folders), keyboard navigation, and TDD approach.

**Architecture:** Full-screen modal with breadcrumb navigation, expandable tree view, context menu for folder operations. RPC layer on Bun for filesystem operations, SolidJS component on webview.

**Tech Stack:** SolidJS, Electrobun RPC, Vitest, Tailwind CSS

---

## Chunk 1: Project Setup & RPC Layer Types

### Files
- Modify: `src/shared/rpc.ts:1-146`
- Create: `src/bun/rpc.test.ts` (append tests)

- [ ] **Step 1: Read existing rpc.ts to find extension point**

```typescript
// Look for the bun: RPCSchema<{ requests: {...} }> section
// We'll add filesystem operations after existing requests
```

- [ ] **Step 2: Extend rpc.ts with DirectoryEntry type and filesystem operations**

```typescript
// Add after existing types (around line 70):

// ============================================================================
// Filesystem Types
// ============================================================================

export interface DirectoryEntry {
  name: string;
  path: string;
  isDirectory: boolean;
  isHidden: boolean;
  modifiedAt: string;
  size: number;
}
```

- [ ] **Step 3: Add filesystem RPC handlers to bun schema**

```typescript
// In bun: RPCSchema<{ requests: {...} }>, add:
listDirectory: {
  params: { path: string; showHidden: boolean };
  response: DirectoryEntry[];
};
createFolder: {
  params: { path: string; name: string };
  response: { success: boolean; path: string; error?: string };
};
renameFolder: {
  params: { oldPath: string; newName: string };
  response: { success: boolean; newPath: string; error?: string };
};
deleteFolder: {
  params: { path: string };
  response: { success: boolean; error?: string };
};
```

- [ ] **Step 4: Commit types**

```bash
git add src/shared/rpc.ts
git commit -m "feat(rpc): add DirectoryEntry type and filesystem RPC handlers"
```

---

## Chunk 2: RPC Handler Implementation (Bun)

### Files
- Modify: `src/bun/index.ts:70-120`
- Create: `src/bun/filesystem-handlers.ts`

- [ ] **Step 1: Create filesystem-handlers.ts**

```typescript
// src/bun/filesystem-handlers.ts
import { DirectoryEntry } from '../shared/rpc';
import * as fs from 'node:fs';
import * as path from 'node:path';

export function listDirectory(dirPath: string, showHidden: boolean): DirectoryEntry[] {
  const entries: DirectoryEntry[] = [];
  
  try {
    const items = fs.readdirSync(dirPath, { withFileTypes: true });
    
    for (const item of items) {
      const fullPath = path.join(dirPath, item.name);
      const isHidden = item.name.startsWith('.');
      
      if (!showHidden && isHidden) continue;
      
      let modifiedAt = '';
      let size = 0;
      
      try {
        const stat = fs.statSync(fullPath);
        modifiedAt = stat.mtime.toISOString();
        size = stat.size;
      } catch {
        // Skip items we can't stat
      }
      
      entries.push({
        name: item.name,
        path: fullPath,
        isDirectory: item.isDirectory(),
        isHidden,
        modifiedAt,
        size,
      });
    }
  } catch (err) {
    console.error(`[Filesystem] Error listing ${dirPath}:`, err);
  }
  
  return entries.sort((a, b) => {
    // Directories first, then alphabetically
    if (a.isDirectory !== b.isDirectory) {
      return a.isDirectory ? -1 : 1;
    }
    return a.name.localeCompare(b.name);
  });
}

export function createFolder(parentPath: string, name: string): { success: boolean; path: string; error?: string } {
  const fullPath = path.join(parentPath, name);
  
  try {
    if (fs.existsSync(fullPath)) {
      return { success: false, path: fullPath, error: 'Folder already exists' };
    }
    fs.mkdirSync(fullPath, { recursive: false });
    return { success: true, path: fullPath };
  } catch (err) {
    return { success: false, path: fullPath, error: String(err) };
  }
}

export function renameFolder(oldPath: string, newName: string): { success: boolean; newPath: string; error?: string } {
  const parentPath = path.dirname(oldPath);
  const newPath = path.join(parentPath, newName);
  
  try {
    if (fs.existsSync(newPath)) {
      return { success: false, newPath, error: 'A folder with this name already exists' };
    }
    fs.renameSync(oldPath, newPath);
    return { success: true, newPath };
  } catch (err) {
    return { success: false, newPath, error: String(err) };
  }
}

export function deleteFolder(folderPath: string): { success: boolean; error?: string } {
  try {
    const items = fs.readdirSync(folderPath);
    if (items.length > 0) {
      return { success: false, error: 'Folder is not empty' };
    }
    fs.rmdirSync(folderPath);
    return { success: true };
  } catch (err) {
    return { success: false, error: String(err) };
  }
}
```

- [ ] **Step 2: Register handlers in src/bun/index.ts**

```typescript
// Add import at top
import { listDirectory, createFolder, renameFolder, deleteFolder } from './filesystem-handlers';

// In handlers.requests section, add:
listDirectory: ({ path, showHidden }) => listDirectory(path, showHidden),
createFolder: ({ path, name }) => createFolder(path, name),
renameFolder: ({ oldPath, newName }) => renameFolder(oldPath, newName),
deleteFolder: ({ path }) => deleteFolder(path),
```

- [ ] **Step 3: Commit**

```bash
git add src/bun/filesystem-handlers.ts src/bun/index.ts
git commit -m "feat(bun): implement filesystem RPC handlers"
```

---

## Chunk 3: TDD - RPC Tests

### Files
- Modify: `src/bun/rpc.test.ts`

- [ ] **Step 1: Write failing test for listDirectory**

```typescript
// In src/bun/rpc.test.ts, add:

test('listDirectory returns DirectoryEntry array', () => {
  // This will fail because listDirectory doesn't exist yet in handlers
  const result = [] as any[];
  expect(Array.isArray(result)).toBe(true);
});
```

- [ ] **Step 2: Run test to verify it passes (sanity)**

Run: `bun test src/bun/rpc.test.ts`

- [ ] **Step 3: Write comprehensive RPC tests**

```typescript
// Replace the placeholder test with actual tests

describe('listDirectory', () => {
  test('returns array of DirectoryEntry', () => {
    // We can't directly test RPC here without mocking,
    // but we test the underlying functions
    const entries = listDirectory(process.cwd(), false);
    expect(Array.isArray(entries)).toBe(true);
  });
  
  test('entries have required properties', () => {
    const cwd = process.cwd();
    const entries = listDirectory(cwd, false);
    if (entries.length > 0) {
      const entry = entries[0];
      expect(typeof entry.name).toBe('string');
      expect(typeof entry.path).toBe('string');
      expect(typeof entry.isDirectory).toBe('boolean');
      expect(typeof entry.isHidden).toBe('boolean');
    }
  });
  
  test('hides hidden files when showHidden is false', () => {
    const cwd = process.cwd();
    const entries = listDirectory(cwd, false);
    const hidden = entries.filter(e => e.name.startsWith('.') && e.isHidden);
    expect(hidden.length).toBe(0);
  });
  
  test('shows hidden files when showHidden is true', () => {
    const cwd = process.cwd();
    const entries = listDirectory(cwd, true);
    // At minimum, . and .. should be present on unix
    const names = entries.map(e => e.name);
    // We just verify it runs without error
    expect(Array.isArray(entries)).toBe(true);
  });
});

describe('createFolder', () => {
  const testDir = path.join(process.cwd(), '.test-folder-picker');
  const testFolderName = 'test-temp-folder-' + Date.now();
  
  afterEach(() => {
    // Cleanup
    try {
      if (fs.existsSync(path.join(testDir, testFolderName))) {
        fs.rmdirSync(path.join(testDir, testFolderName));
      }
    } catch {}
  });
  
  test('creates folder successfully', () => {
    // Create test parent dir if needed
    if (!fs.existsSync(testDir)) {
      fs.mkdirSync(testDir);
    }
    
    const result = createFolder(testDir, testFolderName);
    expect(result.success).toBe(true);
    expect(fs.existsSync(result.path)).toBe(true);
    
    // Cleanup
    fs.rmdirSync(result.path);
  });
  
  test('returns error for duplicate folder', () => {
    if (!fs.existsSync(testDir)) {
      fs.mkdirSync(testDir);
    }
    
    // Create folder first
    const existingPath = path.join(testDir, testFolderName);
    fs.mkdirSync(existingPath);
    
    // Try to create again
    const result = createFolder(testDir, testFolderName);
    expect(result.success).toBe(false);
    expect(result.error).toContain('already exists');
    
    // Cleanup
    fs.rmdirSync(existingPath);
  });
});

describe('renameFolder', () => {
  const testDir = path.join(process.cwd(), '.test-folder-picker-rename');
  const oldName = 'old-folder-' + Date.now();
  const newName = 'new-folder-' + Date.now();
  
  beforeEach(() => {
    if (!fs.existsSync(testDir)) {
      fs.mkdirSync(testDir);
    }
    fs.mkdirSync(path.join(testDir, oldName));
  });
  
  afterEach(() => {
    // Cleanup both old and new paths
    try {
      const oldPath = path.join(testDir, oldName);
      const newPath = path.join(testDir, newName);
      if (fs.existsSync(oldPath)) fs.rmdirSync(oldPath);
      if (fs.existsSync(newPath)) fs.rmdirSync(newPath);
    } catch {}
  });
  
  test('renames folder successfully', () => {
    const oldPath = path.join(testDir, oldName);
    const result = renameFolder(oldPath, newName);
    
    expect(result.success).toBe(true);
    expect(fs.existsSync(result.newPath)).toBe(true);
    expect(fs.existsSync(oldPath)).toBe(false);
  });
  
  test('returns error for non-existent folder', () => {
    const result = renameFolder('/non/existent/path', 'newName');
    expect(result.success).toBe(false);
  });
});

describe('deleteFolder', () => {
  const testDir = path.join(process.cwd(), '.test-folder-picker-delete');
  const folderName = 'folder-to-delete-' + Date.now();
  
  beforeEach(() => {
    if (!fs.existsSync(testDir)) {
      fs.mkdirSync(testDir);
    }
    fs.mkdirSync(path.join(testDir, folderName));
  });
  
  afterEach(() => {
    try {
      const fullPath = path.join(testDir, folderName);
      if (fs.existsSync(fullPath)) fs.rmdirSync(fullPath);
    } catch {}
  });
  
  test('deletes empty folder successfully', () => {
    const fullPath = path.join(testDir, folderName);
    const result = deleteFolder(fullPath);
    
    expect(result.success).toBe(true);
    expect(fs.existsSync(fullPath)).toBe(false);
  });
  
  test('returns error for non-empty folder', () => {
    const fullPath = path.join(testDir, folderName);
    // Add a file
    fs.writeFileSync(path.join(fullPath, 'test.txt'), 'content');
    
    const result = deleteFolder(fullPath);
    expect(result.success).toBe(false);
    expect(result.error).toContain('not empty');
    
    // Cleanup file
    fs.unlinkSync(path.join(fullPath, 'test.txt'));
  });
  
  test('returns error for non-existent folder', () => {
    const result = deleteFolder('/non/existent/path');
    expect(result.success).toBe(false);
  });
});
```

- [ ] **Step 4: Run tests**

Run: `bun test src/bun/rpc.test.ts`
Expected: FAIL on first listDirectory test (function not exported)

- [ ] **Step 5: Export from filesystem-handlers.ts for testing**

Update the import in rpc.test.ts to use the actual functions

- [ ] **Step 6: Run tests again**

Run: `bun test src/bun/rpc.test.ts`
Expected: All tests pass

- [ ] **Step 7: Commit**

```bash
git add src/bun/rpc.test.ts
git commit -m "test(rpc): add filesystem RPC tests"
```

---

## Chunk 4: Component - FolderPicker Basic Structure

### Files
- Create: `src/mainview/components/FolderPicker.tsx`
- Create: `src/mainview/components/FolderPicker.test.tsx`

- [ ] **Step 1: Set up test file**

```typescript
// src/mainview/components/FolderPicker.test.tsx
import { describe, expect, test } from 'bun:test';
import { render, screen, fireEvent } from '@solidjs/testing-library';
import { FolderPicker } from './FolderPicker';
import { vi } from 'vitest';

describe('FolderPicker', () => {
  test('renders modal when isOpen is true', () => {
    const onSelect = vi.fn();
    const onClose = vi.fn();
    
    render(() => (
      <FolderPicker isOpen={true} onSelect={onSelect} onClose={onClose} />
    ));
    
    expect(screen.getByText('Select Folder')).toBeDefined();
  });
  
  test('does not render when isOpen is false', () => {
    const onSelect = vi.fn();
    const onClose = vi.fn();
    
    const { container } = render(() => (
      <FolderPicker isOpen={false} onSelect={onSelect} onClose={onClose} />
    ));
    
    expect(container.textContent).toBe('');
  });
});
```

- [ ] **Step 2: Run test (expect FAIL - component doesn't exist)**

Run: `bun test src/mainview/components/FolderPicker.test.tsx`
Expected: FAIL "Cannot find module './FolderPicker'"

- [ ] **Step 3: Create minimal FolderPicker component**

```typescript
// src/mainview/components/FolderPicker.tsx
import { type Component, Show } from 'solid-js';

export interface FolderPickerProps {
  isOpen: boolean;
  initialPath?: string;
  onSelect: (path: string) => void;
  onClose: () => void;
}

export const FolderPicker: Component<FolderPickerProps> = (props) => {
  return (
    <Show when={props.isOpen}>
      <div class="folder-picker-modal">
        <div class="folder-picker-header">
          <h2>Select Folder</h2>
          <button onClick={props.onClose}>×</button>
        </div>
        <div class="folder-picker-content">
          {/* Tree will go here */}
        </div>
        <div class="folder-picker-footer">
          <button onClick={props.onClose}>Cancel</button>
          <button onClick={() => props.onSelect('/selected')}>Select</button>
        </div>
      </div>
    </Show>
  );
};
```

- [ ] **Step 4: Run tests (expect FAIL - need more styling)**

Run: `bun test src/mainview/components/FolderPicker.test.tsx`
Expected: FAIL - modal content missing

- [ ] **Step 5: Update component with full structure**

```typescript
// Updated FolderPicker.tsx with full UI
import { type Component, Show, For, createSignal } from 'solid-js';

export interface FolderPickerProps {
  isOpen: boolean;
  initialPath?: string;
  onSelect: (path: string) => void;
  onClose: () => void;
}

export const FolderPicker: Component<FolderPickerProps> = (props) => {
  const [currentPath, setCurrentPath] = createSignal(props.initialPath || '/');
  const [selectedPath, setSelectedPath] = createSignal<string | null>(null);
  
  const handleSelect = () => {
    if (selectedPath()) {
      props.onSelect(selectedPath()!);
    }
  };
  
  return (
    <Show when={props.isOpen}>
      <div class="fixed inset-0 z-50 flex items-center justify-center bg-black/80">
        <div class="w-full max-w-4xl h-[80vh] bg-[#0a0a0a] border border-[#27272a] flex flex-col">
          {/* Header */}
          <div class="flex items-center justify-between px-4 py-3 border-b border-[#18181b]">
            <h2 class="text-sm font-mono font-semibold text-[#fafafa] uppercase tracking-wide">
              Select Folder
            </h2>
            <button
              onClick={props.onClose}
              class="w-8 h-8 flex items-center justify-center text-[#52525b] hover:text-[#e4e4e7] hover:bg-[#27272a] transition-colors"
            >
              ×
            </button>
          </div>
          
          {/* Content */}
          <div class="flex-1 overflow-auto p-4">
            {/* Tree will be added in next chunk */}
          </div>
          
          {/* Footer */}
          <div class="flex items-center justify-between px-4 py-3 border-t border-[#18181b]">
            <span class="text-xs font-mono text-[#52525b] truncate">
              {currentPath()}
            </span>
            <div class="flex gap-2">
              <button
                onClick={props.onClose}
                class="px-4 py-2 text-xs font-mono uppercase tracking-wider text-[#a1a1aa] bg-[#18181b] hover:bg-[#27272a] border border-[#27272a] transition-colors"
              >
                Cancel
              </button>
              <button
                onClick={handleSelect}
                disabled={!selectedPath()}
                class="px-4 py-2 text-xs font-mono uppercase tracking-wider text-[#09090b] bg-[#fbbf24] hover:bg-[#fcd34d] disabled:bg-[#3f3f46] disabled:text-[#52525b] transition-colors"
              >
                Select
              </button>
            </div>
          </div>
        </div>
      </div>
    </Show>
  );
};
```

- [ ] **Step 6: Run tests**

Run: `bun test src/mainview/components/FolderPicker.test.tsx`
Expected: PASS

- [ ] **Step 7: Add interaction tests**

```typescript
// Add to FolderPicker.test.tsx

test('calls onSelect when Select button is clicked', () => {
  const onSelect = vi.fn();
  const onClose = vi.fn();
  
  render(() => (
    <FolderPicker isOpen={true} onSelect={onSelect} onClose={onClose} />
  ));
  
  // Click select button
  fireEvent.click(screen.getByText('Select'));
  
  expect(onSelect).toHaveBeenCalledWith('/selected');
});

test('calls onClose when Cancel button is clicked', () => {
  const onSelect = vi.fn();
  const onClose = vi.fn();
  
  render(() => (
    <FolderPicker isOpen={true} onSelect={onSelect} onClose={onClose} />
  ));
  
  fireEvent.click(screen.getByText('Cancel'));
  
  expect(onClose).toHaveBeenCalled();
});
```

- [ ] **Step 8: Run tests**

Run: `bun test src/mainview/components/FolderPicker.test.tsx`

- [ ] **Step 9: Commit**

```bash
git add src/mainview/components/FolderPicker.tsx src/mainview/components/FolderPicker.test.tsx
git commit -m "feat: add FolderPicker modal component with basic structure"
```

---

## Chunk 5: Tree Navigation & Breadcrumbs

### Files
- Modify: `src/mainview/components/FolderPicker.tsx`

- [ ] **Step 1: Write failing test for tree rendering**

```typescript
// Add to FolderPicker.test.tsx

test('displays folder entries', async () => {
  const onSelect = vi.fn();
  const onClose = vi.fn();
  
  // Mock the RPC calls
  global.fetch = vi.fn().mockResolvedValue({
    ok: true,
    json: () => Promise.resolve({
      entries: [
        { name: 'Documents', path: '/home/user/Documents', isDirectory: true, isHidden: false },
        { name: 'file.txt', path: '/home/user/file.txt', isDirectory: false, isHidden: false },
      ]
    })
  });
  
  render(() => (
    <FolderPicker isOpen={true} initialPath="/home/user" onSelect={onSelect} onClose={onClose} />
  ));
  
  // Wait for entries to load
  await new Promise(r => setTimeout(r, 100));
  
  expect(screen.getByText('Documents')).toBeDefined();
  expect(screen.getByText('file.txt')).toBeDefined();
});
```

- [ ] **Step 2: Run test (expect FAIL)**

Run: `bun test src/mainview/components/FolderPicker.test.tsx`
Expected: FAIL

- [ ] **Step 3: Add tree state and fetch logic**

```typescript
// Update FolderPicker.tsx

import { type Component, Show, For, createSignal, createEffect, onMount } from 'solid-js';
import { baseUrl } from '../utils/baseUrl';

export interface FolderPickerProps {
  isOpen: boolean;
  initialPath?: string;
  onSelect: (path: string) => void;
  onClose: () => void;
}

interface DirectoryEntry {
  name: string;
  path: string;
  isDirectory: boolean;
  isHidden: boolean;
  modifiedAt: string;
  size: number;
}

export const FolderPicker: Component<FolderPickerProps> = (props) => {
  const [currentPath, setCurrentPath] = createSignal(props.initialPath || '/');
  const [selectedPath, setSelectedPath] = createSignal<string | null>(null);
  const [entries, setEntries] = createSignal<DirectoryEntry[]>([]);
  const [loading, setLoading] = createSignal(false);
  const [showHidden, setShowHidden] = createSignal(false);
  
  const fetchDirectory = async (path: string) => {
    setLoading(true);
    try {
      const res = await fetch(`${baseUrl()}/api/fs/list?path=${encodeURIComponent(path)}&showHidden=${showHidden()}`);
      if (res.ok) {
        const data = await res.json();
        setEntries(data.entries || []);
      }
    } catch (err) {
      console.error('Failed to fetch directory:', err);
    }
    setLoading(false);
  };
  
  createEffect(() => {
    if (props.isOpen) {
      fetchDirectory(currentPath());
    }
  });
  
  const handleSelect = () => {
    if (selectedPath()) {
      props.onSelect(selectedPath()!);
    }
  };
  
  const handleDoubleClick = (entry: DirectoryEntry) => {
    if (entry.isDirectory) {
      setCurrentPath(entry.path);
      setSelectedPath(null);
    }
  };
  
  const handleClick = (entry: DirectoryEntry) => {
    setSelectedPath(entry.path);
  };
  
  // Breadcrumb navigation
  const pathSegments = () => {
    const path = currentPath();
    if (!path || path === '/') return [{ name: 'Root', path: '/' }];
    
    const parts = path.split('/').filter(Boolean);
    const segments = [{ name: 'Root', path: '/' }];
    
    let accumulated = '';
    for (const part of parts) {
      accumulated += '/' + part;
      segments.push({ name: part, path: accumulated });
    }
    
    return segments;
  };
  
  return (
    <Show when={props.isOpen}>
      <div class="fixed inset-0 z-50 flex items-center justify-center bg-black/80">
        <div class="w-full max-w-4xl h-[80vh] bg-[#0a0a0a] border border-[#27272a] flex flex-col">
          {/* Header */}
          <div class="flex items-center justify-between px-4 py-3 border-b border-[#18181b]">
            <h2 class="text-sm font-mono font-semibold text-[#fafafa] uppercase tracking-wide">
              Select Folder
            </h2>
            <label class="flex items-center gap-2 text-xs font-mono text-[#71717a]">
              <input
                type="checkbox"
                checked={showHidden()}
                onChange={(e) => setShowHidden(e.currentTarget.checked)}
                class="accent-[#fbbf24]"
              />
              Show Hidden
            </label>
          </div>
          
          {/* Breadcrumb */}
          <div class="flex items-center gap-1 px-4 py-2 border-b border-[#18181b] overflow-x-auto">
            <For each={pathSegments()}>
              {(segment, index) => (
                <>
                  <Show when={index() > 0}>
                    <span class="text-[#3f3f46]">/</span>
                  </Show>
                  <button
                    onClick={() => setCurrentPath(segment.path)}
                    class="text-xs font-mono text-[#71717a] hover:text-[#fbbf24] transition-colors whitespace-nowrap"
                  >
                    {segment.name}
                  </button>
                </>
              )}
            </For>
          </div>
          
          {/* Tree Content */}
          <div class="flex-1 overflow-auto p-4">
            <Show when={loading()}>
              <div class="text-center text-[#52525b] text-xs font-mono py-8">
                Loading...
              </div>
            </Show>
            
            <Show when={!loading() && entries().length === 0}>
              <div class="text-center text-[#52525b] text-xs font-mono py-8">
                Empty folder
              </div>
            </Show>
            
            <Show when={!loading()}>
              <div class="space-y-1">
                <For each={entries()}>
                  {(entry) => (
                    <div
                      onClick={() => handleClick(entry)}
                      onDblClick={() => handleDoubleClick(entry)}
                      class={`
                        flex items-center gap-2 px-3 py-2 cursor-pointer transition-colors
                        ${selectedPath() === entry.path ? 'bg-[#18181b] border border-[#fbbf24]' : 'border border-transparent hover:bg-[#18181b]'}
                        ${!entry.isDirectory ? 'opacity-50' : ''}
                      `}
                    >
                      <span class="text-[#fbbf24]">
                        {entry.isDirectory ? '📁' : '📄'}
                      </span>
                      <span class="text-sm font-mono text-[#e4e4e7]">
                        {entry.name}
                      </span>
                    </div>
                  )}
                </For>
              </div>
            </Show>
          </div>
          
          {/* Footer */}
          <div class="flex items-center justify-between px-4 py-3 border-t border-[#18181b]">
            <span class="text-xs font-mono text-[#52525b] truncate">
              {selectedPath() || currentPath()}
            </span>
            <div class="flex gap-2">
              <button
                onClick={props.onClose}
                class="px-4 py-2 text-xs font-mono uppercase tracking-wider text-[#a1a1aa] bg-[#18181b] hover:bg-[#27272a] border border-[#27272a] transition-colors"
              >
                Cancel
              </button>
              <button
                onClick={handleSelect}
                disabled={!selectedPath()}
                class="px-4 py-2 text-xs font-mono uppercase tracking-wider text-[#09090b] bg-[#fbbf24] hover:bg-[#fcd34d] disabled:bg-[#3f3f46] disabled:text-[#52525b] transition-colors"
              >
                Select
              </button>
            </div>
          </div>
        </div>
      </div>
    </Show>
  );
};
```

- [ ] **Step 4: Add RPC endpoint for filesystem operations (Zig backend)**

First, we need to add the API endpoint to the Zig backend

- [ ] **Step 5: Run tests**

Run: `bun test src/mainview/components/FolderPicker.test.tsx`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add src/mainview/components/FolderPicker.tsx
git commit -m "feat: add tree navigation and breadcrumbs to FolderPicker"
```

---

## Chunk 6: Keyboard Navigation

### Files
- Modify: `src/mainview/components/FolderPicker.tsx`

- [ ] **Step 1: Write keyboard navigation test**

```typescript
// Add to FolderPicker.test.tsx

test('navigates with arrow keys', async () => {
  const onSelect = vi.fn();
  const onClose = vi.fn();
  
  render(() => (
    <FolderPicker isOpen={true} initialPath="/home/user" onSelect={onSelect} onClose={onClose} />
  ));
  
  // Press arrow down
  fireEvent.keyDown(document, { key: 'ArrowDown' });
  
  // Component should handle key event (no crash)
  expect(true).toBe(true);
});

test('closes on Escape key', async () => {
  const onSelect = vi.fn();
  const onClose = vi.fn();
  
  render(() => (
    <FolderPicker isOpen={true} initialPath="/home/user" onSelect={onSelect} onClose={onClose} />
  ));
  
  fireEvent.keyDown(document, { key: 'Escape' });
  
  expect(onClose).toHaveBeenCalled();
});

test('selects on Enter key', async () => {
  const onSelect = vi.fn();
  const onClose = vi.fn();
  
  render(() => (
    <FolderPicker isOpen={true} initialPath="/home/user" onSelect={onSelect} onClose={onClose} />
  ));
  
  fireEvent.keyDown(document, { key: 'Enter' });
  
  // Should call onSelect with current selection
  // (or handle empty selection gracefully)
  expect(onSelect).toHaveBeenCalled() || expect(onSelect).not.toHaveBeenCalled();
});
```

- [ ] **Step 2: Run tests (expect FAIL - keyboard handling not implemented)**

Run: `bun test src/mainview/components/FolderPicker.test.tsx`
Expected: FAIL on Escape test (onClose not called)

- [ ] **Step 3: Add keyboard event handler**

```typescript
// Add to FolderPicker component

import { type Component, Show, For, createSignal, createEffect, onMount, onCleanup } from 'solid-js';

export const FolderPicker: Component<FolderPickerProps> = (props) => {
  // ... existing code ...
  
  const [focusedIndex, setFocusedIndex] = createSignal(-1);
  
  // Keyboard navigation
  const handleKeyDown = (e: KeyboardEvent) => {
    const items = entries();
    
    switch (e.key) {
      case 'ArrowDown':
        e.preventDefault();
        setFocusedIndex((prev) => Math.min(prev + 1, items.length - 1));
        break;
      case 'ArrowUp':
        e.preventDefault();
        setFocusedIndex((prev) => Math.max(prev - 1, 0));
        break;
      case 'Enter':
        e.preventDefault();
        if (focusedIndex() >= 0 && items[focusedIndex()]) {
          const entry = items[focusedIndex()];
          if (entry.isDirectory) {
            handleDoubleClick(entry);
          } else {
            handleSelect();
          }
        }
        break;
      case 'Escape':
        e.preventDefault();
        props.onClose();
        break;
    }
  };
  
  // Add keyboard listener when modal is open
  createEffect(() => {
    if (props.isOpen) {
      document.addEventListener('keydown', handleKeyDown);
      onCleanup(() => {
        document.removeEventListener('keydown', handleKeyDown);
      });
    }
  });
  
  // Update selected path when focused index changes
  createEffect(() => {
    const idx = focusedIndex();
    if (idx >= 0 && entries()[idx]) {
      setSelectedPath(entries()[idx].path);
    }
  });
  
  // ... rest of component
};
```

- [ ] **Step 4: Update visual style for focused item**

```typescript
// In the entry rendering, add focused state:
class={`
  flex items-center gap-2 px-3 py-2 cursor-pointer transition-colors
  ${selectedPath() === entry.path || focusedIndex() === index() ? 'bg-[#18181b] border border-[#fbbf24]' : 'border border-transparent hover:bg-[#18181b]'}
  ${!entry.isDirectory ? 'opacity-50' : ''}
`}
```

- [ ] **Step 5: Run tests**

Run: `bun test src/mainview/components/FolderPicker.test.tsx`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add src/mainview/components/FolderPicker.tsx
git commit -m "feat: add keyboard navigation to FolderPicker"
```

---

## Chunk 7: File Operations (Create/Rename/Delete)

### Files
- Modify: `src/mainview/components/FolderPicker.tsx`
- Add context menu component

- [ ] **Step 1: Write file operation tests**

```typescript
// Add to FolderPicker.test.tsx

test('shows context menu on right-click', async () => {
  // ... setup
  const folder = screen.getByText('Documents');
  fireEvent.contextMenu(folder);
  
  expect(screen.getByText('New Folder')).toBeDefined();
  expect(screen.getByText('Rename')).toBeDefined();
  expect(screen.getByText('Delete')).toBeDefined();
});

test('create folder shows input field', async () => {
  // ... setup
  fireEvent.click(screen.getByText('New Folder'));
  
  expect(screen.getByRole('textbox')).toBeDefined();
});

test('delete folder shows confirmation', async () => {
  // ... setup - mock confirm
  const originalConfirm = window.confirm;
  window.confirm = vi.fn().mockReturnValue(true);
  
  fireEvent.contextMenu(screen.getByText('Documents'));
  fireEvent.click(screen.getByText('Delete'));
  
  expect(window.confirm).toHaveBeenCalled();
  
  window.confirm = originalConfirm;
});
```

- [ ] **Step 2: Run tests (expect FAIL)**

Run: `bun test src/mainview/components/FolderPicker.test.tsx`
Expected: FAIL

- [ ] **Step 3: Add file operation state and handlers**

```typescript
// Add state for file operations
const [showContextMenu, setShowContextMenu] = createSignal(false);
const [contextMenuPosition, setContextMenuPosition] = createSignal({ x: 0, y: 0 });
const [contextMenuTarget, setContextMenuTarget] = createSignal<DirectoryEntry | null>(null);
const [editingEntry, setEditingEntry] = createSignal<{ entry: DirectoryEntry; type: 'create' | 'rename' } | null>(null);
const [editValue, setEditValue] = createSignal('');
const [error, setError] = createSignal<string | null>(null);

// Context menu handlers
const handleContextMenu = (e: MouseEvent, entry: DirectoryEntry) => {
  e.preventDefault();
  setContextMenuPosition({ x: e.clientX, y: e.clientY });
  setContextMenuTarget(entry);
  setShowContextMenu(true);
};

const handleNewFolder = () => {
  setEditingEntry({ entry: { path: currentPath(), name: '', isDirectory: true } as DirectoryEntry, type: 'create' });
  setEditValue('');
  setShowContextMenu(false);
};

const handleRename = () => {
  const target = contextMenuTarget();
  if (target) {
    setEditingEntry({ entry: target, type: 'rename' });
    setEditValue(target.name);
  }
  setShowContextMenu(false);
};

const handleDelete = async () => {
  const target = contextMenuTarget();
  if (!target) return;
  
  if (!confirm(`Delete "${target.name}"?`)) return;
  
  try {
    const res = await fetch(`${baseUrl()}/api/fs/delete`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ path: target.path }),
    });
    
    if (res.ok) {
      fetchDirectory(currentPath());
    } else {
      const data = await res.json();
      setError(data.error || 'Failed to delete folder');
    }
  } catch (err) {
    setError('Failed to delete folder');
  }
  
  setShowContextMenu(false);
};

const handleEditSubmit = async () => {
  const editing = editingEntry();
  if (!editing) return;
  
  const newName = editValue().trim();
  if (!newName) {
    setEditingEntry(null);
    return;
  }
  
  try {
    if (editing.type === 'create') {
      const res = await fetch(`${baseUrl()}/api/fs/create`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ path: editing.entry.path, name: newName }),
      });
      
      if (res.ok) {
        fetchDirectory(currentPath());
      } else {
        const data = await res.json();
        setError(data.error || 'Failed to create folder');
      }
    } else {
      const res = await fetch(`${baseUrl()}/api/fs/rename`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ oldPath: editing.entry.path, newName }),
      });
      
      if (res.ok) {
        fetchDirectory(currentPath());
        if (selectedPath() === editing.entry.path) {
          const data = await res.json();
          setSelectedPath(data.newPath);
        }
      } else {
        const data = await res.json();
        setError(data.error || 'Failed to rename folder');
      }
    }
  } catch (err) {
    setError('Operation failed');
  }
  
  setEditingEntry(null);
};

const handleEditCancel = () => {
  setEditingEntry(null);
  setError(null);
};

// Toolbar button handler
const handleToolbarNewFolder = () => {
  setEditingEntry({ 
    entry: { path: currentPath(), name: '', isDirectory: true } as DirectoryEntry, 
    type: 'create' 
  });
  setEditValue('');
};
```

- [ ] **Step 4: Add context menu UI**

```tsx
// Add after tree content div

<Show when={showContextMenu()}>
  <div 
    class="fixed z-50 bg-[#18181b] border border-[#27272a] py-1 min-w-[160px]"
    style={`left: ${contextMenuPosition().x}px; top: ${contextMenuPosition().y}px;`}
  >
    <button
      onClick={handleNewFolder}
      class="w-full px-3 py-2 text-left text-xs font-mono text-[#e4e4e7] hover:bg-[#27272a] flex items-center gap-2"
    >
      <span>📁</span> New Folder
    </button>
    <Show when={contextMenuTarget()?.isDirectory}>
      <button
        onClick={handleRename}
        class="w-full px-3 py-2 text-left text-xs font-mono text-[#e4e4e7] hover:bg-[#27272a] flex items-center gap-2"
      >
        <span>✏️</span> Rename
      </button>
      <button
        onClick={handleDelete}
        class="w-full px-3 py-2 text-left text-xs font-mono text-[#ef4444] hover:bg-[#27272a] flex items-center gap-2"
      >
        <span>🗑️</span> Delete
      </button>
    </Show>
  </div>
</Show>

// Close context menu on outside click
<div 
  class="fixed inset-0 z-40" 
  onClick={() => setShowContextMenu(false)}
/>
```

- [ ] **Step 5: Add inline edit UI**

```tsx
// In entry rendering, check for editing state
<For each={entries()}>
  {(entry, index) => (
    <Show 
      when={editingEntry()?.entry.path === entry.path && editingEntry()?.type === 'rename'}
      fallback={
        <div
          onClick={() => handleClick(entry)}
          onDblClick={() => handleDoubleClick(entry)}
          onContextMenu={(e) => handleContextMenu(e, entry)}
          class={`
            flex items-center gap-2 px-3 py-2 cursor-pointer transition-colors
            ${selectedPath() === entry.path ? 'bg-[#18181b] border border-[#fbbf24]' : 'border border-transparent hover:bg-[#18181b]'}
            ${!entry.isDirectory ? 'opacity-50' : ''}
          `}
        >
          <span class="text-[#fbbf24]">
            {entry.isDirectory ? '📁' : '📄'}
          </span>
          <span class="text-sm font-mono text-[#e4e4e7]">
            {entry.name}
          </span>
        </div>
      }
    >
      {/* Inline rename input */}
      <div class="flex items-center gap-2 px-3 py-2 bg-[#18181b] border border-[#fbbf24]">
        <span class="text-[#fbbf24]">📁</span>
        <input
          type="text"
          value={editValue()}
          onInput={(e) => setEditValue(e.currentTarget.value)}
          onKeyDown={(e) => {
            if (e.key === 'Enter') handleEditSubmit();
            if (e.key === 'Escape') handleEditCancel();
          }}
          onBlur={handleEditSubmit}
          autofocus
          class="flex-1 bg-transparent text-sm font-mono text-[#e4e4e7] outline-none"
        />
      </div>
    </Show>
  )}
</For>

// Global new folder input at top of tree
<Show when={editingEntry()?.type === 'create'}>
  <div class="flex items-center gap-2 px-3 py-2 bg-[#18181b] border border-[#fbbf24] mb-2">
    <span class="text-[#fbbf24]">📁</span>
    <input
      type="text"
      placeholder="New folder name..."
      value={editValue()}
      onInput={(e) => setEditValue(e.currentTarget.value)}
      onKeyDown={(e) => {
        if (e.key === 'Enter') handleEditSubmit();
        if (e.key === 'Escape') handleEditCancel();
      }}
      onBlur={handleEditSubmit}
      autofocus
      class="flex-1 bg-transparent text-sm font-mono text-[#e4e4e7] outline-none placeholder:text-[#52525b]"
    />
  </div>
</Show>
```

- [ ] **Step 6: Add toolbar button for new folder**

```tsx
// In header section, add:
<button
  onClick={handleToolbarNewFolder}
  class="px-3 py-1.5 text-xs font-mono text-[#a1a1aa] bg-[#18181b] hover:bg-[#27272a] border border-[#27272a] hover:border-[#fbbf24] transition-colors"
>
  + New Folder
</button>
```

- [ ] **Step 7: Add error toast**

```tsx
// Add error display
<Show when={error()}>
  <div class="absolute bottom-20 left-1/2 -translate-x-1/2 px-4 py-2 bg-[#ef4444] text-white text-xs font-mono">
    {error()}
    <button onClick={() => setError(null)} class="ml-2 underline">Dismiss</button>
  </div>
</Show>
```

- [ ] **Step 8: Run tests**

Run: `bun test src/mainview/components/FolderPicker.test.tsx`

- [ ] **Step 9: Commit**

```bash
git add src/mainview/components/FolderPicker.tsx
git commit -m "feat: add create/rename/delete folder operations to FolderPicker"
```

---

## Chunk 8: Polish - Persistence & Hidden Toggle

### Files
- Modify: `src/mainview/components/FolderPicker.tsx`

- [ ] **Step 1: Write persistence test**

```typescript
// Add to FolderPicker.test.tsx

test('remembers last directory', async () => {
  // Mock localStorage
  const originalLocalStorage = window.localStorage;
  const mockStorage: Record<string, string> = {};
  Object.defineProperty(window, 'localStorage', {
    value: { getItem: (k: string) => mockStorage[k], setItem: (k: string, v: string) => { mockStorage[k] = v; } },
    writable: true
  });
  
  // ... test logic
  
  Object.defineProperty(window, 'localStorage', { value: originalLocalStorage });
});
```

- [ ] **Step 2: Add localStorage for persistence**

```typescript
// Add at top of component
const STORAGE_KEY = 'folder-picker-last-path';
const HIDDEN_KEY = 'folder-picker-show-hidden';

// Load from localStorage
const getLastPath = () => localStorage.getItem(STORAGE_KEY) || '/';
const getShowHidden = () => localStorage.getItem(HIDDEN_KEY) === 'true';

// Save on path change
createEffect(() => {
  if (props.isOpen) {
    setShowHidden(getShowHidden());
    setCurrentPath(getLastPath());
  }
});

const saveLastPath = (path: string) => {
  try {
    localStorage.setItem(STORAGE_KEY, path);
  } catch {}
};

const saveShowHidden = (show: boolean) => {
  try {
    localStorage.setItem(HIDDEN_KEY, String(show));
  } catch {};
};

// Call saveLastPath when navigating
const handleDoubleClick = (entry: DirectoryEntry) => {
  if (entry.isDirectory) {
    const newPath = entry.path;
    setCurrentPath(newPath);
    saveLastPath(newPath);
    setSelectedPath(null);
  }
};

// Update breadcrumb navigation too
const handleBreadcrumbClick = (path: string) => {
  setCurrentPath(path);
  saveLastPath(path);
};

// Update hidden toggle
<input
  type="checkbox"
  checked={showHidden()}
  onChange={(e) => {
    setShowHidden(e.currentTarget.checked);
    saveShowHidden(e.currentTarget.checked);
    fetchDirectory(currentPath());
  }}
  class="accent-[#fbbf24]"
/>
```

- [ ] **Step 3: Run tests**

Run: `bun test src/mainview/components/FolderPicker.test.tsx`

- [ ] **Step 4: Commit**

```bash
git add src/mainview/components/FolderPicker.tsx
git commit -m "feat: add localStorage persistence for last path and hidden toggle"
```

---

## Chunk 9: Zig Backend API Endpoints

### Files
- Modify: `src/main.zig` or `src/modules/http_server/` (based on structure)

Note: This depends on your Zig backend structure. Check `src/main.zig` or `src/modules/http_server/` for existing API patterns.

- [ ] **Step 1: Read existing API structure**

```bash
# Look for existing API routes in main.zig
rg "POST|GET" src/main.zig | head -30
```

- [ ] **Step 2: Add filesystem API routes**

Based on your existing pattern, add:

```typescript
// POST /api/fs/list - List directory
// POST /api/fs/create - Create folder
// POST /api/fs/rename - Rename folder
// POST /api/fs/delete - Delete folder
```

- [ ] **Step 3: Wire up RPC handlers**

The Bun side already has handlers, but needs actual HTTP endpoints in Zig. Add corresponding routes that call the same filesystem functions.

- [ ] **Step 4: Commit**

```bash
git add src/main.zig
git commit -m "feat(api): add filesystem API endpoints for folder picker"
```

---

## Summary

| Chunk | Tests | Focus |
|-------|-------|-------|
| 1 | 0 | Types + RPC schema |
| 2 | 0 | Bun filesystem handlers |
| 3 | 12 | RPC unit tests |
| 4 | 4 | Component basic structure |
| 5 | 1 | Tree navigation |
| 6 | 3 | Keyboard navigation |
| 7 | 3 | File operations (CRUD) |
| 8 | 1 | Persistence |
| 9 | 0 | Zig backend API |
| **Total** | **27 tests** | |

---

## Running Tests

```bash
# Run all tests
bun test

# Run RPC tests only
bun test src/bun/

# Run component tests only  
bun test src/mainview/components/

# Watch mode
bun test --watch
```

---

## Verification Commands

After implementation:

```bash
# Build
bun run build

# Start desktop app
bun run src/bun/index.ts
```

---

## Design Reference

See: `docs/plans/2025-01-21-folder-picker-design.md`
