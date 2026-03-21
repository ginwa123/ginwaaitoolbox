namespace Desktop;

using Desktop.Views;
using Microsoft.UI;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

/// <summary>
/// MainPage - Neo-brutalist flat design with Moonfly dark theme.
/// Raw, bold, exposed structure with monospace typography.
/// </summary>
public sealed partial class MainPage : Page
{
    private Frame _contentFrame = null!;
    private StackPanel? _sidebar;

    // Moonfly palette
    private static readonly SolidColorBrush Black = new(Colors.Parse("#1b1d22"));
    private static readonly SolidColorBrush DarkGray = new(Colors.Parse("#323437"));
    private static readonly SolidColorBrush Gray = new(Colors.Parse("#464b50"));
    private static readonly SolidColorBrush LightGray = new(Colors.Parse("#8b9198"));
    private static readonly SolidColorBrush White = new(Colors.Parse("#c5c8c9"));
    private static readonly SolidColorBrush Teal = new(Colors.Parse("#56b6c2"));
    private static readonly SolidColorBrush Green = new(Colors.Parse("#98c379"));
    private static readonly SolidColorBrush Orange = new(Colors.Parse("#d19a66"));
    private static readonly FontFamily MonoFont = new("Consolas, Courier New, monospace");

    public MainPage()
    {
        // Frame must be created before Content is set
        _contentFrame = new Frame();

        // Main layout grid
        var root = new Grid();
        root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(40) });
        root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        root.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(280) }); // Sidebar
        root.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) }); // Content
        root.Background = Black;

        // === TOP BAR ===
        var topBar = new Grid
        {
            Background = DarkGray,
            BorderBrush = Gray,
            BorderThickness = new Thickness(0, 0, 0, 2)
        };
        Grid.SetRow(topBar, 0);
        Grid.SetColumnSpan(topBar, 2);

        var logo = new TextBlock
        {
            Text = "nalarcore",
            FontFamily = new FontFamily("Consolas, Courier New, monospace"),
            FontSize = 12,
            FontWeight = FontWeights.Bold,
            Foreground = White,
            VerticalAlignment = VerticalAlignment.Center,
            Margin = new Thickness(16, 0, 0, 0)
        };
        topBar.Children.Add(logo);
        root.Children.Add(topBar);

        // === LEFT SIDEBAR ===
        _sidebar = new StackPanel
        {
            Background = DarkGray,
            BorderBrush = Gray,
            BorderThickness = new Thickness(0, 0, 2, 0)
        };
        Grid.SetRow(_sidebar, 1);
        Grid.SetColumn(_sidebar, 0);

        // Add Workspace button at top
        var addWorkspaceBtn = new Button
        {
            Content = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, Children = 
            { 
                new TextBlock { Text = "+", FontFamily = MonoFont, FontSize = 14, FontWeight = FontWeights.Bold, Foreground = Green, VerticalAlignment = VerticalAlignment.Center },
                new TextBlock { Text = "ADD WORKSPACE", FontFamily = MonoFont, FontSize = 10, FontWeight = FontWeights.Bold, Foreground = White, VerticalAlignment = VerticalAlignment.Center }
            }},
            Background = Black,
            BorderBrush = Gray,
            BorderThickness = new Thickness(2),
            Padding = new Thickness(12, 10, 12, 10),
            HorizontalAlignment = HorizontalAlignment.Stretch,
            Margin = new Thickness(8, 8, 8, 8)
        };
        addWorkspaceBtn.Click += OnAddWorkspaceClick;
        _sidebar.Children.Add(addWorkspaceBtn);

        // Sidebar text component item
        var sidebarText = new TextBlock
        {
            Text = "WORKSPACES",
            FontFamily = MonoFont,
            FontSize = 9,
            FontWeight = FontWeights.Bold,
            Foreground = Gray,
            Margin = new Thickness(16, 16, 16, 8)
        };
        _sidebar.Children.Add(sidebarText);

        // Sessions section header
        var sessionsHeader = new TextBlock
        {
            Text = "SESSIONS",
            FontFamily = MonoFont,
            FontSize = 9,
            FontWeight = FontWeights.Bold,
            Foreground = Gray,
            Margin = new Thickness(16, 16, 16, 8)
        };
        _sidebar.Children.Add(sessionsHeader);

        // Sessions nav item
        var sessionsItem = CreateNavItem("SESSIONS", "▸", true);
        _sidebar.Children.Add(sessionsItem);

        // Add spacer
        _sidebar.Children.Add(new Border { Height = 1, Background = Gray, Margin = new Thickness(8, 16, 8, 16) });

        // Placeholder nav items (for visual structure)
        var historyItem = CreateNavItem("HISTORY", "○", false);
        _sidebar.Children.Add(historyItem);

        var settingsItem = CreateNavItem("SETTINGS", "●", false);
        _sidebar.Children.Add(settingsItem);

        root.Children.Add(_sidebar);

        // === CONTENT FRAME ===
        Grid.SetRow(_contentFrame, 1);
        Grid.SetColumn(_contentFrame, 1);
        root.Children.Add(_contentFrame);

        Content = root;

        // Navigate to Sessions on load
        _contentFrame.Navigate(typeof(SessionsView));
    }

    private static FrameworkElement CreateNavItem(string label, string indicator, bool isSelected)
    {
        var bg = isSelected ? Gray : DarkGray;
        var textColor = isSelected ? Teal : LightGray;
        var indicatorColor = isSelected ? Teal : Gray;

        var container = new Border
        {
            Background = bg,
            BorderThickness = new Thickness(0),
            Padding = new Thickness(16, 12, 16, 12)
        };

        var stack = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };

        var ind = new TextBlock
        {
            Text = indicator,
            FontFamily = new FontFamily("Consolas, Courier New, monospace"),
            FontSize = 10,
            Foreground = indicatorColor,
            VerticalAlignment = VerticalAlignment.Center,
            Width = 16
        };

        var lbl = new TextBlock
        {
            Text = label,
            FontFamily = new FontFamily("Consolas, Courier New, monospace"),
            FontSize = 11,
            FontWeight = isSelected ? FontWeights.Bold : FontWeights.Normal,
            Foreground = textColor,
            VerticalAlignment = VerticalAlignment.Center
        };

        stack.Children.Add(ind);
        stack.Children.Add(lbl);
        container.Child = stack;

        return container;
    }

    private async void OnAddWorkspaceClick(object sender, RoutedEventArgs e)
    {
        var dialog = new WorkspaceBrowserDialog
        {
            XamlRoot = XamlRoot
        };

        var result = await dialog.ShowAsync();
        
        if (result == ContentDialogResult.Primary && dialog.SelectedPath != null)
        {
            // Handle workspace selection - for now, just log it
            // TODO: Integrate with workspace management system
            System.Diagnostics.Debug.WriteLine($"Workspace selected: {dialog.SelectedPath}");
            
            // Add to sidebar as a new workspace item
            AddWorkspaceToSidebar(dialog.SelectedPath);
        }
    }

    private void AddWorkspaceToSidebar(string path)
    {
        if (_sidebar == null) return;

        // Extract folder name from path
        var name = System.IO.Path.GetFileName(path);
        if (string.IsNullOrEmpty(name))
            name = path.Replace("\\", "/").Split('/').LastOrDefault() ?? "Workspace";

        // Create workspace nav item
        var workspaceItem = CreateNavItem(name.ToUpper(), "○", false);
        
        // Insert before the spacer (after sessions header)
        var insertIndex = 3; // After header, button, and sessions
        if (insertIndex < _sidebar.Children.Count)
        {
            _sidebar.Children.Insert(insertIndex, workspaceItem);
        }
        else
        {
            _sidebar.Children.Add(workspaceItem);
        }
    }
}
