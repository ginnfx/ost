using Microsoft.UI.Xaml;
using OstTracker.Networking;
using Windows.Media.Core;
using Windows.Media.Playback;

namespace OstTracker.Playback;

/// <summary>
/// Audio sink for resolved stream URLs (MediaPlayer = AVPlayer counterpart).
/// Position/seek are advisory passthrough; all resolve logic stays in Python.
/// </summary>
public sealed class PlaybackService
{
    public static PlaybackService Instance { get; } = new();

    private MediaPlayer? _player;
    private string? _currentUri;

    public event Action<string>? PlaybackError;

    public void Play(string streamUrl, string? watchUrl)
    {
        if (_player != null && _currentUri == streamUrl)
        {
            // Same stream requested again (page + bar broadcast): resume
            // instead of restarting, like the Swift player sink.
            _player.Play();
            return;
        }
        Stop();
        try
        {
            _player = new MediaPlayer();
            _player.Source = MediaSource.CreateFromUri(new Uri(streamUrl));
            _currentUri = streamUrl;
            _player.Play();
        }
        catch (Exception)
        {
            _currentUri = null;
            // stream unplayable — fall back to the browser, like the Swift app
            PlaybackError?.Invoke(watchUrl ?? streamUrl);
        }
    }

    public void Pause()
    {
        if (_player != null) _player.Pause();
    }

    public void Resume()
    {
        if (_player != null) _player.Play();
    }

    public void Stop()
    {
        if (_player != null)
        {
            _player.Pause();
            _player.Source = null;
            _player.Dispose();
            _player = null;
        }
        _currentUri = null;
    }

    /// <summary>Seconds into the stream, for the synced-lyrics highlight.</summary>
    public double Position => _player?.PlaybackSession.Position.TotalSeconds ?? 0.0;

    public bool Playing => _player != null
        && _player.PlaybackSession.PlaybackState == MediaPlaybackState.Playing;

    public void Seek(double position)
    {
        if (_player != null)
        {
            var session = _player.PlaybackSession;
            session.Position = TimeSpan.FromSeconds(Math.Max(0, position));
        }
    }
}
