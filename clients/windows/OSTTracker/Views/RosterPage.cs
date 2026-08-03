using System.Text.Json;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using OstTracker.Networking;
using OstTracker.Playback;

namespace OstTracker.Views;

public sealed class RosterPage : Page
{
    private readonly ListView _list = Ui.StringList("No OSTs yet — add people and OSTs first.");
    private readonly TextBlock _status = new();

    public RosterPage()
    {
        Loaded += OnLoaded;
        _list.DoubleTapped += async (_, _) =>
        {
            if (_list.SelectedItem is string selected) await PlayAsync(selected);
        };
        var refresh = Ui.Button("Refresh");
        refresh.Click += async (_, _) => await RefreshAsync();
        Content = Ui.Stack("Roster", _list, refresh, _status);
    }

    private void OnLoaded(object sender, RoutedEventArgs e)
    {
        _ = RefreshAsync();
        if (AppServices.Events != null)
        {
            AppServices.Events.EventReceived += OnEvent;
            Unloaded += (_, _) => AppServices.Events.EventReceived -= OnEvent;
        }
    }

    private void OnEvent(string type, JsonElement payload)
    {
        if (type == "leaderboardResorted")
            DispatcherQueue.TryEnqueue(async () => await RefreshAsync());
    }

    private async Task RefreshAsync()
    {
        try
        {
            var entries = await AppServices.Client!.GetLeaderboard();
            _list.ItemsSource = entries.Select(r =>
                $"{Rank(r.Rank),-4} {Avg(r.Average),6}  {r.Ost.Title}  ({r.Ost.SubmitterName ?? "?"})").ToList();
            _status.Text = $"{entries.Count} ranked";
        }
        catch (Exception ex)
        {
            _status.Text = ex.Message;
        }
    }

    private async Task PlayAsync(string line)
    {
        try
        {
            var entries = await AppServices.Client!.GetLeaderboard();
            var match = entries.FirstOrDefault(r => line.Contains(r.Ost.Title, StringComparison.Ordinal));
            if (match == null) return;
            var state = await AppServices.Client.Play(match.Ost.Id);
            if (state.Status == "playing" && !string.IsNullOrEmpty(state.StreamUrl))
            {
                PlaybackService.Instance.Play(state.StreamUrl, state.WatchUrl);
            }
            else if (state.Status == "failed" && !string.IsNullOrEmpty(state.WatchUrl))
            {
                await Windows.System.Launcher.LaunchUriAsync(new Uri(state.WatchUrl));
            }
        }
        catch (Exception ex)
        {
            _status.Text = ex.Message;
        }
    }

    private static string Rank(int? rank) => rank.HasValue ? $"#{rank}" : "—";
    private static string Avg(double? avg) => avg.HasValue ? avg.Value.ToString("0.00") : "—";
}
