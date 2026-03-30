import type { Component } from 'solid-js';

const Footer: Component = () => {
  return (
    <footer class="flex items-center justify-between h-7 px-4 bg-[#050505] border-t border-[#18181b]">
      <span class="font-mono text-[10px] text-[#52525b] uppercase tracking-widest">v0.1.0</span>
      <span class="font-mono text-[10px] text-[#52525b] uppercase tracking-widest flex items-center gap-2">
        <span class="w-1.5 h-1.5 bg-[#22c55e] inline-block" />
        Ready
      </span>
    </footer>
  );
};

export default Footer;
