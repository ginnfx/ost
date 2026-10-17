using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using OstTracker.Networking;
using OstTracker.Playback;
using OstTracker.Themes;

namespace OstTracker.Views;

/// <summary>Detail view for one OST: big cover, info, per-rater scores,
/// playback controls, synced-lyrics takeover, delete — mirrors the macOS
/// DetailView + player takeover. Lyrics are a client-side LRCLIB lookup;
/// highlight follows the local MediaPlayer position, tap a line to seek.</summary>
public sealed class DetailPage : Page
{
    /// <summary>ListView row: Time for seek-on-tap, Text for display.</summary>
    private sealed record LyricRow(double Time, string Text)
    {
        public override string ToString() => Text;
    }

    private readonly int _ostId;
    private readonly Image _cover = new() { Width = 220, Height = 220, Stretch = Stretch.UniformToFill };
    private readonly TextBlock _title = new() { FontSize = 24, FontWeight = Microsoft.UI.Text.FontWeights.Bold, TextWrapping = TextWrapping.Wrap };
    private readonly TextBlock _info = new() { Foreground = Ui.DimBrush, TextWrapping = TextWrapping.Wrap };
    private readonly ListView _scores = Ui.StringList("No ratings yet.");
    private readonly TextBlock _status = new();
    private readonly Button _lyricsToggle = Ui.Button("Lyrics");

    private readonly ListView _lyricsList = new()
    {
        SelectionMode = ListViewSelectionMode.None,
        IsItemClickEnabled = true,
    };
    private readonly TextBlock _lyricsStatus = new() { Foreground = Ui.DimBrush };
    private readonly Grid _lyricsPanel = new() { Visibility = Visibility.Collapsed };

    private IReadOnlyList<LyricLine>? _synced;
    private int _lyricsIndex = -1;
    private bool _lyricsLoaded;
    private readonly DispatcherTimer _lyricsTimer = new() { Interval = TimeSpan.FromMilliseconds(200) };

    public DetailPage()
    {
        _ostId = (int)(FrameParameter ?? 0);
        Loaded += OnLoaded;
        Unloaded += (_, _) => _lyricsTimer.Stop();
        var play = Ui.Button("Play");
        play.Click += async (_, _) => await PlayAsync();
        var stop = Ui.Button("Stop");
        stop.Click += async (_, _) =>
        {
            PlaybackService.Instance.Stop();
            await AppServices.Client!.Stop();
        };
        var link = Ui.Button("Open link");
        link.Click += async (_, _) => await OpenLinkAsync();
        var delete = Ui.Button("Delete");
        delete.Click += async (_, _) => { await AppServices.Client!.DeleteOst(_ostId); Back(); };
        _lyricsToggle.Click += (_, _) => _ = ToggleLyricsAsync();

        _lyricsPanel.Children.Add(_lyricsList);
        _lyricsList.ItemClick += OnLyricClicked;
        _lyricsTimer.Tick += (_, _) => OnLyricsTick();

        Content = Ui.Stack("", Ui.HStack(_cover, new StackPanel
        {
            Spacing = 6,
            Children = { _title, _info, Ui.HStack(play, stop, _lyricsToggle, link, delete) },
        }), _scores, _lyricsStatus, _status);
    }

    private static object? FrameParameter;

    /// <summary>Navigate here with the OST id as the parameter.</summary>
    public static void Navigate(Frame frame, int ostId)
    {
        FrameParameter = ostId;
        frame.Navigate(typeof(DetailPage));
    }

    private void OnLoaded(object sender, RoutedEventArgs e) => _ = LoadAsync();

    private async Task LoadAsync()
    {
        try
        {
            var osts = await AppServices.Client!.GetOsts();
            var ost = osts.FirstOrDefault(o => o.Id == _ostId);
            if (ost == null) { _status.Text = "OST not found"; return; }

            _title.Text = ost.Title;
            _info.Text = $"{ost.Source ?? "no source"} · by {ost.SubmitterName ?? "?"}\n{(ost.ExternalLink ?? "no link")}";
            _cover.Source = await CoverLoader.LoadAsync(ost.CoverImagePath) ?? CoverLoader.Placeholder();

            var ratings = await AppServices.Client.GetRatings();
            var rows = ratings.Where(r => r.OstId == _ostId)
                .OrderByDescending(r => r.Score)
                .Select(r => $"{r.RaterName}: {r.Score:0.##}");
            _scores.ItemsSource = rows.ToList();
            _status.Text = $"{rows.Count()} scores";
        }
        catch (Exception ex)
        {
            _status.Text = ex.Message;
        }
    }

    // --- lyrics takeover ----------------------------------------------------------------

    private async Task ToggleLyricsAsync()
    {
        if (!_lyricsLoaded)
        {
            _lyricsLoaded = true;
            _lyricsToggle.IsEnabled = false;
            try
            {
                var osts = await AppServices.Client!.GetOsts();
                var ost = osts.FirstOrDefault(o => o.Id == _ostId);
                if (ost == null) { _lyricsStatus.Text = "OST not found"; return; }
                var result = await LyricsService.FetchAsync(ost, null);
                if (result == null) { _lyricsStatus.Text = "No lyrics found."; }
                else if (result.Synced is { Count: > 0 } lines)
                {
                    _synced = lines;
                    _lyricsList.ItemsSource = lines.Select(l => (object)new LyricRow(l.Time, l.Text)).ToList();
                    _lyricsTimer.Start();
                }
                else if (result.Plain is { Length: > 0 } plain)
                {
                    _lyricsList.ItemsSource = plain.Split('\n').Select(l => (object)new LyricRow(0, l)).ToList();
                }
            }
            catch (Exception ex)
            {
                _lyricsStatus.Text = ex.Message;
            }
            finally
            {
                _lyricsToggle.IsEnabled = true;
            }
        }
        bool showing = _lyricsPanel.Visibility == Visibility.Visible;
        _lyricsPanel.Visibility = showing ? Visibility.Collapsed : Visibility.Visible;
        _scores.Visibility = showing ? Visibility.Visible : Visibility.Collapsed;
    }

    private void OnLyricClicked(object sender, ItemClickEventArgs e)
    {
        if (e.ClickedItem is LyricRow { Time: > 0 } row)
        {
            try { _ = AppServices.Client!.Seek(row.Time); } catch (Exception) { /* advisory */ }
            PlaybackService.Instance.Seek(row.Time);
        }
    }

    /// <summary>5Hz tick like the Swift TimelineView: find the last line whose
    /// timestamp passed and scroll-center it, dimming sung lines.</summary>
    private void OnLyricsTick()
    {
        if (_synced == null || _lyricsPanel.Visibility != Visibility.Visible) return;
        if (!PlaybackService.Instance.Playing) return;

        double position = PlaybackService.Instance.Position;
        int current = -1;
        for (int i = 0; i < _synced.Count; i++)
        {
            if (_synced[i].Time <= position + 0.2) current = i;
            else break;
        }
        if (current == _lyricsIndex) return;
        _lyricsIndex = current;

        if (current >= 0 && _lyricsList.ContainerFromIndex(current) is ListViewItem row)
        {
            row.Opacity = 1.0;
            _lyricsList.ScrollIntoView(_lyricsList.Items[current]);
        }
        _lyricsStatus.Text = current >= 0 ? "" : "Instrumental section…";
    }

    private async Task PlayAsync()
    {
        try
        {
            var state = await AppServices.Client!.Play(_ostId);
            if (state.Status == "playing" && !string.IsNullOrEmpty(state.StreamUrl))
            {
                PlaybackService.Instance.Play(state.StreamUrl, state.WatchUrl);
            }
            else if (state.Status == "failed" && !string.IsNullOrEmpty(state.WatchUrl))
            {
                await Windows.System.Launcher.LaunchUriAsync(new Uri(state.WatchUrl));
            }
        }
        catch (Exception ex) { _status.Text = ex.Message; }
    }

    private async Task OpenLinkAsync()
    {
        var osts = await AppServices.Client!.GetOsts();
        var ost = osts.FirstOrDefault(o => o.Id == _ostId);
        if (ost?.ExternalLink is string link && Uri.TryCreate(link, UriKind.Absolute, out var uri))
            await Windows.System.Launcher.LaunchUriAsync(uri);
    }

    private void Back()
    {
        if (MainWindow.NavigationFrame is Frame frame && frame.CanGoBack) frame.GoBack();
        else MainWindow.Instance?.Close();
    }
}
