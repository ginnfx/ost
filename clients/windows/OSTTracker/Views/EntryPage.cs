using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using OstTracker.Networking;

namespace OstTracker.Views;

/// <summary>Bulk entry by rater: pick a person, then type scores into each OST row.</summary>
public sealed class EntryPage : Page
{
    private readonly ComboBox _person = new() { PlaceholderText = "Pick a rater" };
    private readonly StackPanel _rows = new() { Spacing = 4 };
    private readonly ScrollViewer _scroll = new();
    private readonly TextBlock _status = new();

    private List<Person> _people = new();
    private List<Ost> _osts = new();
    private Dictionary<int, double> _ratings = new();

    public EntryPage()
    {
        Loaded += OnLoaded;
        _person.SelectionChanged += async (_, _) => await LoadRatingsAsync();
        _scroll.Content = _rows;
        Content = Ui.Stack("Entry", _person, _scroll, _status);
    }

    private void OnLoaded(object sender, RoutedEventArgs e) => _ = LoadAsync();

    private async Task LoadAsync()
    {
        try
        {
            _people = await AppServices.Client!.GetPeople();
            _osts = await AppServices.Client.GetOsts();
            _person.ItemsSource = _people.Select(p => p.Name).ToList();
            if (_people.Count > 0) _person.SelectedIndex = 0;
            if (_people.Count == 0) _status.Text = "Add people first.";
        }
        catch (Exception ex)
        {
            _status.Text = ex.Message;
        }
    }

    private async Task LoadRatingsAsync()
    {
        int idx = _person.SelectedIndex;
        if (idx < 0 || idx >= _people.Count) return;
        int raterId = _people[idx].Id;
        _rows.Children.Clear();
        try
        {
            var ratings = await AppServices.Client!.GetRatings();
            _ratings = ratings.Where(r => r.RaterId == raterId).ToDictionary(r => r.OstId, r => r.Score);
            foreach (var ost in _osts)
            {
                var title = new TextBlock
                {
                    Text = ost.Title,
                    VerticalAlignment = VerticalAlignment.Center,
                    Width = 340,
                    TextTrimming = Microsoft.UI.Xaml.TextTrimming.CharacterEllipsis,
                };
                var box = new TextBox
                {
                    Width = 64,
                    Text = _ratings.TryGetValue(ost.Id, out double s) ? s.ToString("0.##") : "",
                };
                box.Tag = ost.Id;
                box.KeyUp += async (_, e) =>
                {
                    if (e.Key == Windows.System.VirtualKey.Enter) await SaveScore(box);
                };
                box.LostFocus += async (_, _) => await SaveScore(box);

                var row = new Grid { ColumnSpacing = 8 };
                row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Auto) });
                row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
                row.Children.Add(title);
                Grid.SetColumn(box, 1);
                row.Children.Add(box);
                _rows.Children.Add(row);
            }
            int rated = _ratings.Count;
            _status.Text = $"{rated}/{_osts.Count} rated for {_people[idx].Name}";
        }
        catch (Exception ex)
        {
            _status.Text = ex.Message;
        }
    }

    private async Task SaveScore(TextBox box)
    {
        int idx = _person.SelectedIndex;
        if (idx < 0) return;
        int ostId = (int)box.Tag;
        double? score = null;
        if (!string.IsNullOrWhiteSpace(box.Text) && double.TryParse(box.Text, out double parsed))
            score = parsed;
        try
        {
            await AppServices.Client!.PutRating(ostId, _people[idx].Id, score);
            if (score.HasValue) _ratings[ostId] = score.Value;
            else _ratings.Remove(ostId);
            _status.Text = $"{_ratings.Count}/{_osts.Count} rated for {_people[idx].Name}";
        }
        catch (Exception ex)
        {
            _status.Text = ex.Message;
        }
    }
}
