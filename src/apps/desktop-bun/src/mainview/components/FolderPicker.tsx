import { type Component, Show, For, createSignal, createEffect, onCleanup } from 'solid-js';
import { electroview } from '../main';

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

// LocalStorage keys
const STORAGE_KEY_LAST_PATH = 'folder-picker-last-path';
const STORAGE_KEY_SHOW_HIDDEN = 'folder-picker-show-hidden';

// Helper to get last path from localStorage
const getLastPath = (): string => {
  try {
    return localStorage.getItem(STORAGE_KEY_LAST_PATH) || '/';
  } catch {
    return '/';
  }
};

// Helper to get show hidden from localStorage
const getShowHidden = (): boolean => {
  try {
    return localStorage.getItem(STORAGE_KEY_SHOW_HIDDEN) === 'true';
  } catch {
    return false;
  }
};

export const FolderPicker: Component<FolderPickerProps> = (props) => {
  // Initialize from localStorage if no initialPath provided
  const [currentPath, setCurrentPath] = createSignal(props.initialPath ?? getLastPath());
  const [selectedPath, setSelectedPath] = createSignal<string | null>(null);
  const [entries, setEntries] = createSignal<DirectoryEntry[]>([]);
  const [loading, setLoading] = createSignal(false);
  const [showHidden, setShowHidden] = createSignal(getShowHidden());
  const [error, setError] = createSignal<string | null>(null);
  const [focusedIndex, setFocusedIndex] = createSignal(-1);

  // File operation state
  const [showContextMenu, setShowContextMenu] = createSignal(false);
  const [contextMenuPosition, setContextMenuPosition] = createSignal({ x: 0, y: 0 });
  const [contextMenuTarget, setContextMenuTarget] = createSignal<DirectoryEntry | null>(null);
  const [editingEntry, setEditingEntry] = createSignal<{ entry: DirectoryEntry; type: 'create' | 'rename' } | null>(
    null
  );
  const [editValue, setEditValue] = createSignal('');

  // Save current path to localStorage
  const saveLastPath = (path: string) => {
    try {
      localStorage.setItem(STORAGE_KEY_LAST_PATH, path);
    } catch {}
  };

  // Save show hidden preference to localStorage
  const saveShowHidden = (show: boolean) => {
    try {
      localStorage.setItem(STORAGE_KEY_SHOW_HIDDEN, String(show));
    } catch {}
  };

  const fetchDirectory = async (path: string) => {
    setLoading(true);
    setError(null);
    try {
      // Use Bun RPC instead of HTTP call
      const entries = await (electroview as any).rpc.request.listDirectory({
        path,
        showHidden: showHidden(),
      });
      setEntries(entries || []);
    } catch (err) {
      console.error('Failed to fetch directory:', err);
      setError('Failed to load directory via RPC');
      setEntries([]);
    }
    setLoading(false);
  };

  // Fetch when path or showHidden changes
  createEffect(() => {
    if (props.isOpen) {
      fetchDirectory(currentPath());
      setFocusedIndex(-1);
    }
  });

  const handleSelect = () => {
    if (selectedPath()) {
      props.onSelect(selectedPath()!);
    }
  };

  const handleDoubleClick = (entry: DirectoryEntry) => {
    if (entry.isDirectory) {
      const newPath = entry.path;
      setCurrentPath(newPath);
      saveLastPath(newPath);
      setSelectedPath(null);
      setFocusedIndex(-1);
    }
  };

  const handleClick = (entry: DirectoryEntry) => {
    if (entry.isDirectory) {
      setSelectedPath(entry.path);
    }
  };

  // Context menu handlers
  const handleContextMenu = (e: MouseEvent, entry: DirectoryEntry) => {
    e.preventDefault();
    setContextMenuPosition({ x: e.clientX, y: e.clientY });
    setContextMenuTarget(entry);
    setShowContextMenu(true);
  };

  const handleNewFolder = () => {
    setEditingEntry({
      entry: { path: currentPath(), name: '', isDirectory: true } as DirectoryEntry,
      type: 'create',
    });
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
      // Use Bun RPC instead of HTTP call
      const result = await (electroview as any).rpc.request.deleteFolder({
        path: target.path,
      });

      if (result.success) {
        fetchDirectory(currentPath());
      } else {
        setError(result.error || 'Failed to delete folder');
      }
    } catch (err) {
      setError('Failed to delete folder via RPC');
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
        // Use Bun RPC instead of HTTP call
        const result = await (electroview as any).rpc.request.createFolder({
          path: editing.entry.path,
          name: newName,
        });

        if (result.success) {
          fetchDirectory(currentPath());
        } else {
          setError(result.error || 'Failed to create folder');
        }
      } else {
        // Use Bun RPC instead of HTTP call
        const result = await (electroview as any).rpc.request.renameFolder({
          oldPath: editing.entry.path,
          newName,
        });

        if (result.success) {
          fetchDirectory(currentPath());
          if (selectedPath() === editing.entry.path) {
            setSelectedPath(result.newPath);
          }
        } else {
          setError(result.error || 'Failed to rename folder');
        }
      }
    } catch (err) {
      setError('Operation failed via RPC');
    }

    setEditingEntry(null);
  };

  const handleEditCancel = () => {
    setEditingEntry(null);
    setError(null);
  };

  // Keyboard navigation
  const handleKeyDown = (e: KeyboardEvent) => {
    const items = entries().filter((e) => e.isDirectory); // Only navigate folders
    const currentFocused = focusedIndex();

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
        if (currentFocused >= 0 && items[currentFocused]) {
          const entry = items[currentFocused];
          if (entry.isDirectory) {
            handleDoubleClick(entry);
          }
        } else if (selectedPath()) {
          handleSelect();
        }
        break;
      case 'Escape':
        e.preventDefault();
        if (editingEntry()) {
          handleEditCancel();
        } else {
          props.onClose();
        }
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
    const items = entries().filter((e) => e.isDirectory);
    if (idx >= 0 && items[idx]) {
      setSelectedPath(items[idx].path);
    }
  });

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
            <div class="flex items-center gap-4">
              <button
                onClick={handleNewFolder}
                class="px-3 py-1.5 text-xs font-mono text-[#a1a1aa] bg-[#18181b] hover:bg-[#27272a] border border-[#27272a] hover:border-[#fbbf24] transition-colors"
              >
                + New Folder
              </button>
              <label class="flex items-center gap-2 text-xs font-mono text-[#71717a] cursor-pointer">
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
                Show Hidden
              </label>
            </div>
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
                    onClick={() => {
                      setCurrentPath(segment.path);
                      saveLastPath(segment.path);
                    }}
                    class="text-xs font-mono text-[#71717a] hover:text-[#fbbf24] transition-colors whitespace-nowrap"
                  >
                    {segment.name}
                  </button>
                </>
              )}
            </For>
          </div>

          {/* Tree Content */}
          <div class="flex-1 overflow-auto p-4 relative">
            {/* New folder input at top */}
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

            <Show when={loading()}>
              <div class="text-center text-[#52525b] text-xs font-mono py-8">Loading...</div>
            </Show>

            <Show when={error()}>
              <div class="text-center text-[#ef4444] text-xs font-mono py-8">{error()}</div>
            </Show>

            <Show when={!loading() && !error() && entries().length === 0}>
              <div class="text-center text-[#52525b] text-xs font-mono py-8">Empty folder</div>
            </Show>

            <Show when={!loading() && !error()}>
              <div class="space-y-1">
                <For each={entries()}>
                  {(entry) => {
                    const isEditing = () =>
                      editingEntry()?.entry.path === entry.path && editingEntry()?.type === 'rename';

                    return (
                      <Show
                        when={isEditing()}
                        fallback={
                          <div
                            onClick={() => handleClick(entry)}
                            onDblClick={() => handleDoubleClick(entry)}
                            onContextMenu={(e) => entry.isDirectory && handleContextMenu(e, entry)}
                            class={`
                              flex items-center gap-2 px-3 py-2 cursor-pointer transition-colors
                              ${
                                selectedPath() === entry.path
                                  ? 'bg-[#18181b] border border-[#fbbf24]'
                                  : 'border border-transparent hover:bg-[#18181b]'
                              }
                              ${!entry.isDirectory ? 'opacity-50' : ''}
                            `}
                          >
                            <span class="text-[#fbbf24]">
                              {entry.isDirectory ? '📁' : '📄'}
                            </span>
                            <span class="text-sm font-mono text-[#e4e4e7]">{entry.name}</span>
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
                    );
                  }}
                </For>
              </div>
            </Show>

            {/* Context Menu */}
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

            {/* Close context menu on outside click */}
            <Show when={showContextMenu()}>
              <div class="fixed inset-0 z-40" onClick={() => setShowContextMenu(false)} />
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
