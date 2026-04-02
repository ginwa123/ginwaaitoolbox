# Folder Picker Component Design

**Date:** 2025-01-21  
**Component:** `FolderPicker.tsx`  
**Location:** `src/apps/desktop-bun/src/mainview/components/FolderPicker.tsx`  
**Status:** Draft

---

## Overview

A full-screen modal dialog for browsing, selecting, and managing filesystem folders. Provides read-write access to create, rename, and delete folders within the filesystem.

---

## 1. Architecture

### Component Structure

```
FolderPicker (Modal Container)
├── Header
│   ├── Title: "Select Folder"
│   ├── Show Hidden Toggle
│   ├── New Folder Button
│   └── Close Button (X)
├── Breadcrumb Navigation
│   └── Path segments (clickable)
├── File Tree
│   ├── Folder entries (clickable, expandable)
│   ├── File entries (display only, dimmed)
│   └── Empty state
├── Footer
│   ├── Current path display
│   ├── Cancel Button
│   └── Select Button (enabled when folder selected)
└── Context Menu (right-click)
    ├── New Folder
    ├── Rename
    └── Delete
```

### File Structure

| File | Purpose |
|------|---------|
| `components/FolderPicker.tsx` | Main modal component |
| `utils/fileSystem.ts` | Bun RPC wrapper for filesystem operations |

### RPC Schema Extension

Add to `src/shared/rpc.ts`:

```typescript
bun: RPCSchema<{
  requests: {
    // ... existing
    listDirectory: {
      params: { path: string; showHidden: boolean };
      response: DirectoryEntry[];
    };
    createFolder: {
      params: { path: string; name: string };
      response: { success: boolean; path: string };
    };
    renameFolder: {
      params: { oldPath: string; newName: string };
      response: { success: boolean; newPath: string };
    };
    deleteFolder: {
      params: { path: string };
      response: { success: boolean };
    };
    // ... existing
  };
}>;
```

---

## 2. Data Structures

### DirectoryEntry

```typescript
interface DirectoryEntry {
  name: string;
  path: string;
  isDirectory: boolean;
  isHidden: boolean;
  modifiedAt: string;
  size: number;
}
```

### FolderPickerProps

```typescript
interface FolderPickerProps {
  isOpen: boolean;
  initialPath?: string;
  onSelect: (path: string) => void;
  onClose: () => void;
}
```

---

## 3. Interactions

### Navigation

| Action | Behavior |
|--------|----------|
| Single-click folder | Expand/collapse folder in tree |
| Single-click folder name | Select folder (highlight) |
| Double-click folder | Navigate into folder |
| Double-click folder (leaf) | Select and confirm |
| Click breadcrumb segment | Navigate to that path |
| Press `↑`/`↓` | Navigate tree items |
| Press `Enter` | Confirm selected folder |
| Press `Escape` | Cancel and close |

### File Operations

| Action | Trigger | Behavior |
|--------|---------|----------|
| Create folder | Right-click > New Folder, or toolbar button | Inline input field appears, Enter to confirm, Escape to cancel |
| Rename folder | Right-click > Rename | Inline input field replaces name, Enter to confirm, Escape to cancel |
| Delete folder | Right-click > Delete | Confirmation dialog before deletion |

### Hidden Files

- Toggle in header: "Show Hidden"
- Default: OFF
- State persisted to localStorage

### Last Directory

- Remember last opened directory in localStorage
- Restore on next open

---

## 4. Visual Design

### Aesthetic

Follows existing app theme:
- Background: `#050505`
- Borders: `#18181b`
- Text: `#e4e4e7`
- Accent: `#fbbf24` (gold)
- Font: JetBrains Mono for paths/names, IBM Plex Sans for UI text

### Component States

| Element | Default | Hover | Active | Selected | Disabled |
|---------|---------|-------|--------|----------|----------|
| Folder row | `#09090b` | `#18181b` | `#27272a` | `#fbbf24` border | `#27272a` opacity 50% |
| Select button | `#fbbf24` bg | `#fcd34d` bg | `#f59e0b` bg | — | `#3f3f46` bg |

### Animations

- Modal: fade-in 150ms + scale from 95% to 100%
- Tree expand/collapse: height transition 100ms
- Context menu: fade-in 100ms
- Error shake: 200ms horizontal shake

---

## 5. Error Handling

| Scenario | Behavior |
|----------|----------|
| Permission denied | Show error toast, disable operation |
| Folder not empty (delete) | Show confirmation with warning |
| Invalid name (create/rename) | Show inline error, shake input |
| Path not found | Navigate to parent, show error toast |
| Network/disk error | Show error toast with retry option |

### Error Messages

| Error | Message |
|-------|---------|
| Permission denied | "Permission denied: Cannot access this folder" |
| Folder not empty | "This folder is not empty. Delete all contents first." |
| Invalid characters | "Folder name cannot contain: / \ : * ? " < > |" |
| Name too long | "Folder name must be under 255 characters" |
| Already exists | "A folder with this name already exists" |

---

## 6. Accessibility

- Full keyboard navigation
- ARIA labels on all interactive elements
- Focus trap within modal
- Screen reader announcements for state changes
- High contrast focus indicators

---

## 7. TDD Implementation Plan

### TDD Workflow
1. **RED**: Write failing test
2. **GREEN**: Write minimal code to pass
3. **REFACTOR**: Clean up code (optional)

### Phase 1: RPC Layer (TDD)

#### Test 1: `rpc.test.ts` — listDirectory
```typescript
// Arrange: Mock filesystem with test data
// Act: Call listDirectory with a path
// Assert: Returns correct DirectoryEntry[]
```

#### Test 2: `rpc.test.ts` — createFolder
```typescript
// Arrange: Valid path
// Act: Call createFolder
// Assert: Folder created, returns success + new path
```

#### Test 3: `rpc.test.ts` — renameFolder
```typescript
// Arrange: Existing folder
// Act: Call renameFolder with new name
// Assert: Folder renamed, returns new path
```

#### Test 4: `rpc.test.ts` — deleteFolder
```typescript
// Arrange: Empty folder
// Act: Call deleteFolder
// Assert: Folder deleted, returns success
```

### Phase 2: Component Structure (TDD)

#### Test 5: `FolderPicker.test.tsx` — renders modal
```typescript
// Arrange: isOpen=true
// Act: Render FolderPicker
// Assert: Modal visible with title, tree, buttons
```

#### Test 6: `FolderPicker.test.tsx` — calls onSelect on confirm
```typescript
// Arrange: Folder selected
// Act: Click confirm button
// Assert: onSelect called with folder path
```

#### Test 7: `FolderPicker.test.tsx` — calls onClose on cancel
```typescript
// Arrange: Modal open
// Act: Click cancel button
// Assert: onClose called
```

#### Test 8: `FolderPicker.test.tsx` — closes on Escape
```typescript
// Arrange: Modal open
// Act: Press Escape key
// Assert: onClose called
```

### Phase 3: Navigation (TDD)

#### Test 9: `FolderPicker.test.tsx` — navigate into folder
```typescript
// Arrange: FolderPicker with items
// Act: Double-click folder
// Assert: Tree shows subfolder contents
```

#### Test 10: `FolderPicker.test.tsx` — breadcrumb navigation
```typescript
// Arrange: Deep in directory tree
// Act: Click first breadcrumb segment
// Assert: Navigates to root, tree updates
```

#### Test 11: `FolderPicker.test.tsx` — keyboard navigation
```typescript
// Arrange: Modal open
// Act: Press arrow keys
// Assert: Selection moves through items
```

### Phase 4: File Operations (TDD)

#### Test 12: `FolderPicker.test.tsx` — create folder
```typescript
// Arrange: Click new folder button
// Act: Type folder name, press Enter
// Assert: RPC createFolder called, tree updates
```

#### Test 13: `FolderPicker.test.tsx` — rename folder
```typescript
// Arrange: Right-click folder, select rename
// Act: Type new name, press Enter
// Assert: RPC renameFolder called, tree updates
```

#### Test 14: `FolderPicker.test.tsx` — delete folder
```typescript
// Arrange: Right-click folder, select delete
// Act: Confirm deletion
// Assert: RPC deleteFolder called, tree updates
```

#### Test 15: `FolderPicker.test.tsx` — error handling
```typescript
// Arrange: RPC returns error
// Act: Attempt operation
// Assert: Error message shown, no crash
```

### Phase 5: Polish (TDD)

#### Test 16: `FolderPicker.test.tsx` — hidden files toggle
```typescript
// Arrange: Hidden files exist
// Act: Toggle show hidden
// Assert: Hidden items shown/hidden in tree
```

#### Test 17: `FolderPicker.test.tsx` — persist last directory
```typescript
// Arrange: User navigated to /some/path
// Act: Close and reopen modal
// Assert: Opens at /some/path
```

### Test Files

| Test File | Location | Framework |
|----------|----------|-----------|
| `rpc.test.ts` | `src/bun/rpc.test.ts` | Bun test |
| `FolderPicker.test.tsx` | `src/mainview/components/FolderPicker.test.tsx` | Bun/Vitest |

---

## 8. Testing Strategy

### TDD Workflow
1. Write **failing test** first (RED phase)
2. Write **minimal implementation** to pass (GREEN phase)
3. **Refactor** if needed
4. Repeat

### Test Categories

| Category | Test Count | Focus |
|----------|-----------|-------|
| RPC Layer | 4 tests | Backend filesystem operations |
| Component Render | 2 tests | Modal opens, renders correctly |
| User Interactions | 8 tests | Navigation, keyboard, CRUD |
| Edge Cases | 3 tests | Errors, persistence, hidden files |
| **Total** | **17 tests** | Full coverage |

### Test Runners

- **Bun tests**: `bun test` for RPC layer (`src/bun/*.test.ts`)
- **Component tests**: Vitest for SolidJS components (`*.test.tsx`)

### Running Tests

```bash
# Run all tests
bun test

# Run RPC tests only
bun test src/bun/rpc.test.ts

# Run component tests only
bun test src/mainview/components/FolderPicker.test.tsx

# Watch mode during development
bun test --watch
```

### Manual Smoke Tests (Post-TDD)

1. Open picker → should show home directory
2. Navigate to a folder → breadcrumb updates
3. Double-click folder → enters folder
4. Click "New Folder" → input appears → type name → Enter → folder created
5. Right-click folder → Rename → type new name → Enter → folder renamed
6. Right-click folder → Delete → confirm → folder deleted
7. Toggle hidden files → hidden items show/hide
8. Close and reopen → should remember last directory
9. Press Escape → modal closes
10. Press Enter with selection → callback fires

---

## 9. Dependencies

### Existing Dependencies
- `solid-js` — UI framework
- `electrobun` — Desktop app framework + RPC

### New Dependencies Required
- `vitest` — Component testing framework (SolidJS compatible)
- `@solidjs/testing-library` — Testing utilities for SolidJS

```bash
bun add -d vitest @solidjs/testing-library
```
