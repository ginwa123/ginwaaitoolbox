import type { Component } from "solid-js";
import { getCurrentWindow } from "@tauri-apps/api/window";

const Header: Component = () => {
  const appWindow = getCurrentWindow();

  const handleMinimize = () => appWindow.minimize();
  const handleMaximize = () => appWindow.toggleMaximize();
  const handleClose = () => appWindow.close();

  return (
    <header
      data-tauri-drag-region
      class="flex items-center justify-between h-12 px-4 bg-[#0a0a0a] border-b border-[#2a2a2a] select-none"
    >
      <div class="flex items-center gap-3" data-tauri-drag-region>
        <div class="w-3 h-3 bg-[#facc15]" />
        <span class="font-mono text-sm font-medium text-[#e5e5e5]">
          DESKTOP
        </span>
      </div>

      <div class="flex items-center gap-1">
        <button
          onClick={handleMinimize}
          class="w-10 h-8 flex items-center justify-center text-[#737373] hover:bg-[#141414] hover:text-[#e5e5e5] transition-colors duration-150"
          title="Minimize"
        >
          <svg
            width="12"
            height="12"
            viewBox="0 0 12 12"
            fill="none"
            stroke="currentColor"
            stroke-width="1.5"
          >
            <line x1="2" y1="6" x2="10" y2="6" />
          </svg>
        </button>
        <button
          onClick={handleMaximize}
          class="w-10 h-8 flex items-center justify-center text-[#737373] hover:bg-[#141414] hover:text-[#e5e5e5] transition-colors duration-150"
          title="Maximize"
        >
          <svg
            width="12"
            height="12"
            viewBox="0 0 12 12"
            fill="none"
            stroke="currentColor"
            stroke-width="1.5"
          >
            <rect x="2" y="2" width="8" height="8" />
          </svg>
        </button>
        <button
          onClick={handleClose}
          class="w-10 h-8 flex items-center justify-center text-[#737373] hover:bg-[#ef4444] hover:text-white transition-colors duration-150"
          title="Close"
        >
          <svg
            width="12"
            height="12"
            viewBox="0 0 12 12"
            fill="none"
            stroke="currentColor"
            stroke-width="1.5"
          >
            <line x1="2" y1="2" x2="10" y2="10" />
            <line x1="10" y1="2" x2="2" y2="10" />
          </svg>
        </button>
      </div>
    </header>
  );
};

export default Header;
