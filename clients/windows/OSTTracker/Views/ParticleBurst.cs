using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using OstTracker.Themes;
using Windows.Foundation;

namespace OstTracker.Views;

/// <summary>
/// Single-accent celebration when a rater saves a perfect 10 — the WinUI take
/// on the macOS ParticleBurst: 26 accent dots launch outward from one point
/// and fade over ~1.8 s. Purely decorative; hit-testing is disabled.
/// </summary>
public sealed class ParticleBurst : Canvas
{
    private const int Count = 26;
    private static readonly TimeSpan Life = TimeSpan.FromSeconds(1.8);
    private static readonly TimeSpan Frame = TimeSpan.FromMilliseconds(16);

    private sealed class Particle
    {
        public double Angle;
        public double Speed;
        public double Radius;
        public double Opacity;
    }

    private readonly DispatcherTimer _timer = new() { Interval = Frame };
    private readonly List<(Microsoft.UI.Xaml.Shapes.Ellipse dot, Particle p)> _particles = new();
    private double _elapsed;
    private double _centerX, _centerY;

    public ParticleBurst()
    {
        IsHitTestVisible = false;
        Visibility = Visibility.Collapsed;
        _timer.Tick += (_, _) => Tick();
    }

    /// <summary>Fire the burst (mac parity: called when score == 10); the
    /// origin defaults to this overlay's center.</summary>
    public void Fire(Point? origin = null)
    {
        _centerX = origin?.X ?? ActualWidth / 2;
        _centerY = origin?.Y ?? ActualHeight / 2;
        _elapsed = 0;
        Children.Clear();
        _particles.Clear();

        var accent = Theme.ParseHex(Theme.AccentDefault);
        var fill = new SolidColorBrush(accent);
        var random = Random.Shared;
        for (int i = 0; i < Count; i++)
        {
            var particle = new Particle
            {
                Angle = Math.PI * 2 * i / Count + random.NextDouble() * 0.4,
                Speed = 120 + random.NextDouble() * 130,
                Radius = 2 + random.NextDouble() * 2.5,
                Opacity = 0.9,
            };
            var dot = new Microsoft.UI.Xaml.Shapes.Ellipse
            {
                Width = particle.Radius * 2,
                Height = particle.Radius * 2,
                Fill = fill,
            };
            Children.Add(dot);
            _particles.Add((dot, particle));
        }
        Visibility = Visibility.Visible;
        _timer.Start();
    }

    private void Tick()
    {
        _elapsed += Frame.TotalSeconds;
        double t = _elapsed / Life.TotalSeconds;
        if (t >= 1)
        {
            _timer.Stop();
            Visibility = Visibility.Collapsed;
            return;
        }
        for (int i = 0; i < _particles.Count; i++)
        {
            var (dot, p) = _particles[i];
            double distance = p.Speed * _elapsed;
            double x = _centerX + Math.Cos(p.Angle) * distance;
            double y = _centerY + Math.Sin(p.Angle) * distance;
            Canvas.SetLeft(dot, x - p.Radius);
            Canvas.SetTop(dot, y - p.Radius);
            dot.Opacity = Math.Max(0, p.Opacity * (1 - t));
        }
    }
}
