namespace Desktop;

using Desktop.ViewModels;
using Uno.Extensions.Markup;
using Microsoft.UI;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

/// <summary>
/// MainPage View - Uses C# Markup with MVVM data binding.
/// 
/// Pattern: MVVM + C# Markup
/// - ViewModel is set via DataContext extension method
/// - UI controls are created using fluent C# Markup API
/// - Bindings use lambda expressions for type-safe connections
/// </summary>
public sealed partial class MainPage : Page
{
    public MainPage()
    {
        // Set DataContext with ViewModel, allowing binding expressions to access vm
        this.DataContext(new MainViewModel(), (page, vm) => page
            .Background(new SolidColorBrush(Colors.White))
            .Content(
                new ScrollViewer()
                    .VerticalScrollBarVisibility(ScrollBarVisibility.Auto)
                    .Content(
                        new StackPanel()
                            .Margin(24)
                            .Spacing(16)
                            .Children(
                                // Title
                                new TextBlock()
                                    .Text(() => vm.Title)
                                    .FontSize(32)
                                    .FontWeight(FontWeights.Bold)
                                    .HorizontalAlignment(HorizontalAlignment.Center),

                                // Subtitle/Message
                                new TextBlock()
                                    .Text(() => vm.Message)
                                    .FontSize(16)
                                    .Foreground(new SolidColorBrush(Colors.Gray))
                                    .HorizontalAlignment(HorizontalAlignment.Center),

                                // Separator
                                new Border()
                                    .Margin(8)
                                    .Height(1)
                                    .Background(new SolidColorBrush(Colors.LightGray)),

                                // Counter Section
                                new StackPanel()
                                    .Spacing(8)
                                    .Children(
                                        new TextBlock()
                                            .Text("Counter Demo")
                                            .FontSize(14)
                                            .FontWeight(FontWeights.SemiBold),

                                        // Counter Display Row
                                        new StackPanel()
                                            .Orientation(Orientation.Horizontal)
                                            .HorizontalAlignment(HorizontalAlignment.Center)
                                            .Spacing(12)
                                            .Children(
                                                // Decrement Button
                                                new Button()
                                                    .Width(50)
                                                    .Height(50)
                                                    .Content("-")
                                                    .Command(() => vm.DecrementCounterCommand),

                                                // Counter Display
                                                new Border()
                                                    .MinWidth(80)
                                                    .Padding(12)
                                                    .CornerRadius(4)
                                                    .Background(new SolidColorBrush(Colors.LightGray))
                                                    .Child(
                                                        new TextBlock()
                                                            .Text(() => vm.ClickCount, count => count.ToString())
                                                            .FontSize(24)
                                                            .FontWeight(FontWeights.Bold)
                                                            .HorizontalAlignment(HorizontalAlignment.Center)
                                                    ),

                                                // Increment Button
                                                new Button()
                                                    .Width(50)
                                                    .Height(50)
                                                    .Content("+")
                                                    .Command(() => vm.IncrementCounterCommand)
                                            ),

                                        // Command Buttons Row
                                        new StackPanel()
                                            .Orientation(Orientation.Horizontal)
                                            .HorizontalAlignment(HorizontalAlignment.Center)
                                            .Spacing(8)
                                            .Children(
                                                new Button()
                                                    .Content("Decrement")
                                                    .Command(() => vm.DecrementCounterCommand),
                                                new Button()
                                                    .Content("Increment")
                                                    .Command(() => vm.IncrementCounterCommand),
                                                new Button()
                                                    .Content("Reset")
                                                    .Command(() => vm.ResetCommand)
                                            )
                                    ),

                                // Separator
                                new Border()
                                    .Margin(8)
                                    .Height(1)
                                    .Background(new SolidColorBrush(Colors.LightGray)),

                                // Input Section
                                new StackPanel()
                                    .Spacing(8)
                                    .Children(
                                        new TextBlock()
                                            .Text("Input Demo")
                                            .FontSize(14)
                                            .FontWeight(FontWeights.SemiBold),

                                        new TextBox()
                                            .PlaceholderText("Enter some text...")
                                            .Text(x => x.Binding(() => vm.InputText).TwoWay())
                                            .Margin(0, 0, 0, 8),

                                        new Button()
                                            .HorizontalAlignment(HorizontalAlignment.Stretch)
                                            .Content("Process Input")
                                            .Command(() => vm.ProcessInputCommand)
                                    ),

                                // Status InfoBar
                                new InfoBar()
                                    .Title("MVVM Pattern")
                                    .Message("This app uses C# Markup + MVVM Toolkit for clean separation of concerns.")
                                    .Severity(InfoBarSeverity.Informational)
                                    .IsOpen(true)
                                    .IsClosable(false)
                            )
                    )
            )
        );
    }
}
