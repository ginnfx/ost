using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using OstTracker.Networking;

namespace OstTracker.Views;

public sealed class HistoryPage : Page
{
    private readonly ListView _list = Ui.StringList("No history yet.");
    private readonly TextBox _title = new() { PlaceholderText = "Title to check (duplicates are blocked on submit)" };
    private readonly TextBlock _status = new();

    public HistoryPage()
    {
        Loaded += OnLoaded;
        var search = Ui.Button("Search matches");
        search.Click += async (_, _) => await SearchAsync();
        var refresh = Ui.Button("Show all");
        refresh.Click += async (_, _) => await RefreshAsync();

        Content = Ui.Stack("History", _list, _title, search, refresh, _status);
    }

    private void OnLoaded(object sender, RoutedEventArgs e) => _ = RefreshAsync();

    private async Task RefreshAsync()
    {
        try
        {
            var entries = await AppServices.Client!.GetHistory();
            _list.ItemsSource = entries.Select(h =>
                $"{h.Title}  ({h.Source ?? "?"})  — {h.BatchLabel ?? "?"}  from {h.Sender ?? "?"}").ToList();
            _status.Text = $"{entries.Count} past entries";
        }
        catch (Exception ex)
        {
            _status.Text = ex.Message;
        }
    }

    private async Task SearchAsync()
    {
        try
        {
            var matches = await AppServices.Client!.HistoryMatches(_title.Text, null);
            _list.ItemsSource = matches.Select(h =>
                $"{h.Title}  ({h.Source ?? "?"})  — {h.BatchLabel ?? "?"}").ToList();
            _status.Text = matches.Count == 0 ? "no matches — that title is free to submit" : $"{matches.Count} match(es) — resubmission blocked";
        }
        catch (Exception ex)
        {
            _status.Text = ex.Message;
        }
    }
}
