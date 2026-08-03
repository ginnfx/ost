using System.Text.Json;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using OstTracker.Playback;
using OstTracker.Themes;

namespace OstTracker.Views;

/// <summary>Bottom now-playing bar: cover, title, play/pause, stop. State comes
/// from the /ws playbackState events; transport goes to /player.</summary>
public sealed class NowPlayingBar : Grid
{
    public static NowPlayingBar? Instance { get; private set; }

    private readonly Image _cover = new() { Width = 44, Height = 44, Stretch = Stretch.UniformToFill };
    private readonly TextBlock _title = new() { Text = "Nothing playing", TextTrimming = TextTrimming.CharacterEllipsis };
    private readonly TextBlock _status = new() { Foreground = Ui.DimBrush, FontSize = 12 };
    private readonly Button _play = new() { Content = "Play" };
    private readonly Button _stop = new() { Content = "Stop" };

    public NowPlayingBar()
    {
        Instance = this;
        Padding = new Thickness(12, 8);
        Background = (Brush)Application.Current.Resources["BgRaisedBrush"];
        ColumnSpacing = 10;

        ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        var text = new StackPanel { Spacing = 2, VerticalAlignment = VerticalAlignment.Center };
        text.Children.Add(_title);
        text.Children.Add(_status);

        _play.Click += async (_, _) =>
        {
            try
            {
                if (_playing) await AppServices.Client!.Pause();
                else await AppServices.Client!.Play(_currentOstId);
            }
            catch (Exception ex) { _status.Text = ex.Message; }
        };
        _stop.Click += async (_, _) =>
        {
            try
            {
                PlaybackService.Instance.Stop();
                await AppServices.Client!.Stop();
                _playing = false;
                _play.Content = "Play";
                _status.Text = "stopped";
            }
            catch (Exception ex) { _status.Text = ex.Message; }
        };

        Children.Add(_cover);
        Grid.SetColumn(text, 1);
        Children.Add(text);
        Grid.SetColumn(_play, 2);
        Children.Add(_play);
        Grid.SetColumn(_stop, 3);
        Children.Add(_stop);

        if (AppServices.Events != null)
            AppServices.Events.EventReceived += OnEvent;
    }

    private bool _playing;
    private int _currentOstId = -1;

    public void SetNowPlaying(string title, string? coverPath)
    {
        _title.Text = title;
        _ = LoadCoverAsync(coverPath);
    }

    private async Task LoadCoverAsync(string? path)
    {
        _cover.Source = await CoverLoader.LoadAsync(path) ?? CoverLoader.Placeholder();
    }

    private void OnEvent(string type, JsonElement payload)
    {
        if (type != "playbackState") return;
        DispatcherQueue.TryEnqueue(() =>
        {
            if (payload.TryGetProperty("status", out var status))
            {
                string s = status.GetString() ?? "";
                _playing = s == "playing";
                _play.Content = _playing ? "Pause" : "Play";
                if (s == "idle") _title.Text = "Nothing playing";
                _status.Text = s;
            }
            if (payload.TryGetProperty("ost_id", out var ostId) && ostId.ValueKind == JsonValueKind.Number)
                _currentOstId = ostId.GetInt32();
        });
    }
}
