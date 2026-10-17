using System.Text.Json;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using OstTracker.Networking;
using OstTracker.Themes;

namespace OstTracker.Views;

/// <summary>
/// Idle attract overlay — WinUI port of the macOS AttractOverlay: after 90s
/// without input a dark slide show of the leaderboard's cover art fades in
/// (10s cycle, pinned to the now-playing OST while one is on), and any
/// pointer move / key press / click wakes the app again.
/// </summary>
public sealed class AttractOverlay : Grid
{
    private const int IdleSeconds = 90;
    private const int SlideSeconds = 10;

    private readonly Image _cover = new()
    {
        Width = 320, Height = 320,
        Stretch = Stretch.UniformToFill,
        HorizontalAlignment = HorizontalAlignment.Center,
        Opacity = 0.92,
    };
    private readonly TextBlock _title = new()
    {
        FontSize = 24,
        FontWeight = Microsoft.UI.Text.FontWeights.Bold,
        HorizontalAlignment = HorizontalAlignment.Center,
        TextAlignment = TextAlignment.Center,
        TextWrapping = TextWrapping.Wrap,
    };
    private readonly TextBlock _hint = new()
    {
        Foreground = Ui.DimBrush,
        HorizontalAlignment = HorizontalAlignment.Center,
        Text = "Move the mouse to continue",
    };
    private readonly DispatcherTimer _idleTimer = new()
    { Interval = TimeSpan.FromSeconds(IdleSeconds) };
    private readonly DispatcherTimer _slideTimer = new()
    { Interval = TimeSpan.FromSeconds(SlideSeconds) };
    private readonly DispatcherTimer _clockTimer = new()
    { Interval = TimeSpan.FromSeconds(5) };

    private IReadOnlyList<RankEntry> _entries = new List<RankEntry>();
    private bool _revealed = true;
    private int _index;
    private bool _visible;
    private DateTime _lastInput = DateTime.UtcNow;
    private int _playingOstId = -1;

    public AttractOverlay()
    {
        Visibility = Visibility.Collapsed;
        Background = (Brush)Application.Current.Resources["BgBrush"];
        HorizontalAlignment = HorizontalAlignment.Stretch;
        VerticalAlignment = VerticalAlignment.Stretch;

        var stack = new StackPanel
        {
            Spacing = 12,
            VerticalAlignment = VerticalAlignment.Center,
            HorizontalAlignment = HorizontalAlignment.Center,
        };
        stack.Children.Add(_cover);
        stack.Children.Add(_title);
        stack.Children.Add(_hint);
        Children.Add(stack);

        _idleTimer.Tick += (_, _) => TryShow();
        _slideTimer.Tick += (_, _) => { if (_visible) AdvanceSlide(); };
        _clockTimer.Tick += (_, _) => RefreshPlayingId();

        if (AppServices.Events != null)
            AppServices.Events.EventReceived += OnEvent;

        // Input wakes the overlay; even swallowed input must count, so use the
        // handled-events-too form on the root of this overlay's host.
        PointerMoved += (_, _) => Wake();
        PointerPressed += (_, _) => Wake();
        KeyDown += (_, _) => Wake();
    }

    /// <summary>Start the idle watch. Call once from MainWindow.</summary>
    public void Start(Frame host)
    {
        host.PointerMoved += (_, _) => RegisterInput();
        host.PointerPressed += (_, _) => RegisterInput();
        host.KeyDown += (_, _) => RegisterInput();
        _idleTimer.Start();
        _clockTimer.Start();
    }

    private void RegisterInput()
    {
        _lastInput = DateTime.UtcNow;
        Wake();
    }

    private void OnEvent(string type, JsonElement payload)
    {
        if (type != "playbackState") return;
        DispatcherQueue.TryEnqueue(() =>
        {
            var status = payload.TryGetProperty("status", out var s) ? s.GetString() : null;
            if (status == "idle") _playingOstId = -1;
            else if (payload.TryGetProperty("ost_id", out var id) && id.ValueKind == JsonValueKind.Number)
                _playingOstId = id.GetInt32();
            if (_visible) AdvanceSlide(); // re-pin to the now-playing OST
        });
    }

    private void RefreshPlayingId() => _ = RefreshSlidesAsync();

    private async Task RefreshSlidesAsync()
    {
        try
        {
            var client = AppServices.Client;
            if (client == null) return;
            _entries = await client.GetLeaderboard();
            _revealed = (await client.GetReveal()).Unlocked;
        }
        catch
        {
            // idle decoration — network errors just keep the last known slide
        }
    }

    private async void TryShow()
    {
        if (_visible || (DateTime.UtcNow - _lastInput).TotalSeconds < IdleSeconds) return;
        await RefreshSlidesAsync();
        if (_entries.Count == 0) return;
        _index = 0;
        RenderSlide(ResolveEntry());
        _visible = true;
        Visibility = Visibility.Visible;
        _slideTimer.Start();
    }

    private RankEntry ResolveEntry()
    {
        var playing = _entries.FirstOrDefault(e => e.Ost.Id == _playingOstId);
        return playing ?? _entries[_index % _entries.Count];
    }

    private void AdvanceSlide()
    {
        if (_entries.Count == 0) return;
        var playing = _entries.FirstOrDefault(e => e.Ost.Id == _playingOstId);
        if (playing == null)
        {
            _index++;
            if (_index >= _entries.Count) _index = 0;
        }
        RenderSlide(playing ?? _entries[_index]);
    }

    private async void RenderSlide(RankEntry entry)
    {
        _cover.Source = await CoverLoader.LoadAsync(entry.Ost.CoverImagePath) ?? CoverLoader.Placeholder();
        string rank = _revealed && entry.Rank.HasValue ? $"  #{entry.Rank}" : "";
        _title.Text = entry.Ost.Title + rank;
    }

    private void Wake()
    {
        if (!_visible) return;
        _visible = false;
        Visibility = Visibility.Collapsed;
        _slideTimer.Stop();
    }
}
