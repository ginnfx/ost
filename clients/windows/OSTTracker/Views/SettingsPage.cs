using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using OstTracker.Networking;
using OstTracker.Sidecar;

namespace OstTracker.Views;

public sealed class SettingsPage : Page
{
    private readonly TextBlock _info = new() { TextWrapping = TextWrapping.Wrap };

    public SettingsPage()
    {
        Loaded += OnLoaded;
        var refresh = Ui.Button("Refresh");
        refresh.Click += async (_, _) => await LoadAsync();
        Content = Ui.Stack("Settings", _info, BuildAccentPicker(), refresh);
    }

    private void OnLoaded(object sender, RoutedEventArgs e) => _ = LoadAsync();

    /// <summary>Chrome accent presets, mirroring the macOS Settings picker.</summary>
    private UIElement BuildAccentPicker()
    {
        var label = new TextBlock { Text = "Chrome accent:", VerticalAlignment = VerticalAlignment.Center };
        var row = Ui.HStack();
        foreach (var hex in Themes.Theme.PresetHexes)
        {
            var swatch = new Border
            {
                Width = 28,
                Height = 28,
                CornerRadius = new CornerRadius(14),
                Background = new SolidColorBrush(Themes.Theme.ParseHex(hex)),
                BorderThickness = new Thickness(1),
                BorderBrush = new SolidColorBrush(Windows.UI.Color.FromArgb(120, 255, 255, 255)),
            };
            swatch.PointerPressed += (_, _) =>
            {
                Windows.Storage.ApplicationData.Current.LocalSettings.Values["accentHex"] = hex;
                _info.Text = $"Chrome accent set to {hex}";
            };
            row.Children.Add(swatch);
        }
        return Ui.HStack(label, row);
    }

    private async Task LoadAsync()
    {
        try
        {
            var board = await AppServices.Client!.GetElimination();
            var saved = Windows.Storage.ApplicationData.Current.LocalSettings.Values["accentHex"] as string;
            _info.Text =
                $"Data dir:      {DataHome.Dir}\n" +
                $"Sidecar port:  {SidecarProcess.Instance.Port}\n" +
                $"Chrome accent: {saved ?? Themes.Theme.AccentDefault} (tap a swatch to change)\n" +
                $"Elimination threshold: {board.Threshold} (edit on the Slices page)\n" +
                $"Elimination slice size: {board.SliceSize}\n\n" +
                "OST Tracker for Windows — the Python sidecar does all the work;\n" +
                "this UI is just a contract client. Cover art, ratings, batches,\n" +
                "elimination, history, notes and export all live in the backend.";
        }
        catch (Exception ex)
        {
            _info.Text = ex.Message;
        }
    }
}
