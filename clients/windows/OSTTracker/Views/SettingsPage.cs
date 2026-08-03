using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
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
        Content = Ui.Stack("Settings", _info, refresh);
    }

    private void OnLoaded(object sender, RoutedEventArgs e) => _ = LoadAsync();

    private async Task LoadAsync()
    {
        try
        {
            var board = await AppServices.Client!.GetElimination();
            _info.Text =
                $"Data dir:      {DataHome.Dir}\n" +
                $"Sidecar port:  {SidecarProcess.Instance.Port}\n" +
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
