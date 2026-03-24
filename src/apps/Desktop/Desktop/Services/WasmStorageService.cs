namespace Desktop.Services;

using System.Runtime.InteropServices.JavaScript;

/// <summary>
/// WASM storage using Origin Private File System (OPFS).
/// Provides real filesystem access in browser WASM.
/// </summary>
public static partial class WasmStorageService
{
    private static bool _initialized = false;
    private static string? _error;

    /// <summary>
    /// Initialize OPFS. Call this before any read/write operations.
    /// </summary>
    public static async Task InitAsync()
    {
        if (_initialized) return;

        try
        {
            var result = await InitOpfsAsync();
            _initialized = result;
            _error = result ? null : "OPFS init returned false";
            Console.WriteLine($"[WasmStorage] OPFS initialized: {_initialized}");
        }
        catch (Exception ex)
        {
            _initialized = false;
            _error = ex.Message;
            Console.WriteLine($"[WasmStorage] OPFS init failed: {ex.Message}");
        }
    }

    /// <summary>
    /// Check if OPFS is initialized.
    /// </summary>
    public static bool IsInitialized => _initialized;

    /// <summary>
    /// Get last error message.
    /// </summary>
    public static string? LastError => _error;

    /// <summary>
    /// Read a file from OPFS.
    /// </summary>
    public static async Task<string?> ReadFileAsync(string filename)
    {
        if (!_initialized)
        {
            await InitAsync();
        }

        if (!_initialized)
        {
            Console.WriteLine($"[WasmStorage] Not initialized, cannot read {filename}");
            return null;
        }

        try
        {
            return await ReadOpfsFileAsync(filename);
        }
        catch (Exception ex)
        {
            Console.WriteLine($"[WasmStorage] Read {filename} failed: {ex.Message}");
            return null;
        }
    }

    /// <summary>
    /// Write a file to OPFS.
    /// </summary>
    public static async Task WriteFileAsync(string filename, string content)
    {
        if (!_initialized)
        {
            await InitAsync();
        }

        if (!_initialized)
        {
            Console.WriteLine($"[WasmStorage] Not initialized, cannot write {filename}");
            return;
        }

        try
        {
            await WriteOpfsFileAsync(filename, content);
            Console.WriteLine($"[WasmStorage] Wrote {filename} ({content.Length} bytes)");
        }
        catch (Exception ex)
        {
            Console.WriteLine($"[WasmStorage] Write {filename} failed: {ex.Message}");
        }
    }

    /// <summary>
    /// Check if a file exists in OPFS.
    /// </summary>
    public static async Task<bool> FileExistsAsync(string filename)
    {
        if (!_initialized)
        {
            await InitAsync();
        }

        if (!_initialized) return false;

        try
        {
            return await FileExistsOpfsAsync(filename);
        }
        catch
        {
            return false;
        }
    }

    // ===== JS Import declarations (call window.DOTNET_WASM_OPFS) =====

    [JSImport("DOTNET_WASM_OPFS.init", "dotnetwasm")]
    [return: JSMarshalAs<JSType.Promise<JSType.Boolean>>]
    private static partial Task<bool> InitOpfsAsync();

    [JSImport("DOTNET_WASM_OPFS.readFile", "dotnetwasm")]
    [return: JSMarshalAs<JSType.Promise<JSType.String>>]
    private static partial Task<string?> ReadOpfsFileAsync(string filename);

    [JSImport("DOTNET_WASM_OPFS.writeFile", "dotnetwasm")]
    [return: JSMarshalAs<JSType.Promise<JSType.Void>>]
    private static partial Task WriteOpfsFileAsync(string filename, string content);

    [JSImport("DOTNET_WASM_OPFS.exists", "dotnetwasm")]
    [return: JSMarshalAs<JSType.Promise<JSType.Boolean>>]
    private static partial Task<bool> FileExistsOpfsAsync(string filename);
}
