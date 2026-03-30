import type { Component } from 'solid-js';

const Footer: Component = () => {
  return (
    <footer class="flex items-center justify-between h-8 px-4 bg-[#0a0a0a] border-t border-[#2a2a2a]">
      <span class="font-mono text-xs text-[#737373]">v0.1.0</span>
      <span class="font-mono text-xs text-[#737373]">Ready</span>
    </footer>
  );
};

export default Footer;
