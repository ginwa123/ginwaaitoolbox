using System.IO;
using IOPath = System.IO.Path;

namespace Desktop.TestRunner;

public class FileSystemItem
{
    public string Name { get; set; } = string.Empty;
    public bool IsDirectory { get; set; }
    public string FullPath { get; set; } = string.Empty;
    public bool HasChildren { get; set; }
    public bool IsExpanded { get; set; }
    public bool IsDisabled { get; set; }
}

public class Workspace
{
    public string Id { get; set; } = string.Empty;
    public string Name { get; set; } = string.Empty;
    public string Path { get; set; } = string.Empty;
    public DateTime CreatedAt { get; set; }
}

// Replicated from WorkspaceStore for testing
public static class WorkspaceStoreTests
{
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
    
    public static string GetDisplayName(string path)
    {
        var name = IOPath.GetFileName(path);
        if (string.IsNullOrEmpty(name))
        {
            name = path.Replace("\\", "/").TrimEnd('/');
        }
        return name;
    }
}

// Replicated FileSystemService for testing
public static class FileSystemService
{
    public static List<FileSystemItem> ListDirectory(string path)
    {
        var items = new List<FileSystemItem>();

        if (string.IsNullOrEmpty(path) || !Directory.Exists(path))
        {
            items.Add(new FileSystemItem { Name = "[PATH NOT FOUND]", IsDirectory = true, FullPath = path, IsDisabled = true });
            return items;
        }

        try
        {
            var dirs = Directory.GetDirectories(path);
            Array.Sort(dirs, StringComparer.OrdinalIgnoreCase);

            foreach (var dir in dirs)
            {
                var name = IOPath.GetFileName(dir);
                if (name.StartsWith(".")) continue;

                items.Add(new FileSystemItem
                {
                    Name = name,
                    IsDirectory = true,
                    FullPath = dir,
                    HasChildren = HasSubDirectories(dir)
                });
            }

            var files = Directory.GetFiles(path);
            Array.Sort(files, StringComparer.OrdinalIgnoreCase);

            foreach (var file in files.Take(50))
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
        catch
        {
            items.Add(new FileSystemItem { Name = "[ERROR]", IsDirectory = true, FullPath = path, IsDisabled = true });
        }

        return items;
    }

    public static bool HasSubDirectories(string path)
    {
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

class Program
{
    static int passed = 0, failed = 0;
    static List<string> errors = [];

    static void Assert(bool condition, string message)
    {
        if (condition) { passed++; Console.WriteLine($"    ✅ {message}"); }
        else { failed++; errors.Add(message); Console.WriteLine($"    ❌ {message}"); }
    }

    static void AssertEq<T>(T expected, T actual, string message)
    {
        var eq = (expected?.Equals(actual) == true) || (expected == null && actual == null);
        if (eq) { passed++; Console.WriteLine($"    ✅ {message} (expected: {expected}, got: {actual})"); }
        else { failed++; errors.Add($"{message} (expected: {expected}, got: {actual})"); Console.WriteLine($"    ❌ {message} (expected: {expected}, got: {actual})"); }
    }

    static string NewTestDir()
    {
        var d = IOPath.Combine(IOPath.GetTempPath(), $"nalar_test_{Guid.NewGuid():N}");
        Directory.CreateDirectory(d);
        return d;
    }

    static void Main(string[] args)
    {
        Console.WriteLine("╔══════════════════════════════════════════╗");
        Console.WriteLine("║    Unit Tests for Desktop App           ║");
        Console.WriteLine("╚══════════════════════════════════════════╝");

        RunFileSystemServiceTests();
        RunWorkspaceStoreTests();

        Console.WriteLine("\n══════════════════════════════════════════");
        Console.WriteLine($"  ✅ Passed: {passed}");
        Console.WriteLine($"  ❌ Failed: {failed}");
        
        if (failed > 0)
        {
            Console.WriteLine("\n  Failed tests:");
            foreach (var err in errors) Console.WriteLine($"    - {err}");
            Environment.Exit(1);
        }
        else
        {
            Console.WriteLine("\n  🎉 All tests passed!");
        }
    }

    static void RunFileSystemServiceTests()
    {
        Console.WriteLine("\n=== FileSystemService Tests ===");

        // Test 1: Invalid path
        Console.WriteLine("\n[Test 1] ListDirectory with invalid path");
        var items1 = FileSystemService.ListDirectory("/nonexistent/path/12345");
        AssertEq(1, items1.Count, "Should return 1 item");
        AssertEq("[PATH NOT FOUND]", items1[0].Name, "Name");
        Assert(items1[0].IsDirectory, "IsDirectory");
        Assert(items1[0].IsDisabled, "IsDisabled");

        // Test 2: Empty directory
        Console.WriteLine("\n[Test 2] ListDirectory with empty directory");
        var dir2 = NewTestDir();
        try
        {
            var items2 = FileSystemService.ListDirectory(dir2);
            AssertEq(1, items2.Count, "Should return 1 item");
            AssertEq("[EMPTY]", items2[0].Name, "Name");
        }
        finally { Directory.Delete(dir2, true); }

        // Test 3: Directory with subdirs and files
        Console.WriteLine("\n[Test 3] ListDirectory with content");
        var dir3 = NewTestDir();
        try
        {
            Directory.CreateDirectory(IOPath.Combine(dir3, "subdir"));
            File.WriteAllText(IOPath.Combine(dir3, "test.txt"), "hello");
            var items3 = FileSystemService.ListDirectory(dir3);
            AssertEq(2, items3.Count, "Should return 2 items");
            Assert(items3.Any(i => i.Name == "subdir" && i.IsDirectory), "Has subdir");
            Assert(items3.Any(i => i.Name == "test.txt" && !i.IsDirectory), "Has file");
        }
        finally { Directory.Delete(dir3, true); }

        // Test 4: Hidden items skipped
        Console.WriteLine("\n[Test 4] Hidden items skipped");
        var dir4 = NewTestDir();
        try
        {
            Directory.CreateDirectory(IOPath.Combine(dir4, ".hidden"));
            File.WriteAllText(IOPath.Combine(dir4, ".secret"), "data");
            var items4 = FileSystemService.ListDirectory(dir4);
            AssertEq(1, items4.Count, "Should return [EMPTY] when all items are hidden");
            AssertEq("[EMPTY]", items4[0].Name, "Should be [EMPTY] indicator");
        }
        finally { Directory.Delete(dir4, true); }

        // Test 5: Alphabetical sorting
        Console.WriteLine("\n[Test 5] Alphabetical sorting");
        var dir5 = NewTestDir();
        try
        {
            Directory.CreateDirectory(IOPath.Combine(dir5, "zebra"));
            Directory.CreateDirectory(IOPath.Combine(dir5, "apple"));
            var items5 = FileSystemService.ListDirectory(dir5);
            AssertEq(2, items5.Count, "Should return 2 items");
            AssertEq("apple", items5[0].Name, "First should be 'apple'");
            AssertEq("zebra", items5[1].Name, "Second should be 'zebra'");
        }
        finally { Directory.Delete(dir5, true); }

        // Test 6: HasChildren flag
        Console.WriteLine("\n[Test 6] HasChildren flag");
        var dir6 = NewTestDir();
        try
        {
            Directory.CreateDirectory(IOPath.Combine(dir6, "parent", "child"));
            Directory.CreateDirectory(IOPath.Combine(dir6, "empty_parent"));
            var items6 = FileSystemService.ListDirectory(dir6);
            AssertEq(2, items6.Count, "Should return 2 items");
            var parent = items6.First(i => i.Name == "parent");
            var emptyP = items6.First(i => i.Name == "empty_parent");
            Assert(parent.HasChildren, "Parent with child has HasChildren=true");
            Assert(!emptyP.HasChildren, "Empty parent has HasChildren=false");
        }
        finally { Directory.Delete(dir6, true); }

        // Test 7: FullPath set correctly
        Console.WriteLine("\n[Test 7] FullPath set correctly");
        var dir7 = NewTestDir();
        try
        {
            var testFile = IOPath.Combine(dir7, "test.txt");
            File.WriteAllText(testFile, "hello");
            var items7 = FileSystemService.ListDirectory(dir7);
            var fileItem = items7.FirstOrDefault(i => i.Name == "test.txt");
            Assert(fileItem != null, "test.txt found");
            AssertEq(testFile, fileItem?.FullPath ?? "", "FullPath matches");
        }
        finally { Directory.Delete(dir7, true); }

        // Test 8: HasSubDirectories
        Console.WriteLine("\n[Test 8] HasSubDirectories");
        var dir8 = NewTestDir();
        var parent8 = IOPath.Combine(dir8, "parent");
        Directory.CreateDirectory(IOPath.Combine(parent8, "child"));
        var empty8 = IOPath.Combine(dir8, "empty");
        Directory.CreateDirectory(empty8);
        try
        {
            Assert(FileSystemService.HasSubDirectories(parent8), "Parent has subdirs");
            Assert(!FileSystemService.HasSubDirectories(empty8), "Empty has no subdirs");
        }
        finally { Directory.Delete(dir8, true); }
    }

    static void RunWorkspaceStoreTests()
    {
        Console.WriteLine("\n=== WorkspaceStore Tests (Static Functions) ===");

        // GetDisplayName Tests
        Console.WriteLine("\n[GetDisplayName Tests]");

        Console.WriteLine("\n[Test 1] Normal path");
        AssertEq("myapp", WorkspaceStoreTests.GetDisplayName("/home/user/projects/myapp"), "Display name");

        Console.WriteLine("\n[Test 2] Single segment path");
        AssertEq("user", WorkspaceStoreTests.GetDisplayName("/home/user"), "Single segment returns last");

        Console.WriteLine("\n[Test 3] Windows path on Linux");
        AssertEq("C:\\Users\\developer\\workspace", WorkspaceStoreTests.GetDisplayName("C:\\Users\\developer\\workspace"), "Windows path unchanged on Linux");

        Console.WriteLine("\n[Test 4] Trailing slash - returns full path");
        AssertEq("/home/user", WorkspaceStoreTests.GetDisplayName("/home/user/"), "Trailing slash returns root");

        // CreateWorkspace Tests
        Console.WriteLine("\n[CreateWorkspace Tests]");

        Console.WriteLine("\n[Test 5] Sets all properties");
        var ws = WorkspaceStoreTests.CreateWorkspace("/path/to/project");
        Assert(!string.IsNullOrEmpty(ws.Id), "Id is generated");
        AssertEq("project", ws.Name, "Name extracted");
        AssertEq("/path/to/project", ws.Path, "Path preserved");
        Assert(ws.CreatedAt > DateTime.MinValue, "CreatedAt is set");

        Console.WriteLine("\n[Test 6] Unique IDs");
        var ws1 = WorkspaceStoreTests.CreateWorkspace("/one");
        var ws2 = WorkspaceStoreTests.CreateWorkspace("/two");
        Assert(ws1.Id != ws2.Id, "Each workspace has unique ID");

        Console.WriteLine("\n[Test 7] Single segment path");
        var wsRoot = WorkspaceStoreTests.CreateWorkspace("/home/user");
        AssertEq("user", wsRoot.Name, "Single segment returns last name");
    }
}
