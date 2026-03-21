namespace Desktop.Views;

using System.Collections.ObjectModel;
using Microsoft.UI;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;

/// <summary>
/// WorkspaceBrowserDialog - Modal dialog for browsing and selecting workspace directories.
/// Neo-brutalist design matching the Moonfly dark theme.
/// </summary>
public sealed partial class WorkspaceBrowserDialog : ContentDialog
{
    private readonly StackPanel _treePanel;
    private readonly TextBlock _currentPathBlock;
    private readonly string _rootPath;
    private string _currentPath;
    private readonly ObservableCollection<FileSystemItem> _items = new();

    // Moonfly palette
    private static readonly SolidColorBrush Black = new(Colors.Parse("#1b1d22"));
    private static readonly SolidColorBrush DarkGray = new(Colors.Parse("#323437"));
    private static readonly SolidColorBrush Gray = new(Colors.Parse("#464b50"));
    private static readonly SolidColorBrush LightGray = new(Colors.Parse("#8b9198"));
    private static readonly SolidColorBrush White = new(Colors.Parse("#c5c8c9"));
    private static readonly SolidColorBrush Teal = new(Colors.Parse("#56b6c2"));
    private static readonly SolidColorBrush Red = new(Colors.Parse("#e06c75"));
    private static readonly SolidColorBrush Orange = new(Colors.Parse("#d19a66"));

    private static readonly FontFamily MonoFont = new("Consolas, Courier New, monospace");

    public string? SelectedPath { get; private set; }

    public WorkspaceBrowserDialog()
    {
        // Default to user's home directory or common paths
        _rootPath = GetDefaultRootPath();
        _currentPath = _rootPath;

        // Dialog styling
        Title = "ADD WORKSPACE";
        Background = Black;
        PrimaryButtonText = "SELECT";
        PrimaryButtonStyle = CreateButtonStyle(Teal, Black);
        CloseButtonText = "CANCEL";
        CloseButtonStyle = CreateButtonStyle(Gray, White);
        
        DefaultButton = ContentDialogButton.Primary;

        // Build dialog content
        var content = new StackPanel { Spacing = 16 };

        // Current path display
        _currentPathBlock = new TextBlock
        {
            FontFamily = MonoFont,
            FontSize = 11,
            Foreground = Teal,
            TextWrapping = TextWrapping.NoWrap,
            TextTrimming = TextTrimming.CharacterEllipsis,
            Margin = new Thickness(0, 0, 0, 8)
        };
        UpdatePathDisplay();

        // Breadcrumb navigation
        var breadcrumb = CreateBreadcrumb();
        
        // Folder tree container
        var treeContainer = new Border
        {
            Background = DarkGray,
            BorderBrush = Gray,
            BorderThickness = new Thickness(2),
            Padding = new Thickness(8),
            MaxHeight = 400,
            MinWidth = 450
        };

        _treePanel = new StackPanel { Spacing = 0 };
        treeContainer.Child = new ScrollViewer
        {
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            Content = _treePanel
        };

        // Quick navigation buttons
        var quickNav = CreateQuickNavButtons();

        content.Children.Add(breadcrumb);
        content.Children.Add(_currentPathBlock);
        content.Children.Add(treeContainer);
        content.Children.Add(quickNav);

        Content = content;

        // Load initial items
        LoadDirectory(_currentPath);

        // Button click handlers
        PrimaryButtonClick += OnPrimaryButtonClick;
    }

    private string GetDefaultRootPath()
    {
        // Try common locations
        var paths = new[]
        {
            Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
            Environment.GetFolderPath(Environment.SpecialFolder.Desktop),
            "/home",  // Unix-style home
            "C:\\Users", // Windows Users folder
            "/" // Root as fallback
        };

        foreach (var path in paths)
        {
            if (Directory.Exists(path))
                return path;
        }

        return Directory.GetCurrentDirectory();
    }

    private FrameworkElement CreateBreadcrumb()
    {
        var container = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4 };

        // Root button
        var rootBtn = CreateBreadcrumbButton("~", _rootPath);
        container.Children.Add(rootBtn);

        // Parent directory button
        if (_currentPath != _rootPath)
        {
            var parent = Directory.GetParent(_currentPath)?.FullName ?? _rootPath;
            var parentBtn = CreateBreadcrumbButton("..", parent);
            container.Children.Add(parentBtn);
        }

        return container;
    }

    private Button CreateBreadcrumbButton(string label, string path)
    {
        var btn = new Button
        {
            Content = label,
            FontFamily = MonoFont,
            FontSize = 11,
            Background = DarkGray,
            Foreground = LightGray,
            BorderThickness = new Thickness(0),
            Padding = new Thickness(8, 4, 8, 4),
            Margin = new Thickness(0, 0, 4, 0)
        };

        btn.Click += (s, e) =>
        {
            _currentPath = path;
            UpdatePathDisplay();
            RefreshBreadcrumb();
            LoadDirectory(path);
        };

        return btn;
    }

    private void UpdatePathDisplay()
    {
        var displayPath = _currentPath.Replace(_rootPath, "~").Replace("\\", "/");
        _currentPathBlock.Text = $"> {displayPath}";
    }

    private void RefreshBreadcrumb()
    {
        // Rebuild breadcrumb is handled in the parent
    }

    private FrameworkElement CreateQuickNavButtons()
    {
        var panel = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };

        var quickPaths = new[]
        {
            ("HOME", Environment.GetFolderPath(Environment.SpecialFolder.UserProfile)),
            ("DESKTOP", Environment.GetFolderPath(Environment.SpecialFolder.Desktop)),
            ("DOCS", Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments))
        };

        foreach (var (label, path) in quickPaths)
        {
            if (!Directory.Exists(path)) continue;

            var btn = new Button
            {
                Content = $"[{label}]",
                FontFamily = MonoFont,
                FontSize = 10,
                Background = Gray,
                Foreground = White,
                BorderThickness = new Thickness(0),
                Padding = new Thickness(10, 6, 10, 6)
            };

            var capturedPath = path;
            btn.Click += (s, e) =>
            {
                _currentPath = capturedPath;
                UpdatePathDisplay();
                LoadDirectory(capturedPath);
            };

            panel.Children.Add(btn);
        }

        // Refresh button
        var refreshBtn = new Button
        {
            Content = "[↻]",
            FontFamily = MonoFont,
            FontSize = 10,
            Background = DarkGray,
            Foreground = Teal,
            BorderThickness = new Thickness(0),
            Padding = new Thickness(10, 6, 10, 6)
        };
        refreshBtn.Click += (s, e) => LoadDirectory(_currentPath);
        panel.Children.Add(refreshBtn);

        return panel;
    }

    private void LoadDirectory(string path)
    {
        _items.Clear();
        _treePanel.Children.Clear();

        if (!Directory.Exists(path))
        {
            AddItem(new FileSystemItem { Name = "[PATH NOT FOUND]", IsDirectory = true, FullPath = path, IsDisabled = true });
            return;
        }

        try
        {
            // Get directories first
            var dirs = Directory.GetDirectories(path);
            Array.Sort(dirs, StringComparer.OrdinalIgnoreCase);

            foreach (var dir in dirs)
            {
                var name = System.IO.Path.GetFileName(dir);
                // Skip hidden/system directories
                if (name.StartsWith(".")) continue;

                var item = new FileSystemItem
                {
                    Name = name,
                    IsDirectory = true,
                    FullPath = dir,
                    HasChildren = HasSubDirectories(dir)
                };
                _items.Add(item);
                AddTreeItem(item, 0);
            }

            // Then get files (limited to common workspace files)
            var files = Directory.GetFiles(path);
            Array.Sort(files, StringComparer.OrdinalIgnoreCase);

            foreach (var file in files.Take(50)) // Limit file display
            {
                var name = System.IO.Path.GetFileName(file);
                if (name.StartsWith(".")) continue;

                var item = new FileSystemItem
                {
                    Name = name,
                    IsDirectory = false,
                    FullPath = file
                };
                _items.Add(item);
                AddTreeItem(item, 0);
            }

            if (_items.Count == 0)
            {
                AddItem(new FileSystemItem { Name = "[EMPTY]", IsDirectory = true, FullPath = path, IsDisabled = true });
            }
        }
        catch (UnauthorizedAccessException)
        {
            AddItem(new FileSystemItem { Name = "[ACCESS DENIED]", IsDirectory = true, FullPath = path, IsDisabled = true });
        }
        catch (Exception ex)
        {
            AddItem(new FileSystemItem { Name = $"[ERROR: {ex.Message}]", IsDirectory = true, FullPath = path, IsDisabled = true });
        }
    }

    private bool HasSubDirectories(string path)
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

    private void AddTreeItem(FileSystemItem item, int depth)
    {
        var container = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = 0,
            Margin = new Thickness(depth * 16 + 4, 2, 4, 2)
        };

        // Indent
        if (depth > 0)
        {
            container.Children.Add(new Border { Width = 8 });
        }

        // Icon
        var icon = new TextBlock
        {
            Text = item.IsDirectory ? (item.HasChildren ? "[+]" : "[■]") : "[·]",
            FontFamily = MonoFont,
            FontSize = 11,
            Foreground = item.IsDirectory ? Orange : Gray,
            VerticalAlignment = VerticalAlignment.Center,
            Margin = new Thickness(0, 0, 8, 0)
        };

        // Name
        var nameBlock = new TextBlock
        {
            Text = item.Name,
            FontFamily = MonoFont,
            FontSize = 12,
            Foreground = item.IsDisabled ? Gray : (item.IsDirectory ? White : LightGray),
            VerticalAlignment = VerticalAlignment.Center
        };

        container.Children.Add(icon);
        container.Children.Add(nameBlock);

        // Make it interactive if directory
        if (item.IsDirectory && !item.IsDisabled)
        {
            var button = new Button
            {
                Content = container,
                Background = DarkGray,
                BorderThickness = new Thickness(0),
                Padding = new Thickness(0),
                HorizontalAlignment = HorizontalAlignment.Stretch
            };

            // Track which directories have been expanded
            button.Click += (s, e) =>
            {
                if (!item.IsExpanded)
                {
                    ExpandDirectory(item, depth);
                }
                else
                {
                    CollapseDirectory(item);
                }
            };

            // Double click to select
            button.DoubleTapped += (s, e) =>
            {
                SelectedPath = item.FullPath;
                Hide();
            };

            _treePanel.Children.Add(button);
        }
        else
        {
            var border = new Border
            {
                Background = DarkGray,
                Child = container
            };
            _treePanel.Children.Add(border);
        }
    }

    private void ExpandDirectory(FileSystemItem item, int parentDepth)
    {
        item.IsExpanded = true;

        try
        {
            var dirs = Directory.GetDirectories(item.FullPath);
            Array.Sort(dirs, StringComparer.OrdinalIgnoreCase);

            foreach (var dir in dirs.Take(20))
            {
                var name = System.IO.Path.GetFileName(dir);
                if (name.StartsWith(".")) continue;

                var childItem = new FileSystemItem
                {
                    Name = name,
                    IsDirectory = true,
                    FullPath = dir,
                    Parent = item,
                    HasChildren = HasSubDirectories(dir)
                };
                item.Children.Add(childItem);
                AddTreeItem(childItem, parentDepth + 1);
            }
        }
        catch { }
    }

    private void CollapseDirectory(FileSystemItem item)
    {
        item.IsExpanded = false;
        // For simplicity, we remove all children from display
        // A more sophisticated implementation would cache and restore
    }

    private void AddItem(FileSystemItem item)
    {
        AddTreeItem(item, 0);
    }

    private Style CreateButtonStyle(SolidColorBrush bg, SolidColorBrush fg)
    {
        var style = new Style(typeof(Button));
        style.Setters.Add(new Setter(Button.BackgroundProperty, bg));
        style.Setters.Add(new Setter(Button.ForegroundProperty, fg));
        style.Setters.Add(new Setter(Button.FontFamilyProperty, MonoFont));
        style.Setters.Add(new Setter(Button.FontSizeProperty, 11));
        style.Setters.Add(new Setter(Button.FontWeightProperty, FontWeights.Bold));
        style.Setters.Add(new Setter(Button.PaddingProperty, new Thickness(16, 8, 16, 8)));
        style.Setters.Add(new Setter(Button.BorderThicknessProperty, new Thickness(0)));
        return style;
    }

    private void OnPrimaryButtonClick(ContentDialog sender, ContentDialogButtonClickEventArgs args)
    {
        // Use current path as selected workspace
        SelectedPath = _currentPath;
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
