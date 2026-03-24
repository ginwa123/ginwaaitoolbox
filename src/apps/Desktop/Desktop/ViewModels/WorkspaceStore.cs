namespace Desktop.ViewModels;

using System.Collections.ObjectModel;
using System.IO;
using System.Text.Json;
using System.Text.Json.Serialization;

/// <summary>
/// WorkspaceStore - Manages workspace persistence and selection.
/// Workspaces are folders that become the session_dir for nalarcore.
/// </summary>
public class WorkspaceStore
{
    private readonly string _configDir;
    private readonly string _workspacesFile;
    
    public ObservableCollection<Workspace> Workspaces { get; } = [];
    
    public Workspace? SelectedWorkspace { get; private set; }
    
    public event EventHandler<Workspace?>? OnWorkspaceChanged;
    
    /// <summary>
    /// Creates a WorkspaceStore with default config directory (~/.config/nalar)
    /// </summary>
    public WorkspaceStore() : this(GetDefaultConfigDir(), GetDefaultWorkspacesFile())
    {
    }
    
    /// <summary>
    /// Creates a WorkspaceStore with custom paths (for testing)
    /// </summary>
    internal WorkspaceStore(string configDir, string workspacesFile)
    {
        _configDir = configDir;
        _workspacesFile = workspacesFile;
        EnsureConfigDir();
        Load();
    }
    
    private static string GetDefaultConfigDir()
    {
        var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        return Path.Combine(home, ".config", "nalar");
    }
    
    private static string GetDefaultWorkspacesFile()
    {
        return Path.Combine(GetDefaultConfigDir(), "workspaces.json");
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
        var workspace = new Workspace
        {
            Id = Guid.NewGuid().ToString(),
            Name = GetDisplayName(path),
            Path = path,
            CreatedAt = DateTime.UtcNow
        };
        
        Workspaces.Add(workspace);
        Save();
        
        return workspace;
    }
    
    /// <summary>
    /// Remove a workspace
    /// </summary>
    public void RemoveWorkspace(Workspace workspace)
    {
        Workspaces.Remove(workspace);
        
        if (SelectedWorkspace == workspace)
        {
            SelectedWorkspace = null;
            OnWorkspaceChanged?.Invoke(this, null);
        }
        
        Save();
    }
    
    /// <summary>
    /// Select a workspace as the active session_dir
    /// </summary>
    public void SelectWorkspace(Workspace? workspace)
    {
        SelectedWorkspace = workspace;
        OnWorkspaceChanged?.Invoke(this, workspace);
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
    
    private string GetDisplayName(string path)
    {
        var name = Path.GetFileName(path);
        if (string.IsNullOrEmpty(name))
        {
            // For root paths like /home/user, show the full path
            name = path.Replace("\\", "/").TrimEnd('/');
        }
        return name;
    }
    
    private void Load()
    {
        Workspaces.Clear();
        
        if (!File.Exists(_workspacesFile))
        {
            return;
        }
        
        try
        {
            var json = File.ReadAllText(_workspacesFile);
            var data = JsonSerializer.Deserialize(json, WorkspaceContext.Default.WorkspaceStoreData);
            
            if (data?.Workspaces != null)
            {
                foreach (var w in data.Workspaces)
                {
                    // Validate path still exists
                    if (Directory.Exists(w.Path))
                    {
                        Workspaces.Add(w);
                    }
                }
            }
        }
        catch (Exception ex)
        {
            System.Diagnostics.Debug.WriteLine($"Failed to load workspaces: {ex.Message}");
        }
    }
    
    public void Save()
    {
        try
        {
            var data = new WorkspaceStoreData
            {
                Workspaces = Workspaces.ToList(),
                SelectedId = SelectedWorkspace?.Id
            };
            
            var json = JsonSerializer.Serialize(data, WorkspaceContext.Default);
            
            File.WriteAllText(_workspacesFile, json);
        }
        catch (Exception ex)
        {
            System.Diagnostics.Debug.WriteLine($"Failed to save workspaces: {ex.Message}");
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
