/**
 * Welcome Page - Interactive RPC Demo UI
 *
 * This component demonstrates all RPC communication patterns:
 * - Webview → Bun: requests (call & wait)
 * - Webview → Bun: messages (fire & forget)
 * - Bun → Webview: requests (call & wait) [Bun calls this page]
 * - Bun → Webview: messages (fire & forget) [Bun sends to this page]
 * - PORT PASSING: Bun pushes port to webview via message
 */
import { type Component, For, createSignal } from 'solid-js';
import type { BackendInfo } from '../main';

// Props interface - using 'any' for RPC due to complex type inference issues
interface WelcomeProps {
  counter: number;
  lastResult: string | null;
  electroview: any; // Complex Electroview type - simplified for usability
  backendInfo: BackendInfo | null;
}

const Welcome: Component<WelcomeProps> = (props) => {
  // Local state for UI
  const [logs, setLogs] = createSignal<string[]>([]);
  const [loading, setLoading] = createSignal(false);

  // Helper to add log entries
  const addLog = (message: string) => {
    const timestamp = new Date().toLocaleTimeString();
    setLogs((prev) => [...prev.slice(-9), `[${timestamp}] ${message}`]);
  };

  // ==========================================================================
  // WEBVIEW → BUN: Request (call & wait for response)
  // ==========================================================================
  const handleAddNumbers = async () => {
    if (!props.electroview?.request?.addNumbers) return;
    setLoading(true);
    try {
      const result = await props.electroview.request.addNumbers({ a: 42, b: 58 });
      addLog(`addNumbers(42, 58) = ${result}`);
    } catch (err) {
      addLog(`Error: ${err}`);
    }
    setLoading(false);
  };

  const handleGetSystemInfo = async () => {
    if (!props.electroview?.request?.getSystemInfo) return;
    setLoading(true);
    try {
      const info = await props.electroview.request.getSystemInfo();
      addLog(`System: ${info.platform} ${info.arch} (Bun ${info.version})`);
    } catch (err) {
      addLog(`Error: ${err}`);
    }
    setLoading(false);
  };

  const handleEcho = async () => {
    if (!props.electroview?.request?.echo) return;
    setLoading(true);
    try {
      const result = await props.electroview.request.echo({ text: 'Hello from Webview!' });
      addLog(`echo() returned: "${result}"`);
    } catch (err) {
      addLog(`Error: ${err}`);
    }
    setLoading(false);
  };

  // ==========================================================================
  // PORT PASSING: Request port from Bun (Pull approach)
  // ==========================================================================
  const handleGetPort = async () => {
    if (!props.electroview?.request?.getBackendPort) return;
    setLoading(true);
    try {
      const port = await props.electroview.request.getBackendPort();
      addLog(`getBackendPort() = ${port}`);
    } catch (err) {
      addLog(`Error: ${err}`);
    }
    setLoading(false);
  };

  const handleGetUrl = async () => {
    if (!props.electroview?.request?.getBackendUrl) return;
    setLoading(true);
    try {
      const url = await props.electroview.request.getBackendUrl();
      addLog(`getBackendUrl() = ${url}`);
    } catch (err) {
      addLog(`Error: ${err}`);
    }
    setLoading(false);
  };

  // ==========================================================================
  // WEBVIEW → BUN: Message (fire & forget)
  // ==========================================================================
  const handleSendLogMessage = (level: 'info' | 'warn' | 'error') => {
    if (!props.electroview?.send?.logMessage) return;
    const messages = {
      info: 'This is an info message',
      warn: 'This is a warning!',
      error: 'This is an error!',
    };
    props.electroview.send.logMessage({ text: messages[level], level });
    addLog(`Sent ${level} message to Bun`);
  };

  return (
    <div class="max-w-5xl mx-auto space-y-6">
      {/* Header */}
      <div class="mb-8">
        <h1 class="font-mono text-3xl font-semibold text-[#e5e5e5] mb-3">Electrobun RPC Demo 🎯</h1>
        <p class="text-[#737373] text-base">
          Test full-duplex RPC communication between Webview and Bun!
        </p>
      </div>

      {/* Two Column Layout */}
      <div class="grid grid-cols-1 lg:grid-cols-2 gap-6">
        {/* Left Column: Webview → Bun */}
        <div class="bg-[#141414] border border-[#2a2a2a] p-6 rounded-lg">
          <h2 class="font-mono text-lg font-medium text-[#22c55e] mb-4">🌐 Webview → Bun</h2>

          {/* Requests (call & wait) */}
          <div class="mb-6">
            <h3 class="text-sm text-[#a1a1a1] mb-3 font-medium">Requests (call & wait)</h3>
            <div class="space-y-2">
              <button
                onClick={handleAddNumbers}
                disabled={loading()}
                class="w-full bg-[#1a1a1a] hover:bg-[#252525] border border-[#333] px-4 py-2 rounded text-left transition-colors disabled:opacity-50"
              >
                <span class="text-[#22c55e] font-mono text-sm">addNumbers(42, 58)</span>
                <span class="text-[#666] text-xs ml-2">→ returns sum</span>
              </button>

              <button
                onClick={handleGetSystemInfo}
                disabled={loading()}
                class="w-full bg-[#1a1a1a] hover:bg-[#252525] border border-[#333] px-4 py-2 rounded text-left transition-colors disabled:opacity-50"
              >
                <span class="text-[#22c55e] font-mono text-sm">getSystemInfo()</span>
                <span class="text-[#666] text-xs ml-2">→ returns platform info</span>
              </button>

              <button
                onClick={handleEcho}
                disabled={loading()}
                class="w-full bg-[#1a1a1a] hover:bg-[#252525] border border-[#333] px-4 py-2 rounded text-left transition-colors disabled:opacity-50"
              >
                <span class="text-[#22c55e] font-mono text-sm">echo("Hello!")</span>
                <span class="text-[#666] text-xs ml-2">→ returns echoed text</span>
              </button>
            </div>
          </div>

          {/* Messages (fire & forget) */}
          <div>
            <h3 class="text-sm text-[#a1a1a1] mb-3 font-medium">Messages (fire & forget)</h3>
            <div class="flex gap-2 flex-wrap">
              <button
                onClick={() => handleSendLogMessage('info')}
                class="bg-blue-600 hover:bg-blue-700 px-4 py-2 rounded text-sm text-white transition-colors"
              >
                📢 Send Info
              </button>
              <button
                onClick={() => handleSendLogMessage('warn')}
                class="bg-yellow-600 hover:bg-yellow-700 px-4 py-2 rounded text-sm text-white transition-colors"
              >
                ⚠️ Send Warning
              </button>
              <button
                onClick={() => handleSendLogMessage('error')}
                class="bg-red-600 hover:bg-red-700 px-4 py-2 rounded text-sm text-white transition-colors"
              >
                ❌ Send Error
              </button>
            </div>
          </div>
        </div>

        {/* Right Column: Bun → Webview (passive) */}
        <div class="bg-[#141414] border border-[#2a2a2a] p-6 rounded-lg">
          <h2 class="font-mono text-lg font-medium text-[#f59e0b] mb-4">
            🖥️ Bun → Webview (automatic)
          </h2>

          {/* Counter from Bun */}
          <div class="bg-[#1a1a1a] border border-[#333] p-4 rounded mb-4">
            <div class="text-xs text-[#666] mb-1">Counter from Bun</div>
            <div class="font-mono text-3xl text-[#f59e0b]">{props.counter}</div>
            <div class="text-xs text-[#444] mt-1">Updates every 3 seconds</div>
          </div>

          {/* Backend Info from Bun (PUSHED via message) */}
          <div class="bg-[#1a1a1a] border border-[#333] p-4 rounded mb-4">
            <div class="text-xs text-[#666] mb-1">Backend Info (Pushed from Bun)</div>
            {props.backendInfo ? (
              <div class="space-y-1">
                <div class="font-mono text-sm">
                  <span class="text-[#666]">Port: </span>
                  <span class="text-[#f59e0b]">{props.backendInfo.port}</span>
                </div>
                <div class="font-mono text-sm">
                  <span class="text-[#666]">URL: </span>
                  <span class="text-[#f59e0b]">{props.backendInfo.url}</span>
                </div>
              </div>
            ) : (
              <div class="text-sm text-[#444]">Waiting for Bun to push info...</div>
            )}
          </div>

          {/* Request port from Bun (PULL approach) */}
          <div class="bg-[#1a1a1a] border border-[#333] p-4 rounded mb-4">
            <div class="text-xs text-[#666] mb-2">Or request port from Bun (Pull)</div>
            <div class="flex gap-2">
              <button
                onClick={handleGetPort}
                disabled={loading()}
                class="bg-[#333] hover:bg-[#444] px-3 py-1 rounded text-xs text-white transition-colors disabled:opacity-50"
              >
                Get Port
              </button>
              <button
                onClick={handleGetUrl}
                disabled={loading()}
                class="bg-[#333] hover:bg-[#444] px-3 py-1 rounded text-xs text-white transition-colors disabled:opacity-50"
              >
                Get URL
              </button>
            </div>
          </div>

          {/* Last result */}
          {props.lastResult && (
            <div class="bg-[#1a1a1a] border border-[#333] p-4 rounded">
              <div class="text-xs text-[#666] mb-1">Last RPC Result</div>
              <div class="font-mono text-sm text-[#22c55e]">{props.lastResult}</div>
            </div>
          )}
        </div>
      </div>

      {/* Activity Log */}
      <div class="bg-[#141414] border border-[#2a2a2a] p-6 rounded-lg">
        <h2 class="font-mono text-lg font-medium text-[#a855f7] mb-4">📋 Activity Log</h2>
        <div class="bg-black/50 border border-[#333] p-4 rounded font-mono text-xs h-48 overflow-y-auto">
          <For each={logs()} fallback={<span class="text-[#444]">No activity yet...</span>}>
            {(log) => <div class="text-[#a855f7] mb-1 break-all">{log}</div>}
          </For>
        </div>
      </div>

      {/* Schema Reference */}
      <details class="bg-[#141414] border border-[#2a2a2a] p-6 rounded-lg">
        <summary class="font-mono text-sm text-[#666] cursor-pointer hover:text-[#888]">
          📖 RPC Schema Reference (click to expand)
        </summary>
        <pre class="mt-4 text-xs text-[#555] overflow-x-auto leading-relaxed">
          {`// Shared Schema (src/shared/rpc.ts)

export type DemoRPCType = {
  // Functions BUN handles (webview calls these)
  bun: RPCSchema<{
    requests: {
      addNumbers({ a, b }) → number
      getSystemInfo() → { platform, arch, version }
      echo({ text }) → string
      getBackendPort() → number         // ← PORT PASSING (Pull)
      getBackendUrl() → string           // ← PORT PASSING (Pull)
    }
    messages: {
      logMessage({ text, level })
    }
  }>

  // Functions WEBVIEW handles (bun calls these)
  webview: RPCSchema<{
    requests: {
      multiplyNumbers({ a, b }) → number
      getPageTitle() → string
    }
    messages: {
      notifyBrowser({ title, body })
      updateCounter({ value })
      backendPortUpdate({ port, url })   // ← PORT PASSING (Push)
    }
  }>
}

// === TWO WAYS TO PASS PORT ===

// PUSH (Bun → Webview):
//   Bun: webview.rpc.send.backendPortUpdate({ port: 8080, url: 'http://localhost:8080' })
//   Webview: listens for 'backend-info' event

// PULL (Webview → Bun):
//   Webview: await electroview.rpc.request.getBackendPort()
//   Bun: returns the port number`}
        </pre>
      </details>
    </div>
  );
};

export default Welcome;
