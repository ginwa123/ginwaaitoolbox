namespace Desktop.ViewModels;

using System.Collections.ObjectModel;
using System.IO;
using IOPath = System.IO.Path;
using System.Text.Json;
using System.Text.Json.Serialization;
using Desktop.Services;

/// <summary>
/// WorkspaceStore - Manages workspace persistence and selection.
/// Workspaces are folders that become the session_dir for nalarcore.
/// Uses native filesystem (native) or OPFS (WASM) for persistence.
/// </summary>
public class WorkspaceStore
{
    private readonly string _configDir;
    private readonly string _workspacesFile;
    private const string WORKSPCAE_FILENAME = "workspaces.json";
    
    public ObservableCollection<Workspace> Workspaces { get; } = [];
    
    public Workspace? SelectedWorkspace { get; private set; }
    
    public event EventHandler<Workspace?>? OnWorkspaceChanged;
    
    /// <summary>
    /// Creates a WorkspaceStore with default config directory (~/.config/nalar)
    /// </summary>
    public WorkspaceStore()
    {
        // Initialize FS detection first
        FileSystemService.Init();
        
        if (FileSystemService.IsWasm)
        {
            _configDir = "/nalar_data";
            _workspacesFile = WORKSPCAE_FILENAME;
            // Async init will be done separately
        }
        else
        {
            _configDir = GetDefaultConfigDir();
            _workspacesFile = GetWorkspacesFilePath(_configDir);
            EnsureConfigDir();
            LoadSync();
        }
    }
    
    /// <summary>
    /// Initialize async (call after constructor, required for WASM).
    /// </summary>
    public async Task InitializeAsync()
    {
        if (FileSystemService.IsWasm)
        {
            await WasmStorageService.InitAsync();
            await LoadAsync();
        }
    }
    
    /// <summary>
    /// Creates a WorkspaceStore with custom paths (for testing)
    /// </summary>
    internal WorkspaceStore(string configDir, string workspacesFile)
    {
        _configDir = configDir;
        _workspacesFile = workspacesFile;
        EnsureConfigDir();
        LoadSync();
    }
    
    private static string GetDefaultConfigDir()
    {
        var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        return Path.Combine(home, ".config", "nalar");
    }
    
    private static string GetWorkspacesFilePath(string configDir)
    {
        return Path.Combine(configDir, WORKSPCAE_FILENAME);
    }
    
    private void EnsureConfigDir()
    {
        if (!Directory.Exists(_configDir))
        {
            Directory.CreateDirectory(_configDir);
        }
    }
    
    /// <summary>
    /// Add a new workspace (folder path becomes session_dir)
    /// </summary>
    public async Task<Workspace?> AddWorkspaceAsync(string path)
    {
        // Check if already exists
        var existing = Workspaces.FirstOrDefault(w => 
            w.Path.Equals(path, StringComparison.OrdinalIgnoreCase));
        
        if (existing != null)
        {
            return existing;
        }
        
        // Create new workspace
        var workspace = CreateWorkspace(path);
        Workspaces.Add(workspace);
        await SaveAsync();
        
        return workspace;
    }
    
    /// <summary>
    /// Add a new workspace (sync version for backward compatibility)
    /// </summary>
    public Workspace? AddWorkspace(string path)
    {
        // Check if already exists
        var existing = Workspaces.FirstOrDefault(w => 
            w.Path.Equals(path, StringComparison.OrdinalIgnoreCase));
        
        if (existing != null)
        {
            return existing;
        }
        
        // Create new workspace
        var workspace = CreateWorkspace(path);
        Workspaces.Add(workspace);
        SaveSync();
        
        return workspace;
    }
    
    /// <summary>
    /// Remove a workspace
    /// </summary>
    public async Task RemoveWorkspaceAsync(Workspace workspace)
    {
        Workspaces.Remove(workspace);
        
        if (SelectedWorkspace == workspace)
        {
            SelectedWorkspace = null;
            OnWorkspaceChanged?.Invoke(this, null);
        }
        
        await SaveAsync();
    }
    
    /// <summary>
    /// Remove a workspace (sync version)
    /// </summary>
    public void RemoveWorkspace(Workspace workspace)
    {
        Workspaces.Remove(workspace);
        
        if (SelectedWorkspace == workspace)
        {
            SelectedWorkspace = null;
            OnWorkspaceChanged?.Invoke(this, null);
        }
        
        SaveSync();
    }
    
    /// <summary>
    /// Select a workspace as the active session_dir
    /// </summary>
    public void SelectWorkspace(Workspace? workspace)
    {
        SelectedWorkspace = workspace;
        OnWorkspaceChanged?.Invoke(this, workspace);
        
        // Save selection immediately
        if (FileSystemService.IsWasm)
        {
            _ = SaveAsync(); // Fire and forget for selection changes
        }
        else
        {
            SaveSync();
        }
    }
    
    /// <summary>
    /// Get the current session_dir path, or null if none selected
    /// </summary>
    public string? GetSessionDir()
    {
        return SelectedWorkspace?.Path;
    }
    
    /// <summary>
    /// Create session directory structure if it doesn't exist
    /// </summary>
    public void EnsureSessionStructure(string sessionDir)
    {
        if (!Directory.Exists(sessionDir))
        {
            Directory.CreateDirectory(sessionDir);
        }
        
        // Create standard subdirectories
        var dirs = new[] { ".nalar", "src", "docs" };
        foreach (var dir in dirs)
        {
            var subPath = Path.Combine(sessionDir, dir);
            if (!Directory.Exists(subPath))
            {
                Directory.CreateDirectory(subPath);
            }
        }
    }
    
    // ===== Testable Static Functions =====
    
    /// <summary>
    /// Create a new workspace from a path. Static for easy testing.
    /// </summary>
    public static Workspace CreateWorkspace(string path)
    {
        return new Workspace
        {
            Id = Guid.NewGuid().ToString(),
            Name = GetDisplayName(path),
            Path = path,
            CreatedAt = DateTime.UtcNow
        };
    }
    
    /// <summary>
    /// Get display name from path. Static for easy testing.
    /// </summary>
    public static string GetDisplayName(string path)
    {
        if (string.IsNullOrEmpty(path))
            return string.Empty;
            
        // Normalize path separators for cross-platform
        var normalized = path.Replace("\\", "/");
        
        // Get the filename (last segment)
        var name = IOPath.GetFileName(normalized);
        
        // If no filename (root path), return the full normalized path
        if (string.IsNullOrEmpty(name))
        {
            name = normalized.TrimEnd('/');
            if (string.IsNullOrEmpty(name))
                name = "/";
        }
        
        return name;
    }
    
    /// <summary>
    /// Serialize workspace data to JSON. Static for easy testing.
    /// </summary>
    public static string SerializeWorkspaces(List<Workspace> workspaces, string? selectedId)
    {
        var data = new WorkspaceStoreData
        {
            Workspaces = workspaces,
            SelectedId = selectedId
        };
        return JsonSerializer.Serialize(data, WorkspaceContext.Default.WorkspaceStoreData);
    }
    
    /// <summary>
    /// Deserialize workspace data from JSON. Static for easy testing.
    /// </summary>
    public static WorkspaceDataResult? DeserializeWorkspaces(string json)
    {
        if (string.IsNullOrEmpty(json))
            return null;
            
        var data = JsonSerializer.Deserialize(json, WorkspaceContext.Default.WorkspaceStoreData);
        return data == null ? null : new WorkspaceDataResult(data.Workspaces, data.SelectedId);
    }
    
    // ===== Native FileSystem (sync) =====
    
    private void LoadSync()
    {
        Workspaces.Clear();
            
        if (!File.Exists(_workspacesFile))
        {
            return;
        }
        
        try
        {
            var json = File.ReadAllText(_workspacesFile);
            LoadFromJson(json);
        }
        catch (Exception ex)
        {
            System.Diagnostics.Debug.WriteLine($"Failed to load workspaces: {ex.Message}");
        }
    }
    
    private void SaveSync()
    {
        try
        {
            var json = SerializeWorkspaces(Workspaces.ToList(), SelectedWorkspace?.Id);
            File.WriteAllText(_workspacesFile, json);
            System.Diagnostics.Debug.WriteLine($"[WorkspaceStore] Saved {Workspaces.Count} workspaces to {_workspacesFile}");
        }
        catch (Exception ex)
        {
            System.Diagnostics.Debug.WriteLine($"Failed to save workspaces: {ex.Message}");
        }
    }
    
    // ===== WASM OPFS (async) =====
    
    private async Task LoadAsync()
    {
        Workspaces.Clear();
            
        try
        {
            var json = await WasmStorageService.ReadFileAsync(WORKSPCAE_FILENAME);
            if (!string.IsNullOrEmpty(json))
            {
                LoadFromJson(json);
                System.Diagnostics.Debug.WriteLine($"[WorkspaceStore] Loaded {Workspaces.Count} workspaces from OPFS");
            }
            else
            {
                System.Diagnostics.Debug.WriteLine("[WorkspaceStore] No existing workspace file in OPFS");
            }
        }
        catch (Exception ex)
        {
            System.Diagnostics.Debug.WriteLine($"Failed to load workspaces from OPFS: {ex.Message}");
        }
    }
    
    private async Task SaveAsync()
    {
        try
        {
            var json = SerializeWorkspaces(Workspaces.ToList(), SelectedWorkspace?.Id);
            await WasmStorageService.WriteFileAsync(WORKSPCAE_FILENAME, json);
            System.Diagnostics.Debug.WriteLine($"[WorkspaceStore] Saved {Workspaces.Count} workspaces to OPFS");
        }
        catch (Exception ex)
        {
            System.Diagnostics.Debug.WriteLine($"Failed to save workspaces to OPFS: {ex.Message}");
        }
    }
    
    // ===== Common JSON parsing =====
    
    private void LoadFromJson(string json)
    {
        var result = DeserializeWorkspaces(json);
        if (result == null) return;
        
        foreach (var w in result.Workspaces)
        {
            // In native, validate path exists; in WASM, accept all
            if (!FileSystemService.IsWasm && !string.IsNullOrEmpty(w.Path) && !Directory.Exists(w.Path))
            {
                continue;
            }
            Workspaces.Add(w);
        }
        
        // Restore selected workspace
        if (!string.IsNullOrEmpty(result.SelectedId))
        {
            SelectedWorkspace = Workspaces.FirstOrDefault(w => w.Id == result.SelectedId);
        }
    }
}

public class Workspace
{
    public string Id { get; set; } = string.Empty;
    public string Name { get; set; } = string.Empty;
    public string Path { get; set; } = string.Empty;
    public DateTime CreatedAt { get; set; }
}

/// <summary>
/// Result of deserializing workspace data.
/// </summary>
public record WorkspaceDataResult(List<Workspace> Workspaces, string? SelectedId);

[JsonSerializable(typeof(Workspace))]
[JsonSerializable(typeof(WorkspaceStoreData))]
[JsonSerializable(typeof(List<Workspace>))]
internal partial class WorkspaceContext : JsonSerializerContext
{
}

internal class WorkspaceStoreData
{
    public List<Workspace> Workspaces { get; set; } = [];
    public string? SelectedId { get; set; }
}
