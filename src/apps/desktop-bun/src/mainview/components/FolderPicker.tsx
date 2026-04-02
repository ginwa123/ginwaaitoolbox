import { type Component, Show, createSignal } from 'solid-js';

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
              class="w-8 h-8 flex items-center justify-center text-[#52525b] hover:text-[#e4e4e7] hover:bg-[#27272a] transition-colors text-xl leading-none"
            >
              ×
            </button>
          </div>

          {/* Content - placeholder for tree */}
          <div class="flex-1 overflow-auto p-4">
            <div class="text-center text-[#52525b] text-xs font-mono py-8">
              Select a folder...
            </div>
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
