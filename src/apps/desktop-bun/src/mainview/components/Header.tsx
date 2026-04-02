import type { Component } from 'solid-js';
import { log } from '../utils/logger';

const Header: Component = () => {
  const handleMinimize = () => {
    log.info('Minimize clicked');
  };

  const handleMaximize = () => {
    log.info('Maximize clicked');
  };

  const handleClose = () => {
    log.info('Close clicked');
  };

  return (
    <header class="flex items-center justify-between h-10 px-4 bg-[#050505] border-b border-[#18181b] select-none">
      <div class="flex items-center gap-2">
        <div class="w-2 h-2 bg-[#fbbf24]" />
        <span class="font-mono text-xs font-semibold text-[#a1a1aa] uppercase tracking-[0.15em]">
          Desktop Bun
        </span>
      </div>

      <div class="flex items-center">
        <button
          onClick={handleMinimize}
          class="w-10 h-8 flex items-center justify-center text-[#52525b] hover:bg-[#18181b] hover:text-[#a1a1aa] transition-colors"
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
          class="w-10 h-8 flex items-center justify-center text-[#52525b] hover:bg-[#18181b] hover:text-[#a1a1aa] transition-colors"
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
          class="w-10 h-8 flex items-center justify-center text-[#52525b] hover:bg-[#ef4444] hover:text-white transition-colors"
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
