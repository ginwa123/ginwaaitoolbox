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
    <div class="space-y-6">
      {/* Header */}
      <div class="mb-2">
        <h1 class="font-mono text-2xl font-semibold text-[#fafafa] mb-1 tracking-tight uppercase">
          Electrobun RPC Demo
        </h1>
        <p class="text-[#52525b] text-xs font-mono uppercase tracking-widest">
          Full-duplex RPC communication between Webview and Bun
        </p>
      </div>

      {/* Two Column Layout */}
      <div class="grid grid-cols-1 lg:grid-cols-2 gap-4">
        {/* Left Column: Webview → Bun */}
        <div class="bg-[#0a0a0a] border border-[#18181b] p-5">
          <h2 class="font-mono text-xs font-semibold text-[#22c55e] mb-4 uppercase tracking-[0.15em]">
            Webview → Bun
          </h2>

          {/* Requests (call & wait) */}
          <div class="mb-5">
            <h3 class="text-[10px] text-[#71717a] mb-2 font-mono uppercase tracking-widest">
              Requests
            </h3>
            <div class="space-y-1">
              <button
                onClick={handleAddNumbers}
                disabled={loading()}
                class="w-full bg-[#09090b] hover:bg-[#18181b] border border-[#27272a] px-3 py-2 text-left transition-colors disabled:opacity-50"
              >
                <span class="text-[#22c55e] font-mono text-xs">addNumbers(42, 58)</span>
                <span class="text-[#52525b] text-[10px] ml-2">→ sum</span>
              </button>

              <button
                onClick={handleGetSystemInfo}
                disabled={loading()}
                class="w-full bg-[#09090b] hover:bg-[#18181b] border border-[#27272a] px-3 py-2 text-left transition-colors disabled:opacity-50"
              >
                <span class="text-[#22c55e] font-mono text-xs">getSystemInfo()</span>
                <span class="text-[#52525b] text-[10px] ml-2">→ platform</span>
              </button>

              <button
                onClick={handleEcho}
                disabled={loading()}
                class="w-full bg-[#09090b] hover:bg-[#18181b] border border-[#27272a] px-3 py-2 text-left transition-colors disabled:opacity-50"
              >
                <span class="text-[#22c55e] font-mono text-xs">echo("Hello!")</span>
                <span class="text-[#52525b] text-[10px] ml-2">→ text</span>
              </button>
            </div>
          </div>

          {/* Messages (fire & forget) */}
          <div>
            <h3 class="text-[10px] text-[#71717a] mb-2 font-mono uppercase tracking-widest">
              Messages
            </h3>
            <div class="flex gap-1">
              <button
                onClick={() => handleSendLogMessage('info')}
                class="bg-[#1d4ed8] hover:bg-[#2563eb] px-3 py-1.5 text-[10px] font-mono uppercase tracking-wider text-white transition-colors"
              >
                Info
              </button>
              <button
                onClick={() => handleSendLogMessage('warn')}
                class="bg-[#d97706] hover:bg-[#ea580c] px-3 py-1.5 text-[10px] font-mono uppercase tracking-wider text-white transition-colors"
              >
                Warn
              </button>
              <button
                onClick={() => handleSendLogMessage('error')}
                class="bg-[#dc2626] hover:bg-[#ef4444] px-3 py-1.5 text-[10px] font-mono uppercase tracking-wider text-white transition-colors"
              >
                Error
              </button>
            </div>
          </div>
        </div>

        {/* Right Column: Bun → Webview (passive) */}
        <div class="bg-[#0a0a0a] border border-[#18181b] p-5">
          <h2 class="font-mono text-xs font-semibold text-[#fbbf24] mb-4 uppercase tracking-[0.15em]">
            Bun → Webview
          </h2>

          {/* Counter from Bun */}
          <div class="bg-[#09090b] border border-[#27272a] p-3 mb-3">
            <div class="text-[10px] text-[#52525b] mb-1 font-mono uppercase tracking-widest">
              Counter
            </div>
            <div class="font-mono text-2xl text-[#fbbf24]">{props.counter}</div>
            <div class="text-[10px] text-[#3f3f46] mt-1 font-mono uppercase tracking-wider">
              Updates every 3s
            </div>
          </div>

          {/* Backend Info from Bun (PUSHED via message) */}
          <div class="bg-[#09090b] border border-[#27272a] p-3 mb-3">
            <div class="text-[10px] text-[#52525b] mb-2 font-mono uppercase tracking-widest">
              Backend (Pushed)
            </div>
            {props.backendInfo ? (
              <div class="space-y-1">
                <div class="font-mono text-[11px]">
                  <span class="text-[#52525b]">Port: </span>
                  <span class="text-[#fbbf24]">{props.backendInfo.port}</span>
                </div>
                <div class="font-mono text-[11px]">
                  <span class="text-[#52525b]">URL: </span>
                  <span class="text-[#fbbf24]">{props.backendInfo.url}</span>
                </div>
              </div>
            ) : (
              <div class="text-[10px] text-[#3f3f46] font-mono uppercase tracking-wider">
                Waiting...
              </div>
            )}
          </div>

          {/* Request port from Bun (PULL approach) */}
          <div class="bg-[#09090b] border border-[#27272a] p-3 mb-3">
            <div class="text-[10px] text-[#52525b] mb-2 font-mono uppercase tracking-widest">
              Backend (Pull)
            </div>
            <div class="flex gap-1">
              <button
                onClick={handleGetPort}
                disabled={loading()}
                class="bg-[#27272a] hover:bg-[#3f3f46] px-3 py-1 text-[10px] font-mono uppercase tracking-wider text-[#a1a1aa] transition-colors disabled:opacity-50"
              >
                Get Port
              </button>
              <button
                onClick={handleGetUrl}
                disabled={loading()}
                class="bg-[#27272a] hover:bg-[#3f3f46] px-3 py-1 text-[10px] font-mono uppercase tracking-wider text-[#a1a1aa] transition-colors disabled:opacity-50"
              >
                Get URL
              </button>
            </div>
          </div>

          {/* Last result */}
          {props.lastResult && (
            <div class="bg-[#09090b] border border-[#27272a] p-3">
              <div class="text-[10px] text-[#52525b] mb-1 font-mono uppercase tracking-widest">
                Last Result
              </div>
              <div class="font-mono text-[11px] text-[#22c55e]">{props.lastResult}</div>
            </div>
          )}
        </div>
      </div>

      {/* Activity Log */}
      <div class="bg-[#0a0a0a] border border-[#18181b] p-5">
        <h2 class="font-mono text-xs font-semibold text-[#a78bfa] mb-3 uppercase tracking-[0.15em]">
          Activity Log
        </h2>
        <div class="bg-[#09090b] border border-[#18181b] p-3 font-mono text-[10px] h-32 overflow-y-auto">
          <For
            each={logs()}
            fallback={
              <span class="text-[#3f3f46] uppercase tracking-widest">No activity yet...</span>
            }
          >
            {(log) => <div class="text-[#a78bfa] mb-1 break-all">{log}</div>}
          </For>
        </div>
      </div>

      {/* Schema Reference */}
      <details class="bg-[#0a0a0a] border border-[#18181b] p-5">
        <summary class="font-mono text-[10px] text-[#52525b] cursor-pointer hover:text-[#71717a] uppercase tracking-widest">
          RPC Schema Reference
        </summary>
        <pre class="mt-4 text-[10px] text-[#3f3f46] overflow-x-auto leading-relaxed font-mono">
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
