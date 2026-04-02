/**
 * Bun Side - Main process entry point
 *
 * This is where your server/backend code runs.
 * We define RPC handlers for functions the webview can call,
 * and also show how Bun can call webview functions!
 */
import { ApplicationMenu, BrowserView, BrowserWindow } from 'electrobun/bun';
import type { DemoRPCType } from '../shared/rpc';
import { createFolder, deleteFolder, listDirectory, renameFolder } from './filesystem-handlers';
import { findNalarPort } from './processDiscovery';

// ============================================================================
// Application Menu
// ============================================================================
ApplicationMenu.setApplicationMenu([
  { submenu: [{ label: 'Quit', role: 'quit' }] },
  {
    label: 'Edit',
    submenu: [
      { role: 'undo' },
      { role: 'redo' },
      { type: 'separator' },
      { label: 'Custom Menu Item 🚀', action: 'custom-action-1', tooltip: "I'm a tooltip" },
      { label: 'Custom menu disabled', enabled: false, action: 'custom-action-2' },
      { type: 'separator' },
      { role: 'cut' },
      { role: 'copy' },
      { role: 'paste' },
      { role: 'pasteAndMatchStyle' },
      { role: 'delete' },
      { role: 'selectAll' },
    ],
  },
]);

// ============================================================================
// Configuration
// ============================================================================
const DEV_SERVER_PORT = 5173;
const DEV_SERVER_URL = `http://localhost:${DEV_SERVER_PORT}`;
const NALAR_PORT = findNalarPort();
console.log(`[Desktop] Discovered nalar port: ${NALAR_PORT}`);

// Backend URL that webview will use to connect
const BACKEND_URL = `http://localhost:${NALAR_PORT}`;

// ============================================================================
// Helper functions for system info
// ============================================================================
function getPlatform(): string {
  if (typeof process !== 'undefined' && process.platform) {
    const platform = process.platform;
    if (platform === 'linux') return 'Linux 🐧';
    if (platform === 'darwin') return 'macOS 🍎';
    if (platform === 'win32') return 'Windows 🪟';
  }
  return 'Unknown';
}

function getArch(): string {
  if (typeof process !== 'undefined' && process.arch) {
    return process.arch === 'x64' ? '64-bit' : process.arch;
  }
  return 'Unknown';
}

// ============================================================================
// RPC Handlers (Bun handles these when webview calls)
// ============================================================================
const myWebviewRPC = BrowserView.defineRPC<DemoRPCType>({
  maxRequestTime: 5000,
  handlers: {
    // -----------------------------------------------------------------
    // REQUESTS - Functions that run in BUN when webview calls them
    // -----------------------------------------------------------------
    requests: {
      // Add two numbers (simple demo)
      addNumbers: ({ a, b }) => {
        console.log(`[Bun] addNumbers called with ${a} + ${b}`);
        return a + b;
      },

      // Get system info (useful for debugging)
      getSystemInfo: () => {
        return {
          platform: getPlatform(),
          arch: getArch(),
          version: Bun.version,
        };
      },

      // Echo back text (for testing RPC is working)
      echo: ({ text }) => {
        console.log(`[Bun] echo called with: "${text}"`);
        return `Bun echo: ${text}`;
      },

      // === PORT PASSING EXAMPLE ===
      // Webview calls this to get the backend port
      getBackendPort: () => {
        console.log(`[Bun] getBackendPort called, returning: ${NALAR_PORT}`);
        return NALAR_PORT;
      },

      // Webview calls this to get the full backend URL
      getBackendUrl: () => {
        console.log(`[Bun] getBackendUrl called, returning: ${BACKEND_URL}`);
        return BACKEND_URL;
      },

      // Get the current working directory from Bun's main process
      getCwd: () => {
        const cwd = process.cwd();
        console.log(`[Bun] getCwd called, returning: ${cwd}`);
        return cwd;
      },

      // === FILESYSTEM OPERATIONS ===
      // List directory contents
      listDirectory: ({ path, showHidden }) => {
        console.log(`[Bun] listDirectory called: ${path}, showHidden=${showHidden}`);
        return listDirectory(path, showHidden);
      },

      // Create a new folder
      createFolder: ({ path, name }) => {
        console.log(`[Bun] createFolder called: ${path}/${name}`);
        return createFolder(path, name);
      },

      // Rename/move a folder
      renameFolder: ({ oldPath, newName }) => {
        console.log(`[Bun] renameFolder called: ${oldPath} -> ${newName}`);
        return renameFolder(oldPath, newName);
      },

      // Delete an empty folder
      deleteFolder: ({ path }) => {
        console.log(`[Bun] deleteFolder called: ${path}`);
        return deleteFolder(path);
      },
    },

    // -----------------------------------------------------------------
    // MESSAGES - One-way messages from webview (no response needed)
    // -----------------------------------------------------------------
    messages: {
      // Wildcard handler - catches ALL messages
      '*': (messageName, payload) => {
        console.log(`[Bun] Received message "${messageName}":`, payload);
      },

      // Specific handler for logMessage
      logMessage: ({ text, level }) => {
        if (level === 'error') {
          console.error(`[Bun Log] ${text}`);
        } else if (level === 'warn') {
          console.warn(`[Bun Log] ${text}`);
        } else {
          console.log(`[Bun Log] ${text}`);
        }
      },
    },
  },
});

// ============================================================================
// Create Window
// ============================================================================
async function getMainViewUrl(): Promise<string> {
  try {
    await fetch(DEV_SERVER_URL, { method: 'HEAD' });
    console.log(`HMR enabled: Using Vite dev server at ${DEV_SERVER_URL}`);
    // NOTE: Don't add query params - electrobun treats them as file paths!
    // Port is passed via RPC instead
    return DEV_SERVER_URL;
  } catch {
    console.log('Vite dev server not running.');
  }
  return 'views://mainview/index.html';
}

const mainWindow = new BrowserWindow({
  title: 'Desktop Bun - RPC Demo',
  url: await getMainViewUrl(),
  rpc: myWebviewRPC, // ✅ CRITICAL: Pass RPC to window
  // Enable SPA routing - serve index.html for all mainview paths
  // navigationRules: `allow: views://mainview/**`,
});

// Export webview for external use
export const defaultWebview = mainWindow.webview;

// ============================================================================
// BONUS: Bun → Webview Communication!
// After the window loads, Bun can also call webview functions!
// ============================================================================

// Wait for window to be ready, then demonstrate Bun → Webview calls
setTimeout(() => {
  console.log('\n========================================');
  console.log('[Bun] Demo: Bun calling Webview functions');
  console.log('========================================\n');

  const rpc = mainWindow.webview.rpc;
  if (!rpc) {
    console.error('[Bun] RPC not available on webview');
    return;
  }

  // === PORT PASSING: Bun pushes port to Webview ===
  // Instead of webview asking, Bun can PUSH the port info
  console.log(`[Bun] Pushing backend info to webview: port=${NALAR_PORT}, url=${BACKEND_URL}`);
  rpc.send.backendPortUpdate({ port: NALAR_PORT, url: BACKEND_URL });

  // Example: Call webview's multiplyNumbers function
  rpc.request
    .multiplyNumbers({ a: 6, b: 7 })
    .then((result) => {
      console.log(`[Bun] multiplyNumbers(6, 7) = ${result}`);
    })
    .catch((err) => {
      console.error('[Bun] Error calling multiplyNumbers:', err);
    });

  // Example: Send a notification to webview
  rpc.send.notifyBrowser({
    title: 'Hello from Bun! 👋',
    body: 'This message was sent from the main process!',
  });

  // Example: Get page title from webview
  rpc.request
    .getPageTitle()
    .then((title) => {
      console.log(`[Bun] Current page title: "${title}"`);
    })
    .catch((err) => {
      console.error('[Bun] Error getting page title:', err);
    });
}, 2000); // Wait 2 seconds for window to fully load

// Periodic counter updates (demonstrates streaming messages from Bun → Webview)
let counter = 0;
setInterval(() => {
  counter++;
  const rpc = mainWindow.webview.rpc;
  if (rpc) {
    rpc.send.updateCounter({ value: counter });
  }

  // Stop after 10 updates
  if (counter >= 10) {
    console.log('[Bun] Stopped counter updates after 10 iterations');
  }
}, 3000); // Every 3 seconds

console.log('[Desktop] Desktop Bun app started!');
