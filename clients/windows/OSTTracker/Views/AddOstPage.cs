using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using OstTracker.Networking;

namespace OstTracker.Views;

/// <summary>Add-OST form — mirrors the macOS AddOstView: title, source,
/// required submitter, optional external link, and a live duplicate hint
/// against the past-round history before submission.</summary>
public sealed class AddOstPage : Page
{
    private readonly TextBox _title = new() { PlaceholderText = "Title (required)" };
    private readonly TextBox _source = new() { PlaceholderText = "Source (album / series, optional)" };
    private readonly TextBox _link = new() { PlaceholderText = "External link (YouTube URL, optional)" };
    private readonly ComboBox _submitter = new()
    {
        PlaceholderText = "Pick a submitter",
        HorizontalAlignment = HorizontalAlignment.Stretch,
    };
    private readonly TextBlock _hint = new()
    {
        Foreground = Ui.DimBrush,
        TextWrapping = TextWrapping.Wrap,
    };
    private readonly TextBlock _status = new();
    private readonly Button _submit = Ui.Button("Add OST");

    private List<Person> _people = new();
    private List<HistoryEntry> _history = new();
    private bool _submitting;

    public AddOstPage()
    {
        Loaded += OnLoaded;
        _title.TextChanged += (_, _) => Hint();
        _source.TextChanged += (_, _) => Hint();
        _submitter.SelectionChanged += (_, _) => Hint();
        _submit.Click += async (_, _) => await SubmitAsync();

        var form = new StackPanel { Spacing = 10, MinWidth = 420, HorizontalAlignment = HorizontalAlignment.Left };
        form.Children.Add(_title);
        form.Children.Add(_source);
        form.Children.Add(_link);
        form.Children.Add(_submitter);
        form.Children.Add(_submit);
        Content = Ui.Stack("Add OST", form, _hint, _status);
    }

    private void OnLoaded(object sender, RoutedEventArgs e) => _ = LoadAsync();

    private async Task LoadAsync()
    {
        try
        {
            _people = await AppServices.Client!.GetPeople();
            _history = await AppServices.Client!.GetHistory();
            _submitter.ItemsSource = _people.Select(p => p.Name).ToList();
            Hint();
        }
        catch (Exception ex)
        {
            _status.Text = ex.Message;
        }
    }

    /// <summary>Client-side duplicate hint — same rule as the Swift
    /// AddOstRules.historyConflict: same title, sources match unless either
    /// side's source is unknown. The backend 400 stays the real enforcement.</summary>
    private HistoryEntry? Conflict()
    {
        string title = _title.Text.Trim();
        if (title.Length == 0) return null;
        string source = _source.Text.Trim().ToLowerInvariant();
        return _history.FirstOrDefault(h =>
        {
            if (!string.Equals(h.Title.Trim(), title, StringComparison.InvariantCultureIgnoreCase)) return false;
            string entrySource = (h.Source ?? "").Trim().ToLowerInvariant();
            return entrySource.Length == 0 || source.Length == 0 || entrySource == source;
        });
    }

    private bool Ready() =>
        _title.Text.Trim().Length > 0
        && _submitter.SelectedIndex >= 0
        && !_submitting
        && Conflict() == null;

    private void Hint()
    {
        var conflict = Conflict();
        if (conflict != null)
        {
            string source = conflict.Source is { Length: > 0 } ? $" ({conflict.Source})" : "";
            _hint.Text = $"⚠ Likely duplicate of a past round: “{conflict.Title}”{source}";
        }
        else if (_title.Text.Trim().Length == 0 || _submitter.SelectedIndex < 0)
        {
            _hint.Text = "Title and a roster submitter are required.";
        }
        else
        {
            _hint.Text = "";
        }
        _submit.IsEnabled = Ready();
    }

    private async Task SubmitAsync()
    {
        if (!Ready()) { _status.Text = "Fill the title and pick a submitter first."; return; }
        var submitter = _people[_submitter.SelectedIndex];
        try
        {
            _submitting = true;
            _submit.IsEnabled = false;
            var ost = await AppServices.Client!.AddOst(new OstIn(
                Title: _title.Text.Trim(),
                Source: _source.Text.Trim().Length > 0 ? _source.Text.Trim() : null,
                SubmitterId: submitter.Id,
                ExternalLink: _link.Text.Trim().Length > 0 ? _link.Text.Trim() : null));
            _status.Text = $"Added “{ost.Title}” (id {ost.Id})";
            _title.Text = "";
            _source.Text = "";
            _link.Text = "";
            Hint();
        }
        catch (Exception ex)
        {
            _status.Text = ex.Message;
        }
        finally
        {
            _submitting = false;
            _submit.IsEnabled = Ready();
        }
    }
}
