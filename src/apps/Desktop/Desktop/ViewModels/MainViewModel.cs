namespace Desktop.ViewModels;

using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;

/// <summary>
/// Main ViewModel demonstrating MVVM pattern with observable properties and relay commands.
/// </summary>
public partial class MainViewModel : ObservableObject
{
    [ObservableProperty]
    private string _title = "Hello Uno Platform MVVM!";

    [ObservableProperty]
    private string _message = "Welcome to the Desktop app with C# Markup + MVVM pattern.";

    [ObservableProperty]
    private int _clickCount = 0;

    [ObservableProperty]
    private string _inputText = string.Empty;

    [ObservableProperty]
    private bool _isDark = false;

    /// <summary>
    /// Command that increments the click counter.
    /// </summary>
    [RelayCommand]
    private void IncrementCounter()
    {
        ClickCount++;
    }

    /// <summary>
    /// Command that decrements the click counter.
    /// </summary>
    [RelayCommand]
    private void DecrementCounter()
    {
        ClickCount--;
    }

    /// <summary>
    /// Command that resets the counter and input.
    /// </summary>
    [RelayCommand]
    private void Reset()
    {
        ClickCount = 0;
        InputText = string.Empty;
    }

    /// <summary>
    /// Command that processes the input text.
    /// </summary>
    [RelayCommand]
    private void ProcessInput()
    {
        if (!string.IsNullOrWhiteSpace(InputText))
        {
            Message = $"You entered: {InputText}";
            InputText = string.Empty;
        }
    }

    /// <summary>
    /// Command that toggles the theme.
    /// </summary>
    [RelayCommand]
    private void ToggleTheme()
    {
        IsDark = !IsDark;
    }
}
