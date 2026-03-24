// Origin Private File System (OPFS) helper for .NET WASM
// This module exposes OPFS operations to the .NET side via window.DOTNET_WASM_OPFS

const DOTNET_WASM_OPFS = {
    rootHandle: null,

    // Initialize OPFS root
    async init() {
        try {
            const opfsRoot = await navigator.storage.getDirectory();
            this.rootHandle = await opfsRoot.getDirectoryHandle("nalar_data", { create: true });
            console.log("[OPFS] Initialized successfully");
            return true;
        } catch (e) {
            console.error("[OPFS] Init failed:", e);
            return false;
        }
    },

    // Read a file
    async readFile(filename) {
        if (!this.rootHandle) {
            throw new Error("OPFS not initialized");
        }
        try {
            const fileHandle = await this.rootHandle.getFileHandle(filename);
            const file = await fileHandle.getFile();
            const content = await file.text();
            return content;
        } catch (e) {
            console.error(`[OPFS] Read ${filename} failed:`, e);
            return null;
        }
    },

    // Write a file
    async writeFile(filename, content) {
        if (!this.rootHandle) {
            throw new Error("OPFS not initialized");
        }
        try {
            const fileHandle = await this.rootHandle.getFileHandle(filename, { create: true });
            const writable = await fileHandle.createWritable();
            await writable.write(content);
            await writable.close();
            console.log(`[OPFS] Wrote ${filename} (${content.length} bytes)`);
        } catch (e) {
            console.error(`[OPFS] Write ${filename} failed:`, e);
            throw e;
        }
    },

    // Check if file exists
    async exists(filename) {
        if (!this.rootHandle) {
            return false;
        }
        try {
            await this.rootHandle.getFileHandle(filename);
            return true;
        } catch {
            return false;
        }
    }
};

// Export for .NET interop
window.DOTNET_WASM_OPFS = DOTNET_WASM_OPFS;

// Also expose at global scope for dotnetwasm
globalThis.DOTNET_WASM_OPFS = DOTNET_WASM_OPFS;
