# Desktop App Moonfly Theme Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add top app bar and left sidebar to Desktop app using Uno Platform with Moonfly dark theme

**Architecture:** Grid-based layout with WinUI NavigationView for sidebar, custom Moonfly color resources, MVVM pattern

**Tech Stack:** Uno Platform, C# Markup, WinUI NavigationView, CommunityToolkit.Mvvm

---

## Chunk 1: Moonfly Theme Resources

**Files:**
- Modify: `src/apps/Desktop/Desktop/App.xaml`

- [ ] **Step 1: Add Moonfly color resources to App.xaml**

Replace the existing App.xaml content with Moonfly colors:

```xml
<Application x:Class="Desktop.App"
       xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
       xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml">

  <Application.Resources>
    <ResourceDictionary>
      <ResourceDictionary.MergedDictionaries>
        <XamlControlsResources xmlns="using:Microsoft.UI.Xaml.Controls" />
      </ResourceDictionary.MergedDictionaries>

      <!-- Moonfly Color Palette -->
      <Color x:Key="MoonflyBlack">#1b1d22</Color>
      <Color x:Key="MoonflyDarkGray">#323437</Color>
      <Color x:Key="MoonflyGray">#464b50</Color>
      <Color x:Key="MoonflyLightGray">#8b9198</Color>
      <Color x:Key="MoonflyWhite">#c5c8c9</Color>
      <Color x:Key="MoonflyTeal">#56b6c2</Color>
      <Color x:Key="MoonflyGreen">#98c379</Color>
      <Color x:Key="MoonflyYellow">#e5c07b</Color>
      <Color x:Key="MoonflyRed">#e06c75</Color>
      <Color x:Key="MoonflyBlue">#61afef</Color>
      <Color x:Key="MoonflyPurple">#c678dd</Color>
      <Color x:Key="MoonflyOrange">#d19a66</Color>

      <!-- Moonfly Brushes -->
      <SolidColorBrush x:Key="MoonflyBackgroundBrush" Color="#1b1d22" />
      <SolidColorBrush x:Key="MoonflySidebarBrush" Color="#323437" />
      <SolidColorBrush x:Key="MoonflySidebarHoverBrush" Color="#464b50" />
      <SolidColorBrush x:Key="MoonflySidebarSelectedBrush" Color="#56b6c2" />
      <SolidColorBrush x:Key="MoonflyTextPrimaryBrush" Color="#c5c8c9" />
      <SolidColorBrush x:Key="MoonflyTextSecondaryBrush" Color="#8b9198" />
      <SolidColorBrush x:Key="MoonflyBorderBrush" Color="#464b50" />
      <SolidColorBrush x:Key="MoonflyAccentBrush" Color="#56b6c2" />

      <!-- Window Chrome -->
      <SolidColorBrush x:Key="AppBarBackgroundBrush" Color="#1b1d22" />

    </ResourceDictionary>
  </Application.Resources>

</Application>
```

- [ ] **Step 2: Verify build**

Run: `cd src/apps/Desktop && dotnet build -f net10.0-desktop`
Expected: BUILD SUCCEEDED

---

## Chunk 2: Sessions View (Chat Interface)

**Files:**
- Create: `src/apps/Desktop/Desktop/Views/SessionsView.xaml.cs`

- [ ] **Step 1: Create SessionsView with chat interface**

Create the file with C# Markup:

```csharp
namespace Desktop.Views;

using Microsoft.UI;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Uno.Extensions.Markup;
using Desktop.ViewModels;

/// <summary>
/// Sessions view with chat interface for LLM interaction.
/// </summary>
public sealed partial class SessionsView : Page
{
    public SessionsView()
    {
        this.DataContext(new SessionsViewModel(), (page, vm) => page
            .Background(new SolidColorBrush(Colors.Black))
            .Content(
                new Grid()
                    .RowDefinitions(
                        rows => rows
                            .Star(1)  // Messages area
                            .Auto()   // Input area
                    )
                    .Children(
                        // Messages ScrollViewer
                        new ScrollViewer()
                            .Grid(row: 0)
                            .VerticalScrollBarVisibility(ScrollBarVisibility.Auto)
                            .Padding(16)
                            .Content(
                                new ItemsControl()
                                    .ItemsSource(() => vm.Messages, items => items
                                        .StackPanel()
                                        .Spacing(12)
                                        .Children(
                                            vm.Messages.Select(msg => CreateMessageBubble(msg))
                                        )
                                    )
                            ),

                        // Input Area
                        new Border()
                            .Grid(row: 1)
                            .BorderBrush(new SolidColorBrush(Colors.Parse("#464b50")))
                            .BorderThickness(0, 1, 0, 0)
                            .Padding(16, 12, 16, 12)
                            .Background(new SolidColorBrush(Colors.Parse("#323437")))
                            .Child(
                                new Grid()
                                    .ColumnDefinitions(
                                        cols => cols
                                            .Star(1)
                                            .Auto()
                                    )
                                    .Children(
                                        new TextBox()
                                            .Grid(column: 0)
                                            .PlaceholderText("Send a message...")
                                            .Background(new SolidColorBrush(Colors.Parse("#1b1d22")))
                                            .Foreground(new SolidColorBrush(Colors.Parse("#c5c8c9")))
                                            .BorderBrush(new SolidColorBrush(Colors.Parse("#464b50")))
                                            .Text(x => x.Binding(() => vm.InputText).TwoWay())
                                            .Margin(0, 0, 8, 0),

                                        new Button()
                                            .Grid(column: 1)
                                            .Content("Send")
                                            .Background(new SolidColorBrush(Colors.Parse("#56b6c2")))
                                            .Foreground(new SolidColorBrush(Colors.Parse("#1b1d22")))
                                            .Command(() => vm.SendMessageCommand)
                                    )
                            )
                    )
            )
        );
    }

    private static FrameworkElement CreateMessageBubble(MessageViewModel msg)
    {
        var isUser = msg.IsUser;
        var bubbleColor = isUser ? "#323437" : "#2d333b";
        var textColor = "#c5c8c9";
        var alignment = isUser ? HorizontalAlignment.Right : HorizontalAlignment.Left;
        var margin = isUser ? "80,0,0,0" : "0,0,80,0";

        return new Border()
            .Background(new SolidColorBrush(Colors.Parse(bubbleColor)))
            .CornerRadius(12)
            .Padding(12, 8, 12, 8)
            .HorizontalAlignment(alignment)
            .Margin(0, 0, 0, 0)
            .Child(
                new TextBlock()
                    .Text(msg.Content)
                    .Foreground(new SolidColorBrush(Colors.Parse(textColor)))
                    .TextWrapping(TextWrapping.Wrap)
            );
    }
}
```

- [ ] **Step 2: Create SessionsViewModel**

```csharp
namespace Desktop.ViewModels;

using System.Collections.ObjectModel;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;

public partial class SessionsViewModel : ObservableObject
{
    [ObservableProperty]
    private string _inputText = string.Empty;

    public ObservableCollection<MessageViewModel> Messages { get; } = new();

    public SessionsViewModel()
    {
        // Initial welcome message
        Messages.Add(new MessageViewModel
        {
            Content = "Welcome! How can I assist you today?",
            IsUser = false
        });
    }

    [RelayCommand]
    private void SendMessage()
    {
        if (string.IsNullOrWhiteSpace(InputText))
            return;

        // Add user message
        Messages.Add(new MessageViewModel
        {
            Content = InputText,
            IsUser = true
        });

        var userInput = InputText;
        InputText = string.Empty;

        // Simulate LLM response (placeholder - connect to actual LLM later)
        Task.Delay(500).ContinueWith(_ =>
        {
            // This would be replaced with actual LLM integration
            Windows.ApplicationModel.Core.CoreApplication.MainView.CoreWindow.Dispatcher
                .RunAsync(Windows.UI.Core.CoreDispatcherPriority.Normal, () =>
                {
                    Messages.Add(new MessageViewModel
                    {
                        Content = $"Echo: {userInput}",
                        IsUser = false
                    });
                });
        });
    }
}

public partial class MessageViewModel : ObservableObject
{
    [ObservableProperty]
    private string _content = string.Empty;

    [ObservableProperty]
    private bool _isUser;
}
```

- [ ] **Step 3: Verify build**

Run: `cd src/apps/Desktop && dotnet build -f net10.0-desktop`
Expected: BUILD SUCCEEDED

---

## Chunk 3: MainPage with Navigation

**Files:**
- Modify: `src/apps/Desktop/Desktop/MainPage.xaml.cs`

- [ ] **Step 1: Restructure MainPage with NavigationView**

Replace MainPage.xaml.cs with:

```csharp
namespace Desktop;

using Microsoft.UI;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Uno.Extensions.Markup;

public sealed partial class MainPage : Page
{
    public MainPage()
    {
        this
            .Background(new SolidColorBrush(Colors.Parse("#1b1d22")))
            .Content(
                new NavigationView()
                    .PaneBackground(new SolidColorBrush(Colors.Parse("#323437")))
                    .Background(new SolidColorBrush(Colors.Parse("#1b1d22")))
                    .IsPaneOpen(false)
                    .PaneDisplayMode(NavigationViewPaneDisplayMode.LeftMinimal)
                    .IsBackButtonVisible(NavigationViewBackButtonVisible.Collapsed)
                    .OpenPaneLength(220)
                    .IsPaneToggleVisible(false)
                    .AlwaysShowHeader(true)
                    .Header(
                        new Grid()
                            .Height(48)
                            .Background(new SolidColorBrush(Colors.Parse("#1b1d22")))
                            .Padding(16, 0, 16, 0)
                            .Children(
                                new TextBlock()
                                    .Text("nalarcore")
                                    .FontSize(16)
                                    .FontWeight(Windows.UI.Text.FontWeights.SemiBold)
                                    .Foreground(new SolidColorBrush(Colors.Parse("#c5c8c9")))
                                    .VerticalAlignment(VerticalAlignment.Center)
                            )
                    )
                    .MenuItems(
                        new NavigationViewItem()
                            .Content("Sessions")
                            .Icon(new SymbolIcon(Symbol.Chat24))
                            .Foreground(new SolidColorBrush(Colors.Parse("#c5c8c9")))
                    )
                    .Content(
                        new SessionsContent()
                    )
            );
    }
}

/// <summary>
/// Placeholder content that will be replaced when Sessions is selected.
/// For now, shows the SessionsView directly.
/// </summary>
public class SessionsContent : Frame
{
    public SessionsContent()
    {
        this.Navigate(typeof(Desktop.Views.SessionsView));
    }
}
```

- [ ] **Step 2: Update MainViewModel for navigation**

Simplify MainViewModel - navigation is now handled by NavigationView:

```csharp
namespace Desktop.ViewModels;

using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;

public partial class MainViewModel : ObservableObject
{
    [ObservableProperty]
    private string _title = "nalarcore";

    [ObservableProperty]
    private string _message = "Desktop Assistant";
}
```

- [ ] **Step 3: Verify build**

Run: `cd src/apps/Desktop && dotnet build -f net10.0-desktop`
Expected: BUILD SUCCEEDED

---

## Chunk 4: Add Navigation Selection Logic

**Files:**
- Modify: `src/apps/Desktop/Desktop/MainPage.xaml.cs`

- [ ] **Step 1: Add navigation selection handling**

Update MainPage.xaml.cs to handle navigation item selection:

```csharp
namespace Desktop;

using Desktop.Views;
using Microsoft.UI;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Uno.Extensions.Markup;

public sealed partial class MainPage : Page
{
    private readonly Frame _contentFrame;

    public MainPage()
    {
        _contentFrame = new Frame();

        this
            .Background(new SolidColorBrush(Colors.Parse("#1b1d22")))
            .Content(
                new NavigationView()
                    .Reference(nav => _navView = nav)
                    .PaneBackground(new SolidColorBrush(Colors.Parse("#323437")))
                    .Background(new SolidColorBrush(Colors.Parse("#1b1d22")))
                    .IsPaneOpen(false)
                    .PaneDisplayMode(NavigationViewPaneDisplayMode.LeftMinimal)
                    .IsBackButtonVisible(NavigationViewBackButtonVisible.Collapsed)
                    .OpenPaneLength(220)
                    .IsPaneToggleVisible(false)
                    .AlwaysShowHeader(true)
                    .Header(
                        new Grid()
                            .Height(48)
                            .Background(new SolidColorBrush(Colors.Parse("#1b1d22")))
                            .Padding(16, 0, 16, 0)
                            .Children(
                                new TextBlock()
                                    .Text("nalarcore")
                                    .FontSize(16)
                                    .FontWeight(Windows.UI.Text.FontWeights.SemiBold)
                                    .Foreground(new SolidColorBrush(Colors.Parse("#c5c8c9")))
                                    .VerticalAlignment(VerticalAlignment.Center)
                            )
                    )
                    .MenuItems(
                        new NavigationViewItem()
                            .Content("Sessions")
                            .Icon(new SymbolIcon(Symbol.Chat24))
                            .Foreground(new SolidColorBrush(Colors.Parse("#c5c8c9")))
                            .IsSelected(true)
                            .Reference(item => _sessionsItem = item)
                    )
                    .Content(
                        _contentFrame
                    )
            );

        // Navigate to initial view
        _contentFrame.Navigate(typeof(SessionsView));
    }

    private NavigationView? _navView;
    private NavigationViewItem? _sessionsItem;
}

public class SessionsContent : Frame
{
    public SessionsContent()
    {
        this.Navigate(typeof(Desktop.Views.SessionsView));
    }
}
```

- [ ] **Step 2: Verify build**

Run: `cd src/apps/Desktop && dotnet build -f net10.0-desktop`
Expected: BUILD SUCCEEDED

---

## Verification Checklist

- [ ] Moonfly colors render correctly (dark background, teal accents)
- [ ] App bar shows "nalarcore" title
- [ ] Sidebar shows "Sessions" item with chat icon
- [ ] Clicking Sessions shows chat interface
- [ ] Chat input field accepts text
- [ ] Send button triggers message

---

## Run Commands

```bash
cd src/apps/Desktop
dotnet build -f net10.0-desktop
dotnet run -f net10.0-desktop
```
