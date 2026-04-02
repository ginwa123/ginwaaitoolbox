import { type Component, Show, For, createSignal, createEffect, onCleanup } from 'solid-js';
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
  const [error, setError] = createSignal<string | null>(null);
  const [focusedIndex, setFocusedIndex] = createSignal(-1);

  const fetchDirectory = async (path: string) => {
    setLoading(true);
    setError(null);
    try {
      const res = await fetch(
        `${baseUrl()}/api/fs/list?path=${encodeURIComponent(path)}&showHidden=${showHidden()}`
      );
      if (res.ok) {
        const data = await res.json();
        setEntries(data.entries || []);
      } else {
        const data = await res.json().catch(() => ({}));
        setError(data.error || `Failed to load directory (${res.status})`);
        setEntries([]);
      }
    } catch (err) {
      console.error('Failed to fetch directory:', err);
      setError('Failed to connect to backend');
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
      setCurrentPath(entry.path);
      setSelectedPath(null);
      setFocusedIndex(-1);
    }
  };

  const handleClick = (entry: DirectoryEntry) => {
    if (entry.isDirectory) {
      setSelectedPath(entry.path);
    }
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
            <label class="flex items-center gap-2 text-xs font-mono text-[#71717a] cursor-pointer">
              <input
                type="checkbox"
                checked={showHidden()}
                onChange={(e) => {
                  setShowHidden(e.currentTarget.checked);
                  fetchDirectory(currentPath());
                }}
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

            <Show when={error()}>
              <div class="text-center text-[#ef4444] text-xs font-mono py-8">
                {error()}
              </div>
            </Show>

            <Show when={!loading() && !error() && entries().length === 0}>
              <div class="text-center text-[#52525b] text-xs font-mono py-8">
                Empty folder
              </div>
            </Show>

            <Show when={!loading() && !error()}>
              <div class="space-y-1">
                <For each={entries()}>
                  {(entry, index) => {
                    const folderIndex = entries()
                      .slice(0, index())
                      .filter((e) => e.isDirectory).length;
                    const isFocused = () => focusedIndex() === folderIndex && entry.isDirectory;

                    return (
                      <div
                        onClick={() => handleClick(entry)}
                        onDblClick={() => handleDoubleClick(entry)}
                        class={`
                          flex items-center gap-2 px-3 py-2 cursor-pointer transition-colors
                          ${
                            selectedPath() === entry.path
                              ? 'bg-[#18181b] border border-[#fbbf24]'
                              : isFocused()
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
                    );
                  }}
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
