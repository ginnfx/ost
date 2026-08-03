using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using OstTracker.Networking;

namespace OstTracker.Views;

public sealed class StatsPage : Page
{
    private readonly ListView _list = Ui.StringList("No ratings yet.");
    private readonly TextBlock _status = new();

    public StatsPage()
    {
        Loaded += OnLoaded;
        var refresh = Ui.Button("Refresh");
        refresh.Click += async (_, _) => await RefreshAsync();
        Content = Ui.Stack("Stats", _list, refresh, _status);
    }

    private void OnLoaded(object sender, RoutedEventArgs e) => _ = RefreshAsync();

    private async Task RefreshAsync()
    {
        try
        {
            var entries = await AppServices.Client!.GetLeaderboard();
            _list.ItemsSource = entries.Select(r =>
            {
                string avg = r.Average.HasValue ? r.Average.Value.ToString("0.00") : "—";
                string min = r.Minimum.HasValue ? r.Minimum.Value.ToString("0.0") : "—";
                string max = r.Maximum.HasValue ? r.Maximum.Value.ToString("0.0") : "—";
                string sd = r.Stddev.HasValue ? r.Stddev.Value.ToString("0.00") : "—";
                return $"{r.Ost.Title,-40} n={r.RatingCount,2}  avg {avg,6}  min {min,4}  max {max,4}  σ {sd}";
            }).ToList();
            _status.Text = $"{entries.Count} OSTs";
        }
        catch (Exception ex)
        {
            _status.Text = ex.Message;
        }
    }
}
