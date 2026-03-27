import type { Component } from "solid-js";
import Header from "./components/Header";
import Sidebar from "./components/Sidebar";
import Footer from "./components/Footer";

const App: Component = () => {
  return (
    <div class="flex flex-col h-full w-full bg-[#0a0a0a]">
      <Header />
      <div class="flex flex-1 overflow-hidden">
        <Sidebar />
        <main class="flex-1 overflow-auto p-6">
          <div class="max-w-4xl mx-auto">
            <h1 class="font-mono text-2xl font-semibold text-[#e5e5e5] mb-4">
              Welcome
            </h1>
            <p class="text-[#737373] mb-6">
              Your SolidJS + Tauri desktop application is ready.
            </p>
            <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
              <div class="bg-[#141414] border border-[#2a2a2a] p-4">
                <h2 class="font-mono text-sm font-medium text-[#facc15] mb-2">
                  SolidJS
                </h2>
                <p class="text-[#737373] text-sm">
                  Fine-grained reactivity with no virtual DOM overhead.
                </p>
              </div>
              <div class="bg-[#141414] border border-[#2a2a2a] p-4">
                <h2 class="font-mono text-sm font-medium text-[#facc15] mb-2">
                  Tauri
                </h2>
                <p class="text-[#737373] text-sm">
                  Rust-powered desktop framework with tiny binaries.
                </p>
              </div>
              <div class="bg-[#141414] border border-[#2a2a2a] p-4">
                <h2 class="font-mono text-sm font-medium text-[#facc15] mb-2">
                  Tailwind CSS
                </h2>
                <p class="text-[#737373] text-sm">
                  Utility-first CSS with a brutalist dark theme.
                </p>
              </div>
              <div class="bg-[#141414] border border-[#2a2a2a] p-4">
                <h2 class="font-mono text-sm font-medium text-[#facc15] mb-2">
                  Bun
                </h2>
                <p class="text-[#737373] text-sm">
                  Fast JavaScript runtime and package manager.
                </p>
              </div>
            </div>
          </div>
        </main>
      </div>
      <Footer />
    </div>
  );
};

export default App;
