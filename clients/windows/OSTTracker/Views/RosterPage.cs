using System.Text.Json;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using OstTracker.Networking;
using OstTracker.Playback;
using OstTracker.Themes;

namespace OstTracker.Views;

/// <summary>Roster as cover cards — rank badge, accent tint, search/filter,
/// click → detail, double-click → play. Mirrors the macOS roster.</summary>
public sealed class RosterPage : Page
{
    private readonly ScrollViewer _scroll = new();
    private readonly StackPanel _cards = new() { Spacing = 10 };
    private readonly TextBox _search = new() { PlaceholderText = "Search" };
    private readonly ComboBox _filter = new() { PlaceholderText = "All submitters" };
    private readonly TextBlock _status = new();
    private bool _revealed = true;

    private List<RankEntry> _entries = new();

    public RosterPage()
    {
        Loaded += OnLoaded;
        _search.TextChanged += (_, _) => _ = RenderAsync();
        _filter.SelectionChanged += (_, _) => _ = RenderAsync();
        var refresh = Ui.Button("Refresh");
        refresh.Click += async (_, _) => await LoadAsync();
        var searchRow = Ui.HStack(_search, _filter, refresh);

        _scroll.Content = _cards;
        Content = Ui.Stack("Roster", searchRow, _scroll, _status);
    }

    private void OnLoaded(object sender, RoutedEventArgs e)
    {
        _ = LoadAsync();
        if (AppServices.Events != null)
        {
            AppServices.Events.EventReceived += OnEvent;
            Unloaded += (_, _) => AppServices.Events.EventReceived -= OnEvent;
        }
    }

    private void OnEvent(string type, JsonElement payload)
    {
        if (type is "leaderboardResorted" or "revealState" or "coverArtReady")
            DispatcherQueue.TryEnqueue(async () => await LoadAsync());
    }

    private async Task LoadAsync()
    {
        try
        {
            _entries = await AppServices.Client!.GetLeaderboard();
            _revealed = (await AppServices.Client.GetReveal()).Unlocked;
            var people = await AppServices.Client.GetPeople();
            _filter.ItemsSource = people.Select(p => p.Name).ToList();
            await RenderAsync();
        }
        catch (Exception ex)
        {
            _status.Text = ex.Message;
        }
    }

    private async Task RenderAsync()
    {
        _cards.Children.Clear();
        string query = _search.Text.Trim();
        string? submitter = _filter.SelectedItem as string;
        var visible = _entries.Where(e =>
            (query.Length == 0 || e.Ost.Title.Contains(query, StringComparison.OrdinalIgnoreCase))
            && (submitter == null || e.Ost.SubmitterName == submitter)).ToList();

        foreach (var entry in visible)
        {
            _cards.Children.Add(await BuildCard(entry));
        }
        _status.Text = $"{visible.Count} of {_entries.Count} — reveal {( _revealed ? "unlocked" : "locked")}";
    }

    private async Task<Border> BuildCard(RankEntry entry)
    {
        var cover = new Image { Width = 96, Height = 96, Stretch = Stretch.UniformToFill };
        var bmp = await CoverLoader.LoadAsync(entry.Ost.CoverImagePath);
        cover.Source = bmp ?? CoverLoader.Placeholder();

        var title = new TextBlock { Text = entry.Ost.Title, FontWeight = FontWeights.SemiBold, TextTrimming = TextTrimming.CharacterEllipsis };
        var submit = new TextBlock { Text = entry.Ost.SubmitterName ?? "?", Foreground = Ui.DimBrush, FontSize = 12 };
        var score = new TextBlock
        {
            Text = entry.Average.HasValue ? entry.Average.Value.ToString("0.00") : "—",
            FontWeight = FontWeights.Bold,
        };

        string rankText = _revealed && entry.Rank.HasValue ? $"#{entry.Rank}" : "·";
        var badge = new Border
        {
            Style = (Style)Application.Current.Resources[RankStyle(entry.Rank, _revealed)],
            Child = new TextBlock { Text = rankText, FontSize = 12, FontWeight = FontWeights.Bold },
            VerticalAlignment = VerticalAlignment.Top,
            HorizontalAlignment = HorizontalAlignment.Left,
            Margin = new Thickness(6),
        };

        var accent = Theme.ParseHex(entry.Ost.CoverAccentHex);
        var card = new Border
        {
            Style = (Style)Application.Current.Resources["CardBorder"],
            BorderBrush = new SolidColorBrush(ColorFromArgb(90, accent)),
            Padding = new Thickness(10),
        };
        card.PointerPressed += (_, _) => _ = OpenDetailAsync(entry.Ost.Id);
        card.DoubleTapped += async (_, _) => await PlayAsync(entry);

        var text = new StackPanel { Spacing = 2, VerticalAlignment = VerticalAlignment.Center };
        text.Children.Add(title);
        text.Children.Add(submit);
        text.Children.Add(score);

        var row = new Grid { ColumnSpacing = 12 };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        row.Children.Add(cover);
        Grid.SetColumn(text, 1);
        row.Children.Add(text);

        var root = new Grid();
        root.Children.Add(row);
        root.Children.Add(badge);
        card.Child = root;
        return card;
    }

    private static string RankStyle(int? rank, bool revealed)
    {
        if (!revealed || rank is null) return "RankBadge";
        return rank switch
        {
            1 => "RankBadgeGold",
            2 => "RankBadgePink",
            3 => "RankBadgeRust",
            _ => "RankBadgeDim",
        };
    }

    private static Windows.UI.Color ColorFromArgb(byte a, Windows.UI.Color c) =>
        Windows.UI.Color.FromArgb(a, c.R, c.G, c.B);

    private async Task OpenDetailAsync(int ostId)
    {
        if (MainWindow.ContentFrame is Frame frame)
            DetailPage.Navigate(frame, ostId);
        await Task.CompletedTask;
    }

    private async Task PlayAsync(RankEntry entry)
    {
        try
        {
            NowPlayingBar.Instance?.SetNowPlaying(entry.Ost.Title, entry.Ost.CoverImagePath);
            var state = await AppServices.Client!.Play(entry.Ost.Id);
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
}
