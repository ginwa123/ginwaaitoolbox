import { type Component } from 'solid-js';

const Welcome: Component = () => {
  return (
    <div class="max-w-4xl mx-auto">
      <div class="mb-8">
        <h1 class="font-mono text-3xl font-semibold text-[#e5e5e5] mb-3">Welcome</h1>
        <p class="text-[#737373] text-base">
          Your SolidJS + Electrobun desktop application is ready.
        </p>
      </div>
      <div class="grid grid-cols-1 md:grid-cols-2 gap-5">
        <div class="bg-[#141414] border border-[#2a2a2a] p-6 rounded-lg">
          <h2 class="font-mono text-sm font-medium text-[#facc15] mb-3">SolidJS</h2>
          <p class="text-[#737373] text-sm leading-relaxed">
            Fine-grained reactivity with no virtual DOM overhead.
          </p>
        </div>
        <div class="bg-[#141414] border border-[#2a2a2a] p-6 rounded-lg">
          <h2 class="font-mono text-sm font-medium text-[#facc15] mb-3">Electrobun</h2>
          <p class="text-[#737373] text-sm leading-relaxed">
            Bun-powered desktop app with Chromium Embedded Framework.
          </p>
        </div>
        <div class="bg-[#141414] border border-[#2a2a2a] p-6 rounded-lg">
          <h2 class="font-mono text-sm font-medium text-[#facc15] mb-3">Tailwind CSS</h2>
          <p class="text-[#737373] text-sm leading-relaxed">
            Utility-first CSS with a brutalist dark theme.
          </p>
        </div>
        <div class="bg-[#141414] border border-[#2a2a2a] p-6 rounded-lg">
          <h2 class="font-mono text-sm font-medium text-[#facc15] mb-3">Bun</h2>
          <p class="text-[#737373] text-sm leading-relaxed">
            Fast JavaScript runtime and package manager.
          </p>
        </div>
      </div>
    </div>
  );
};

export default Welcome;
