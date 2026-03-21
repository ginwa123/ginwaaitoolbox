namespace Desktop.Views;

using Microsoft.UI;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Desktop.ViewModels;

/// <summary>
/// SessionsView - Neo-brutalist flat chat interface.
/// Raw borders, monospace typography, exposed structure.
/// </summary>
public sealed partial class SessionsView : Page
{
    private readonly StackPanel _messagesPanel;
    private readonly ScrollViewer _scrollViewer;
    private readonly TextBox _inputBox;
    private readonly Button _sendButton;
    private readonly SessionsViewModel _viewModel;

    // Moonfly palette
    private static readonly SolidColorBrush Black = new(Colors.Parse("#1b1d22"));
    private static readonly SolidColorBrush DarkGray = new(Colors.Parse("#323437"));
    private static readonly SolidColorBrush Gray = new(Colors.Parse("#464b50"));
    private static readonly SolidColorBrush White = new(Colors.Parse("#c5c8c9"));
    private static readonly SolidColorBrush Teal = new(Colors.Parse("#56b6c2"));
    private static readonly SolidColorBrush Green = new(Colors.Parse("#98c379"));

    private static readonly FontFamily MonoFont = new("Consolas, Courier New, monospace");

    public SessionsView()
    {
        _viewModel = new SessionsViewModel();
        _viewModel.OnMessageReceived += OnMessageReceived;

        // Messages container
        _messagesPanel = new StackPanel { Spacing = 16 };

        _scrollViewer = new ScrollViewer
        {
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            Padding = new Thickness(24, 24, 24, 24),
            Content = _messagesPanel
        };

        // Input box
        _inputBox = new TextBox
        {
            PlaceholderText = ">",
            FontFamily = MonoFont,
            FontSize = 13,
            Background = Black,
            Foreground = White,
            BorderBrush = Gray,
            BorderThickness = new Thickness(2, 2, 0, 2),
            Padding = new Thickness(12, 10, 12, 10)
        };

        // Send button (brutalist square)
        _sendButton = new Button
        {
            Content = "SEND",
            FontFamily = MonoFont,
            FontSize = 11,
            FontWeight = FontWeights.Bold,
            Background = Teal,
            Foreground = Black,
            BorderThickness = new Thickness(0),
            Padding = new Thickness(16, 10, 16, 10)
        };
        _sendButton.Click += OnSendClick;

        // Build layout
        var root = new Grid();
        root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(56) });
        root.Background = Black;

        // Input area container
        var inputContainer = new Grid
        {
            Background = DarkGray,
            BorderBrush = Gray,
            BorderThickness = new Thickness(0, 2, 0, 0)
        };
        inputContainer.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        inputContainer.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(0, GridUnitType.Auto) });

        Grid.SetRow(inputContainer, 1);
        Grid.SetColumn(_inputBox, 0);
        Grid.SetColumn(_sendButton, 1);

        inputContainer.Children.Add(_inputBox);
        inputContainer.Children.Add(_sendButton);

        root.Children.Add(_scrollViewer);
        root.Children.Add(inputContainer);

        Content = root;

        // Initial message
        AddSystemMessage("nalarcore v1.0.0");
        AddSystemMessage("Session started. Ready for input.");
    }

    private void OnSendClick(object sender, RoutedEventArgs e)
    {
        var text = _inputBox.Text?.Trim();
        if (string.IsNullOrEmpty(text)) return;

        // Add user message
        AddUserMessage(text);
        _inputBox.Text = "";

        // Process via viewmodel
        _viewModel.InputText = text;
        _viewModel.SendMessageCommand.Execute(null);
    }

    private void AddSystemMessage(string text)
    {
        var msg = CreateBrutalistMessage(text, "SYS", Gray);
        _messagesPanel.Children.Add(msg);
    }

    private void AddUserMessage(string text)
    {
        var msg = CreateBrutalistMessage(text, "USER", Teal);
        _messagesPanel.Children.Add(msg);
        ScrollToBottom();
    }

    private void AddAssistantMessage(string text)
    {
        var msg = CreateBrutalistMessage(text, "AI", Green);
        _messagesPanel.Children.Add(msg);
        ScrollToBottom();
    }

    private void ScrollToBottom()
    {
        DispatcherQueue.TryEnqueue(Microsoft.UI.Dispatching.DispatcherQueuePriority.Low, () =>
        {
            _scrollViewer.ScrollToVerticalOffset(_scrollViewer.ScrollableHeight);
        });
    }

    private void OnMessageReceived(object? sender, string response)
    {
        DispatcherQueue.TryEnqueue(Microsoft.UI.Dispatching.DispatcherQueuePriority.Normal, () =>
        {
            AddAssistantMessage(response);
        });
    }

    private static FrameworkElement CreateBrutalistMessage(string content, string prefix, SolidColorBrush accentColor)
    {
        var container = new StackPanel { Spacing = 4 };

        // Header with prefix and accent
        var header = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };

        var accent = new Border
        {
            Width = 3,
            Background = accentColor
        };

        var prefixBlock = new TextBlock
        {
            Text = prefix,
            FontFamily = MonoFont,
            FontSize = 10,
            FontWeight = FontWeights.Bold,
            Foreground = accentColor,
            VerticalAlignment = VerticalAlignment.Center
        };

        header.Children.Add(accent);
        header.Children.Add(prefixBlock);

        // Content
        var contentBlock = new TextBlock
        {
            Text = content,
            FontFamily = MonoFont,
            FontSize = 13,
            Foreground = White,
            TextWrapping = TextWrapping.Wrap,
            Margin = new Thickness(11, 4, 0, 0)
        };

        container.Children.Add(header);
        container.Children.Add(contentBlock);

        return container;
    }
}
