using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using OstTracker.Networking;
using OstTracker.Playback;
using OstTracker.Themes;

namespace OstTracker.Views;

/// <summary>Detail view for one OST: big cover, info, per-rater scores,
/// playback controls, edit/delete — mirrors the macOS DetailView.</summary>
public sealed class DetailPage : Page
{
    private readonly int _ostId;
    private readonly Image _cover = new() { Width = 220, Height = 220, Stretch = Stretch.UniformToFill };
    private readonly TextBlock _title = new() { FontSize = 24, FontWeight = Microsoft.UI.Text.FontWeights.Bold, TextWrapping = TextWrapping.Wrap };
    private readonly TextBlock _info = new() { Foreground = Ui.DimBrush, TextWrapping = TextWrapping.Wrap };
    private readonly ListView _scores = Ui.StringList("No ratings yet.");
    private readonly TextBlock _status = new();

    public DetailPage()
    {
        _ostId = (int)(FrameParameter ?? 0);
        Loaded += OnLoaded;
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

        Content = Ui.Stack("", Ui.HStack(_cover, new StackPanel
        {
            Spacing = 6,
            Children = { _title, _info, Ui.HStack(play, stop, link, delete) },
        }), _scores, _status);
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
        if (MainWindow.ContentFrame is Frame frame && frame.CanGoBack) frame.GoBack();
        else MainWindow.Instance?.Close();
    }
}
