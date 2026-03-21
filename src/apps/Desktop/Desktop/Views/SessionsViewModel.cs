namespace Desktop.ViewModels;

using System.Collections.ObjectModel;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;

public partial class SessionsViewModel : ObservableObject
{
    [ObservableProperty]
    private string _inputText = string.Empty;

    public ObservableCollection<MessageViewModel> Messages { get; } = [];

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
        // Dispatcher will be handled by the view
        OnMessageReceived?.Invoke(this, $"Echo: {userInput}");
    }

    // Event to notify view about new responses
    public event EventHandler<string>? OnMessageReceived;
}

public partial class MessageViewModel : ObservableObject
{
    [ObservableProperty]
    private string _content = string.Empty;

    [ObservableProperty]
    private bool _isUser;
}
