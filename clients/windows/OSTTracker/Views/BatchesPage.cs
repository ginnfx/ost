using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using OstTracker.Networking;

namespace OstTracker.Views;

public sealed class BatchesPage : Page
{
    private readonly ListView _list = Ui.StringList("No batches yet — randomize to arrange the OSTs into days.");
    private readonly ComboBox _count = new() { PlaceholderText = "Days (1–8)" };
    private readonly TextBlock _status = new();
    private bool _loaded;

    public BatchesPage()
    {
        Loaded += OnLoaded;
        _count.ItemsSource = Enumerable.Range(1, 8).Select(i => i.ToString()).ToList();

        var randomize = Ui.Button("Randomize");
        randomize.Click += async (_, _) =>
        {
            await AppServices.Client!.RandomizeBatches();
            await RefreshAsync();
        };
        _count.SelectionChanged += async (_, _) =>
        {
            if (!_loaded) return;   // no accidental write while the page first renders
            if (_count.SelectedItem is string s && int.TryParse(s, out int n))
            {
                await AppServices.Client!.PutBatchCount(n);
                await RefreshAsync();
            }
        };
        var refresh = Ui.Button("Refresh");
        refresh.Click += async (_, _) => await RefreshAsync();

        Content = Ui.Stack("Batches", _list, randomize, _count, refresh, _status);
    }

    private void OnLoaded(object sender, RoutedEventArgs e) => _ = RefreshAsync();

    private async Task RefreshAsync()
    {
        try
        {
            var batches = await AppServices.Client!.GetBatches();
            _list.ItemsSource = batches.Groups
                .Select(g => $"Day {g.Day}: " + string.Join(", ", g.Slots.Select(s => s.Ost.Title)))
                .ToList();
            _status.Text = batches.GeneratedAt is null ? "not yet generated" : $"generated {batches.GeneratedAt}";
            _loaded = true;
        }
        catch (Exception ex)
        {
            _status.Text = ex.Message;
        }
    }
}
