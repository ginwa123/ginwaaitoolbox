# Desktop App - MVVM + C# Markup Pattern

This Uno Platform Desktop application uses **MVVM + C# Markup** for UI definition.

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                     VIEW (MainPage.cs)                     │
│  - C# Markup fluent API for UI                            │
│  - DataContext set via extension method                    │
│  - Zero XAML required                                      │
└─────────────────────────────────────────────────────────────┘
                              │
                              │ Data Binding (OneWay/TwoWay)
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                  VIEWMODEL (MainViewModel.cs)                │
│  - ObservableObject base class                             │
│  - [ObservableProperty] for state                          │
│  - [RelayCommand] for actions                              │
└─────────────────────────────────────────────────────────────┘
```

## Project Structure

```
Desktop/
├── MainPage.xaml.cs         # View - C# Markup UI (NO .xaml file needed!)
├── ViewModels/
│   └── MainViewModel.cs     # ViewModel - Business logic & state
├── App.xaml.cs              # App initialization + Theme loading
└── Desktop.csproj           # UnoFeatures enables CSharpMarkup
```

## Key Files

### MainPage.xaml.cs (View)
```csharp
public sealed partial class MainPage : Page
{
    public MainPage()
    {
        this.DataContext(new MainViewModel(), (page, vm) => page
            .Background(Theme.Brushes.Background.Default)
            .Content(
                new StackPanel()
                    .Spacing(16)
                    .Children(
                        new TextBlock()
                            .Text(() => vm.Title)
                            .FontSize(32),
                        new Button()
                            .Content("Click Me")
                            .Command(() => vm.IncrementCommand)
                    )
            )
        );
    }
}
```

### MainViewModel.cs (ViewModel)
```csharp
public partial class MainViewModel : ObservableObject
{
    [ObservableProperty]
    private int _count = 0;

    [RelayCommand]
    private void Increment() => Count++;
}
```

## UnoFeatures in .csproj

```xml
<UnoFeatures>
  CSharpMarkup;    <!-- Enables C# Markup fluent API -->
  Material;        <!-- Material Design theme -->
  Toolkit;        <!-- Uno Toolkit helpers -->
  Mvvm;           <!-- MVVM support -->
  ExtensionsCore; <!-- Core Uno extensions -->
  SkiaRenderer;   <!-- Skia rendering -->
</UnoFeatures>
```

## C# Markup Syntax

### DataContext with Binding Support
```csharp
this.DataContext(new MainViewModel(), (page, vm) => page
    // vm is available in all child binding expressions
);
```

### One-Way Binding (display)
```csharp
.Text(() => vm.PropertyName)
```

### Two-Way Binding (input)
```csharp
.Text(x => x.Binding(() => vm.Property).TwoWay())
```

### Command Binding
```csharp
.Command(() => vm.CommandNameCommand)
```

### Fluent Property Setters
```csharp
.FontSize(32)
.FontWeight(FontWeights.Bold)
.HorizontalAlignment(HorizontalAlignment.Center)
.Background(Theme.Brushes.Surface.Default)
```

### Grid Row/Column Attachment
```csharp
.Grid(row: 0, column: 1)
```

## Build & Run

```bash
cd src/apps/Desktop
dotnet build -f net10.0-desktop
dotnet run -f net10.0-desktop
```

## Reference

- Uno Platform C# Markup: https://platform.uno/docs/articles/features/uno-markup.html
- SimpleCalculator Sample: https://github.com/unoplatform/Uno.Samples/tree/master/reference/SimpleCalc/CSharp-MVVM/SimpleCalculator
- CommunityToolkit.Mvvm: https://learn.microsoft.com/en-us/dotnet/communitytoolkit/mvvm/
