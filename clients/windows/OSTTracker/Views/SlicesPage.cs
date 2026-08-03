using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using OstTracker.Networking;

namespace OstTracker.Views;

public sealed class SlicesPage : Page
{
    private readonly ListView _list = Ui.StringList("No board yet.");
    private readonly TextBox _threshold = new() { PlaceholderText = "Threshold (1–20)" };
    private readonly TextBlock _status = new();

    public SlicesPage()
    {
        Loaded += OnLoaded;
        var save = Ui.Button("Set threshold");
        save.Click += async (_, _) =>
        {
            if (int.TryParse(_threshold.Text, out int t))
            {
                await AppServices.Client!.PutThreshold(t);
                await RefreshAsync();
            }
        };
        var refresh = Ui.Button("Refresh");
        refresh.Click += async (_, _) => await RefreshAsync();

        Content = Ui.Stack("Slice elimination", _list, _threshold, save, refresh, _status);
    }

    private void OnLoaded(object sender, RoutedEventArgs e) => _ = RefreshAsync();

    private async Task RefreshAsync()
    {
        try
        {
            var board = await AppServices.Client!.GetElimination();
            var lines = new List<string>();
            foreach (var slice in board.Slices)
            {
                string tally = string.Join(", ", slice.Tallies.Select(t =>
                    $"{t.Name} (out here {t.OutHere}/{t.TotalOut}{(t.EliminatedHere ? " ✗" : "")})"));
                lines.Add($"{slice.Label}: {tally}");
            }
            foreach (var s in board.Survivors)
                lines.Add($"safe: {s.Name} ({s.Remaining} left)");
            foreach (var e in board.Eliminated)
                lines.Add($"ELIMINATED #{e.Place}: {e.Name} at rank {e.OutAtRank}");
            _list.ItemsSource = lines;
            _threshold.Text = board.Threshold.ToString();
            _status.Text = $"{board.RankedCount} ranked, slice size {board.SliceSize}";
        }
        catch (Exception ex)
        {
            _status.Text = ex.Message;
        }
    }
}
