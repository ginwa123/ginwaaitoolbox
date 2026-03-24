namespace Desktop.Services;

using System.Runtime.InteropServices;
using IOPath = System.IO.Path;

/// <summary>
/// Public service for file system operations.
/// Falls back to WASM-compatible file picking when running in browser.
/// </summary>
public static class FileSystemService
{
    /// <summary>
    /// Whether we're running in browser WASM (no file system access).
    /// </summary>
    public static bool IsWasm { get; private set; }

    /// <summary>
    /// User-selected directory path (for WASM picker).
    /// </summary>
    public static string? SelectedPath { get; set; }

    /// <summary>
    /// Initialize WASM detection. Call this from UI code on startup.
    /// </summary>
    public static void Init()
    {
#if __WASM__
        IsWasm = true;
#else
        IsWasm = RuntimeInformation.IsOSPlatform(OSPlatform.Create("browser"));
#endif
    }

    /// <summary>
    /// For WASM: set the picked folder path.
    /// </summary>
    public static void SetSelectedPath(string path)
    {
        SelectedPath = path;
    }

    /// <summary>
    /// Load directory contents as a list of FileSystemItem.
    /// Returns special items for WASM or errors.
    /// </summary>
    public static List<FileSystemItem> ListDirectory(string path)
    {
        var items = new List<FileSystemItem>();

        // Check if running in WASM - no file system access
        if (IsWasm)
        {
            return ListDirectoryWasm(path);
        }

        if (string.IsNullOrEmpty(path) || !Directory.Exists(path))
        {
            items.Add(new FileSystemItem { Name = "[PATH NOT FOUND]", IsDirectory = true, FullPath = path, IsDisabled = true });
            return items;
        }

        try
        {
            // Get directories first
            var dirs = Directory.GetDirectories(path);
            Array.Sort(dirs, StringComparer.OrdinalIgnoreCase);

            foreach (var dir in dirs)
            {
                var name = IOPath.GetFileName(dir);
                // Skip hidden/system directories
                if (name.StartsWith(".")) continue;

                items.Add(new FileSystemItem
                {
                    Name = name,
                    IsDirectory = true,
                    FullPath = dir,
                    HasChildren = HasSubDirectories(dir)
                });
            }

            // Then get files (limited to common workspace files)
            var files = Directory.GetFiles(path);
            Array.Sort(files, StringComparer.OrdinalIgnoreCase);

            foreach (var file in files.Take(50)) // Limit file display
            {
                var name = IOPath.GetFileName(file);
                if (name.StartsWith(".")) continue;

                items.Add(new FileSystemItem
                {
                    Name = name,
                    IsDirectory = false,
                    FullPath = file
                });
            }

            if (items.Count == 0)
            {
                items.Add(new FileSystemItem { Name = "[EMPTY]", IsDirectory = true, FullPath = path, IsDisabled = true });
            }
        }
        catch (UnauthorizedAccessException)
        {
            items.Add(new FileSystemItem { Name = "[ACCESS DENIED]", IsDirectory = true, FullPath = path, IsDisabled = true });
        }
        catch (Exception ex)
        {
            items.Add(new FileSystemItem { Name = $"[ERROR: {ex.Message}]", IsDirectory = true, FullPath = path, IsDisabled = true });
        }

        return items;
    }

    /// <summary>
    /// WASM-compatible directory listing using browser APIs.
    /// </summary>
    private static List<FileSystemItem> ListDirectoryWasm(string path)
    {
        var items = new List<FileSystemItem>();

        // Use selected path if provided
        var targetPath = !string.IsNullOrEmpty(path) ? path : SelectedPath;

        if (string.IsNullOrEmpty(targetPath))
        {
            // Show browser-specific instructions
            items.Add(new FileSystemItem { Name = "[CLICK 'PICK FOLDER' BUTTON]", IsDirectory = true, FullPath = "", IsDisabled = true });
            items.Add(new FileSystemItem { Name = "[TO SELECT WORKSPACE]", IsDirectory = true, FullPath = "", IsDisabled = true });
            return items;
        }

        // In WASM, we can't list arbitrary directories - show message
        items.Add(new FileSystemItem { Name = $"[WORKSPACE: {IOPath.GetFileName(targetPath)}]", IsDirectory = true, FullPath = targetPath, IsDisabled = false });
        items.Add(new FileSystemItem { Name = "[BROWSER: NO DIRECTORY LISTING]", IsDirectory = true, FullPath = targetPath, IsDisabled = true });
        return items;
    }

    /// <summary>
    /// Check if a directory has subdirectories.
    /// </summary>
    public static bool HasSubDirectories(string path)
    {
        if (IsWasm) return false;

        try
        {
            return Directory.GetDirectories(path).Length > 0;
        }
        catch
        {
            return false;
        }
    }
}

public class FileSystemItem
{
    public string Name { get; set; } = string.Empty;
    public bool IsDirectory { get; set; }
    public string FullPath { get; set; } = string.Empty;
    public bool HasChildren { get; set; }
    public bool IsExpanded { get; set; }
    public bool IsDisabled { get; set; }
    public FileSystemItem? Parent { get; set; }
    public List<FileSystemItem> Children { get; set; } = new();
}
