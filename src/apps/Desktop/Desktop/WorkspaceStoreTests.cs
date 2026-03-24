namespace Desktop.ViewModels;

using IOPath = System.IO.Path;

/// <summary>
/// TDD Tests for WorkspaceStore - Tests static/testable functions.
/// </summary>
public class WorkspaceStoreTests
{
    // ===== GetDisplayName Tests =====
    
    [Fact]
    public void GetDisplayName_ReturnsFileName_ForNormalPath()
    {
        // Arrange
        var path = "/home/user/projects/myapp";
        
        // Act
        var name = WorkspaceStore.GetDisplayName(path);
        
        // Assert
        Assert.Equal("myapp", name);
    }
    
    [Fact]
    public void GetDisplayName_ReturnsFullPath_ForRootPath()
    {
        // Arrange
        var path = "/home/user";
        
        // Act
        var name = WorkspaceStore.GetDisplayName(path);
        
        // Assert
        Assert.Equal("/home/user", name);
    }
    
    [Fact]
    public void GetDisplayName_ReturnsFullPath_ForEmptyFileName()
    {
        // Arrange
        var path = "/";
        
        // Act
        var name = WorkspaceStore.GetDisplayName(path);
        
        // Assert
        Assert.Equal("/", name);
    }
    
    [Fact]
    public void GetDisplayName_HandlesWindowsPath()
    {
        // Arrange
        var path = "C:\\Users\\developer\\workspace";
        
        // Act
        var name = WorkspaceStore.GetDisplayName(path);
        
        // Assert
        Assert.Equal("workspace", name);
    }
    
    // ===== CreateWorkspace Tests =====
    
    [Fact]
    public void CreateWorkspace_SetsAllProperties()
    {
        // Arrange
        var path = "/home/user/projects/test";
        
        // Act
        var workspace = WorkspaceStore.CreateWorkspace(path);
        
        // Assert
        Assert.NotEmpty(workspace.Id);
        Assert.Equal("test", workspace.Name);
        Assert.Equal(path, workspace.Path);
        Assert.NotEqual(default, workspace.CreatedAt);
    }
    
    [Fact]
    public void CreateWorkspace_GeneratesUniqueIds()
    {
        // Arrange & Act
        var ws1 = WorkspaceStore.CreateWorkspace("/path/one");
        var ws2 = WorkspaceStore.CreateWorkspace("/path/two");
        
        // Assert
        Assert.NotEqual(ws1.Id, ws2.Id);
    }
    
    [Fact]
    public void CreateWorkspace_SetsCorrectName_ForRootPath()
    {
        // Arrange
        var path = "/home/user";
        
        // Act
        var workspace = WorkspaceStore.CreateWorkspace(path);
        
        // Assert
        Assert.Equal("/home/user", workspace.Name);
        Assert.Equal(path, workspace.Path);
    }
    
    // ===== SerializeWorkspaces Tests =====
    
    [Fact]
    public void SerializeWorkspaces_SerializesEmptyList()
    {
        // Arrange
        var workspaces = new List<Workspace>();
        
        // Act
        var json = WorkspaceStore.SerializeWorkspaces(workspaces, null);
        
        // Assert
        Assert.Contains("\"Workspaces\":[]", json);
        Assert.Contains("\"SelectedId\":null", json);
    }
    
    [Fact]
    public void SerializeWorkspaces_SerializesSingleWorkspace()
    {
        // Arrange
        var workspaces = new List<Workspace>
        {
            new Workspace { Id = "test-id", Name = "TestWorkspace", Path = "/test/path", CreatedAt = DateTime.Parse("2024-01-01") }
        };
        
        // Act
        var json = WorkspaceStore.SerializeWorkspaces(workspaces, "test-id");
        
        // Assert
        Assert.Contains("\"test-id\"", json);
        Assert.Contains("\"TestWorkspace\"", json);
        Assert.Contains("\"/test/path\"", json);
    }
    
    [Fact]
    public void SerializeWorkspaces_IncludesSelectedId()
    {
        // Arrange
        var workspaces = new List<Workspace>
        {
            new Workspace { Id = "ws-1", Name = "Workspace1", Path = "/path1" },
            new Workspace { Id = "ws-2", Name = "Workspace2", Path = "/path2" }
        };
        
        // Act
        var json = WorkspaceStore.SerializeWorkspaces(workspaces, "ws-2");
        
        // Assert
        Assert.Contains("\"SelectedId\":\"ws-2\"", json);
    }
    
    [Fact]
    public void SerializeWorkspaces_SerializesMultipleWorkspaces()
    {
        // Arrange
        var workspaces = new List<Workspace>
        {
            new Workspace { Id = "1", Name = "A", Path = "/a" },
            new Workspace { Id = "2", Name = "B", Path = "/b" },
            new Workspace { Id = "3", Name = "C", Path = "/c" }
        };
        
        // Act
        var json = WorkspaceStore.SerializeWorkspaces(workspaces, "2");
        
        // Assert
        Assert.Contains("\"1\"", json);
        Assert.Contains("\"2\"", json);
        Assert.Contains("\"3\"", json);
        Assert.Contains("\"A\"", json);
        Assert.Contains("\"B\"", json);
        Assert.Contains("\"C\"", json);
    }
    
    // ===== DeserializeWorkspaces Tests =====
    
    [Fact]
    public void DeserializeWorkspaces_ReturnsNull_ForEmptyJson()
    {
        // Act
        var result = WorkspaceStore.DeserializeWorkspaces("");
        
        // Assert
        Assert.Null(result);
    }
    
    [Fact]
    public void DeserializeWorkspaces_ReturnsNull_ForNullJson()
    {
        // Act
        var result = WorkspaceStore.DeserializeWorkspaces(null!);
        
        // Assert
        Assert.Null(result);
    }
    
    [Fact]
    public void DeserializeWorkspaces_DeserializesEmptyWorkspaces()
    {
        // Arrange
        var json = "{\"Workspaces\":[],\"SelectedId\":null}";
        
        // Act
        var result = WorkspaceStore.DeserializeWorkspaces(json);
        
        // Assert
        Assert.NotNull(result);
        Assert.Empty(result.Workspaces);
        Assert.Null(result.SelectedId);
    }
    
    [Fact]
    public void DeserializeWorkspaces_DeserializesSingleWorkspace()
    {
        // Arrange
        var json = "{\"Workspaces\":[{\"Id\":\"ws-1\",\"Name\":\"Test\",\"Path\":\"/test\",\"CreatedAt\":\"2024-01-01T00:00:00Z\"}],\"SelectedId\":\"ws-1\"}";
        
        // Act
        var result = WorkspaceStore.DeserializeWorkspaces(json);
        
        // Assert
        Assert.NotNull(result);
        Assert.Single(result.Workspaces);
        Assert.Equal("ws-1", result.Workspaces[0].Id);
        Assert.Equal("Test", result.Workspaces[0].Name);
        Assert.Equal("/test", result.Workspaces[0].Path);
        Assert.Equal("ws-1", result.SelectedId);
    }
    
    [Fact]
    public void DeserializeWorkspaces_DeserializesMultipleWorkspaces()
    {
        // Arrange
        var json = @"{""Workspaces"":[
            {""Id"":""1"",""Name"":""A"",""Path"":""/a"",""CreatedAt"":""2024-01-01T00:00:00Z""},
            {""Id"":""2"",""Name"":""B"",""Path"":""/b"",""CreatedAt"":""2024-01-02T00:00:00Z""}
        ],""SelectedId"":""2""}";
        
        // Act
        var result = WorkspaceStore.DeserializeWorkspaces(json);
        
        // Assert
        Assert.NotNull(result);
        Assert.Equal(2, result.Workspaces.Count);
        Assert.Equal("1", result.Workspaces[0].Id);
        Assert.Equal("2", result.Workspaces[1].Id);
        Assert.Equal("2", result.SelectedId);
    }
    
    [Fact]
    public void DeserializeWorkspaces_RoundTrips_SerializeDeserialize()
    {
        // Arrange
        var original = new List<Workspace>
        {
            new Workspace { Id = "id-1", Name = "Workspace One", Path = "/path/one" },
            new Workspace { Id = "id-2", Name = "Workspace Two", Path = "/path/two" }
        };
        
        // Act
        var json = WorkspaceStore.SerializeWorkspaces(original, "id-2");
        var result = WorkspaceStore.DeserializeWorkspaces(json);
        
        // Assert
        Assert.NotNull(result);
        Assert.Equal(2, result.Workspaces.Count);
        Assert.Equal("id-1", result.Workspaces[0].Id);
        Assert.Equal("Workspace One", result.Workspaces[0].Name);
        Assert.Equal("/path/one", result.Workspaces[0].Path);
        Assert.Equal("id-2", result.Workspaces[1].Id);
        Assert.Equal("id-2", result.SelectedId);
    }
    
    // ===== Workspace Class Tests =====
    
    [Fact]
    public void Workspace_DefaultValues()
    {
        // Act
        var workspace = new Workspace();
        
        // Assert
        Assert.Equal(string.Empty, workspace.Id);
        Assert.Equal(string.Empty, workspace.Name);
        Assert.Equal(string.Empty, workspace.Path);
        Assert.Equal(default, workspace.CreatedAt);
    }
    
    [Fact]
    public void Workspace_CanSetProperties()
    {
        // Arrange
        var id = "test-id";
        var name = "My Workspace";
        var path = "/home/user/workspace";
        var created = DateTime.Parse("2024-06-15");
        
        // Act
        var workspace = new Workspace
        {
            Id = id,
            Name = name,
            Path = path,
            CreatedAt = created
        };
        
        // Assert
        Assert.Equal(id, workspace.Id);
        Assert.Equal(name, workspace.Name);
        Assert.Equal(path, workspace.Path);
        Assert.Equal(created, workspace.CreatedAt);
    }
    
    // ===== WorkspaceDataResult Tests =====
    
    [Fact]
    public void WorkspaceDataResult_Record_Works()
    {
        // Arrange
        var workspaces = new List<Workspace> { new Workspace { Id = "1" } };
        
        // Act
        var result = new WorkspaceDataResult(workspaces, "1");
        
        // Assert
        Assert.Single(result.Workspaces);
        Assert.Equal("1", result.SelectedId);
    }
}
