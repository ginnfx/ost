using System.Text.Json;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using OstTracker.Themes;

namespace OstTracker.Views;

/// <summary>
/// Centered spectrum ribbon down in the bottom bar — the WinUI take on the
/// macOS SpectrumView. MediaPlayer exposes no PCM tap, so live bands measured
/// like the Swift MTAudioProcessingTap don't exist here; the display runs the
/// exact ambient motion the Mac shows when it has no signal, goes silent to
/// the silhouette when paused, and drops out entirely when idle.
/// </summary>
public sealed class VisualizerBar : Grid
{
    private const int BandCount = 48;
    private static readonly TimeSpan Frame = TimeSpan.FromMilliseconds(33);

    private readonly List<Microsoft.UI.Xaml.Shapes.Rectangle> _bars = new();
    private readonly DispatcherTimer _timer = new() { Interval = Frame };
    private bool _playing;
    private bool _idle = true;

    public VisualizerBar()
    {
        Width = 150;
        Height = 26;
        VerticalAlignment = VerticalAlignment.Center;

        ColumnDefinitions.Clear();
        for (int i = 0; i < BandCount; i++)
            ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });

        var accent = Theme.ParseHex(Theme.AccentDefault);
        var fill = new SolidColorBrush(accent);
        for (int i = 0; i < BandCount; i++)
        {
            var bar = new Microsoft.UI.Xaml.Shapes.Rectangle
            {
                Fill = fill,
                RadiusX = 1,
                RadiusY = 1,
                Opacity = 0.55,
                VerticalAlignment = VerticalAlignment.Stretch,
                MinHeight = 2,
            };
            Grid.SetColumn(bar, i);
            Children.Add(bar);
            _bars.Add(bar);
        }

        if (AppServices.Events != null)
            AppServices.Events.EventReceived += OnEvent;
        _timer.Tick += (_, _) => Tick();
        _timer.Start();
    }

    private void OnEvent(string type, JsonElement payload)
    {
        if (type != "playbackState") return;
        DispatcherQueue.TryEnqueue(() =>
        {
            var status = payload.TryGetProperty("status", out var s) ? s.GetString() : null;
            if (status == null) return;
            _playing = status == "playing";
            _idle = status == "idle";
        });
    }

    private void Tick()
    {
        if (_idle)
        {
            foreach (var bar in _bars) bar.Height = 2;
            return;
        }
        double now = Environment.TickCount64 / 1000.0;
        for (int i = 0; i < _bars.Count; i++)
        {
            double unit = _bars.Count < 2 ? 0 : (double)i / (_bars.Count - 1);
            double level;
            if (_playing)
            {
                // Ambient wave — SpectrumView's ambient fallback, mirrored.
                double wave = Math.Sin(now * 3.1 + unit * 13) * Math.Sin(now * 1.7 - unit * 21);
                level = 0.11 + 0.10 * (wave + 1) / 2;
            }
            else
            {
                level = 0;
            }
            double silhouette = 0.035 + 0.045 * Math.Pow(Math.Max(0, Math.Sin(Math.PI * unit)), 0.7);
            double edge = 0.22 + 0.78 * Math.Pow(Math.Max(0, Math.Sin(Math.PI * unit)), 0.42);
            level = Math.Max(silhouette, Math.Pow(level, 0.78) * edge);
            _bars[i].Height = Math.Max(2, Math.Min(Height * 0.43, level * Height * 0.59));
        }
    }
}
