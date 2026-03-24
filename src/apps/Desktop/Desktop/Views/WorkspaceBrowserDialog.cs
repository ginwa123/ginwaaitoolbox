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
    private readonly ListView _folderList;
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
        
        // Folder list container with proper sizing
        var listContainer = new Grid
        {
            Background = DarkGray,
            BorderBrush = Gray,
            BorderThickness = new Thickness(2),
            MinHeight = 300,
            MinWidth = 450
        };

        _folderList = new ListView
        {
            Background = DarkGray,
            BorderThickness = new Thickness(0),
            ItemTemplate = CreateItemTemplate(),
            ItemsSource = _items
        };
        _folderList.SelectionChanged += OnFolderSelected;
        _folderList.DoubleTapped += OnFolderDoubleTapped;
        listContainer.Children.Add(_folderList);

        // Quick navigation buttons
        var quickNav = CreateQuickNavButtons();

        content.Children.Add(breadcrumb);
        content.Children.Add(_currentPathBlock);
        content.Children.Add(listContainer);
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
        _folderList.SelectedItem = null;

        if (!Directory.Exists(path))
        {
            _items.Add(new FileSystemItem { Name = "[PATH NOT FOUND]", IsDirectory = true, FullPath = path, IsDisabled = true });
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
            }

            if (_items.Count == 0)
            {
                _items.Add(new FileSystemItem { Name = "[EMPTY]", IsDirectory = true, FullPath = path, IsDisabled = true });
            }
        }
        catch (UnauthorizedAccessException)
        {
            _items.Add(new FileSystemItem { Name = "[ACCESS DENIED]", IsDirectory = true, FullPath = path, IsDisabled = true });
        }
        catch (Exception ex)
        {
            _items.Add(new FileSystemItem { Name = $"[ERROR: {ex.Message}]", IsDirectory = true, FullPath = path, IsDisabled = true });
        }
    }

    private DataTemplate CreateItemTemplate()
    {
        var template = new DataTemplate(() =>
        {
            var grid = new Grid();
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

            var icon = new TextBlock
            {
                FontFamily = MonoFont,
                FontSize = 12,
                VerticalAlignment = VerticalAlignment.Center,
                Margin = new Thickness(8, 6, 8, 6)
            };
            icon.SetBinding(TextBlock.TextProperty, new Microsoft.UI.Xaml.Data.Binding 
            { 
                Converter = new IconConverter() 
            });
            icon.SetBinding(TextBlock.ForegroundProperty, new Microsoft.UI.Xaml.Data.Binding
            {
                Converter = new IconColorConverter()
            });

            var name = new TextBlock
            {
                FontFamily = MonoFont,
                FontSize = 13,
                VerticalAlignment = VerticalAlignment.Center,
                Margin = new Thickness(0, 6, 16, 6)
            };
            // Use string path directly instead of PropertyPath
            var nameBinding = new Microsoft.UI.Xaml.Data.Binding { Path = "Name" };
            name.SetBinding(TextBlock.TextProperty, nameBinding);
            name.SetBinding(TextBlock.ForegroundProperty, new Microsoft.UI.Xaml.Data.Binding
            {
                Converter = new NameColorConverter()
            });

            Grid.SetColumn(icon, 0);
            Grid.SetColumn(name, 1);
            grid.Children.Add(icon);
            grid.Children.Add(name);

            return new ListViewItem { Content = grid };
        });
        return template;
    }

    private void OnFolderSelected(object sender, SelectionChangedEventArgs e)
    {
        if (_folderList.SelectedItem is FileSystemItem item && item.IsDirectory && !item.IsDisabled)
        {
            _currentPath = item.FullPath;
            UpdatePathDisplay();
            RefreshBreadcrumb();
            LoadDirectory(item.FullPath);
        }
    }

    private void OnFolderDoubleTapped(object sender, DoubleTappedRoutedEventArgs e)
    {
        if (_folderList.SelectedItem is FileSystemItem item && item.IsDirectory && !item.IsDisabled)
        {
            SelectedPath = item.FullPath;
            Hide();
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

public class IconConverter : Microsoft.UI.Xaml.Data.IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, string language)
    {
        if (value is FileSystemItem item)
        {
            if (item.IsDisabled) return "[?]";
            return item.IsDirectory ? (item.HasChildren ? "[+]" : "[■]") : "[·]";
        }
        return "[·]";
    }

    public object ConvertBack(object value, Type targetType, object parameter, string language) => throw new NotImplementedException();
}

public class IconColorConverter : Microsoft.UI.Xaml.Data.IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, string language)
    {
        if (value is FileSystemItem item)
        {
            if (item.IsDisabled) return new SolidColorBrush(Colors.Parse("#8b9198"));
            return item.IsDirectory ? new SolidColorBrush(Colors.Parse("#d19a66")) : new SolidColorBrush(Colors.Parse("#464b50"));
        }
        return new SolidColorBrush(Colors.Parse("#464b50"));
    }

    public object ConvertBack(object value, Type targetType, object parameter, string language) => throw new NotImplementedException();
}

public class NameColorConverter : Microsoft.UI.Xaml.Data.IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, string language)
    {
        if (value is FileSystemItem item)
        {
            if (item.IsDisabled) return new SolidColorBrush(Colors.Parse("#8b9198"));
            return item.IsDirectory ? new SolidColorBrush(Colors.Parse("#c5c8c9")) : new SolidColorBrush(Colors.Parse("#8b9198"));
        }
        return new SolidColorBrush(Colors.Parse("#c5c8c9"));
    }

    public object ConvertBack(object value, Type targetType, object parameter, string language) => throw new NotImplementedException();
}
