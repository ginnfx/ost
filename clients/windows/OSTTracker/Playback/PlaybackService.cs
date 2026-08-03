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

    public event Action<string>? PlaybackError;

    public void Play(string streamUrl, string? watchUrl)
    {
        Stop();
        try
        {
            _player = new MediaPlayer();
            _player.Source = MediaSource.CreateFromUri(new Uri(streamUrl));
            _player.Play();
        }
        catch (Exception)
        {
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
    }
}
