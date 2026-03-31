/**
 * Webview Side - Browser entry point
 *
 * This runs in the embedded Chromium browser.
 * We define RPC handlers for functions Bun can call,
 * and use effects to demonstrate Webview → Bun calls!
 */
import { Route, Router } from '@solidjs/router';
import { Component, createEffect, createSignal, onCleanup, onMount } from 'solid-js';
/* @refresh reload */
import { render } from 'solid-js/web';
import { QueryClient, QueryClientProvider } from '@tanstack/solid-query';
import { AppLayout } from './AppLayout';
import SessionChat from './pages/SessionChat';
import Welcome from './pages/Welcome';
import './app.css';
import { Electroview } from 'electrobun/view';
import { DemoRPCType } from 'src/shared/rpc';
import { initBaseUrl } from './utils/baseUrl';

// Create QueryClient for TanStack Query
const queryClient = new QueryClient({});

// ============================================================================
// Initialize baseUrl - listen for port from Bun via RPC
// ============================================================================
initBaseUrl();

// ============================================================================
// Type for the backend info that we receive from Bun
// ============================================================================
export interface BackendInfo {
  port: number;
  url: string;
}

// ============================================================================
// RPC Setup
// ============================================================================

// Create the RPC instance with type-safe handlers
const rpc = Electroview.defineRPC<DemoRPCType>({
  handlers: {
    // -----------------------------------------------------------------
    // REQUESTS - Functions that run in WEBVIEW when BUN calls them
    // -----------------------------------------------------------------
    requests: {
      // Multiply two numbers (Bun can call this!)
      multiplyNumbers: ({ a, b }) => {
        console.log(`[Webview] multiplyNumbers called with ${a} * ${b}`);
        return a * b;
      },

      // Get current page title
      getPageTitle: () => {
        return document.title;
      },
    },

    // -----------------------------------------------------------------
    // MESSAGES - One-way messages from BUN (no response needed)
    // -----------------------------------------------------------------
    messages: {
      // Wildcard handler - catches ALL messages
      '*': (messageName, payload) => {
        console.log(`[Webview] Received message "${messageName}":`, payload);
      },

      // Show browser notification
      notifyBrowser: ({ title, body }) => {
        if ('Notification' in window && Notification.permission === 'granted') {
          new Notification(title, { body });
        }
        console.log(`[Webview] Notification: ${title} - ${body}`);
      },

      // Update counter display
      updateCounter: ({ value }) => {
        // Dispatch custom event for UI to listen
        window.dispatchEvent(new CustomEvent('counter-update', { detail: value }));
      },

      // === PORT PASSING: Bun pushes the backend info to us! ===
      backendPortUpdate: ({ port, url }) => {
        console.log(`[Webview] Received backend info from Bun: port=${port}, url=${url}`);
        // Dispatch custom event for UI to listen
        window.dispatchEvent(new CustomEvent('backend-info', { detail: { port, url } }));
      },
    },
  },
});

// Create the Electroview instance
export const electroview = new Electroview({ rpc });

// ============================================================================
// App Component
// ============================================================================
const App: Component = () => {
  // Counter state (updated from Bun via messages)
  const [counter, setCounter] = createSignal(0);

  // RPC result display
  const [lastResult, setLastResult] = createSignal<string | null>(null);

  // === PORT PASSING: Store backend info received from Bun ===
  const [backendInfo, setBackendInfo] = createSignal<BackendInfo | null>(null);

  // Listen for counter updates from Bun
  onMount(() => {
    const counterHandler = (e: CustomEvent) => {
      setCounter(e.detail);
    };

    // === PORT PASSING: Listen for backend info from Bun ===
    const backendHandler = (e: CustomEvent<BackendInfo>) => {
      setBackendInfo(e.detail);
    };

    window.addEventListener('counter-update', counterHandler as EventListener);
    window.addEventListener('backend-info', backendHandler as EventListener);

    onCleanup(() => {
      window.removeEventListener('counter-update', counterHandler as EventListener);
      window.removeEventListener('backend-info', backendHandler as EventListener);
    });
  });

  // ==========================================================================
  // DEMO: Webview → Bun Communication
  // ==========================================================================
  createEffect(() => {
    (async () => {
      console.log('\n========================================');
      console.log('[Webview] Demo: Webview calling Bun functions');
      console.log('========================================\n');

      // Type-safe RPC access via type assertion
      const rpcInstance = rpc as any;

      // === PORT PASSING: Request port from Bun (Pull approach) ===
      try {
        const port = await rpcInstance.request.getBackendPort();
        console.log(`[Webview] Pulled port from Bun: ${port}`);
      } catch (err) {
        console.error('[Webview] Error getting port:', err);
      }

      // Example: Call addNumbers (request/response)
      try {
        const sum = await rpcInstance.request.addNumbers({ a: 10, b: 20 });
        console.log(`[Webview] addNumbers(10, 20) = ${sum}`);
        setLastResult(`addNumbers(10, 20) = ${sum}`);
      } catch (err) {
        console.error('[Webview] Error:', err);
      }

      // Example: Send a message to Bun (fire and forget)
      rpcInstance.send.logMessage({
        text: 'Hello from Webview! 🖐️',
        level: 'info',
      });

      // Example: Get system info from Bun
      try {
        const info = await rpcInstance.request.getSystemInfo();
        console.log('[Webview] System info:', info);
      } catch (err) {
        console.error('[Webview] Error getting system info:', err);
      }

      // Example: Echo test
      try {
        const echoed = await rpcInstance.request.echo({ text: 'Testing RPC!' });
        console.log(`[Webview] Echo result: "${echoed}"`);
      } catch (err) {
        console.error('[Webview] Error:', err);
      }
    })();
  });

  return (
    <Router root={AppLayout}>
      <Route
        path="/"
        component={() => (
          <Welcome
            counter={counter()}
            lastResult={lastResult()}
            electroview={rpc}
            backendInfo={backendInfo()}
          />
        )}
      />
      <Route path="/session/:sessionId" component={SessionChat} />
    </Router>
  );
};

render(
  () => (
    <QueryClientProvider client={queryClient}>
      <App />
    </QueryClientProvider>
  ),
  document.getElementById('app')!
);
