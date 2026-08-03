using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using OstTracker.Networking;

namespace OstTracker.Views;

/// <summary>
/// The ranked board. The Python side decides when the reveal unlocks; this
/// client renders whatever /leaderboard returns (rank gating mirrors the
/// macOS app once the reveal-setting endpoint exists in the contract).
/// </summary>
public sealed class RevealPage : Page
{
    private readonly ListView _list = Ui.StringList("No standings yet.");
    private readonly TextBlock _status = new();

    public RevealPage()
    {
        Loaded += OnLoaded;
        var refresh = Ui.Button("Refresh");
        refresh.Click += async (_, _) => await RefreshAsync();
        Content = Ui.Stack("Reveal", _list, refresh, _status);
    }

    private void OnLoaded(object sender, RoutedEventArgs e) => _ = RefreshAsync();

    private async Task RefreshAsync()
    {
        try
        {
            var entries = await AppServices.Client!.GetLeaderboard();
            _list.ItemsSource = entries
                .OrderBy(r => r.Rank ?? int.MaxValue)
                .Select(r => r.Rank.HasValue
                    ? $"#{r.Rank,3}  {r.Ost.Title,-40}  {r.Average?.ToString("0.00") ?? "—"}"
                    : $"—     {r.Ost.Title,-40}  (unrated)")
                .ToList();
            _status.Text = $"{entries.Count} OSTs";
        }
        catch (Exception ex)
        {
            _status.Text = ex.Message;
        }
    }
}
