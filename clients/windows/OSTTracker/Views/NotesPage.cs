using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using OstTracker.Networking;

namespace OstTracker.Views;

public sealed class NotesPage : Page
{
    private readonly ListView _list = Ui.StringList("No notes.");
    private readonly TextBox _title = new() { PlaceholderText = "Title" };
    private readonly TextBox _note = new() { PlaceholderText = "Note", AcceptsReturn = true, Height = 90 };
    private readonly TextBlock _status = new();

    private int _selectedId = -1;

    public NotesPage()
    {
        Loaded += OnLoaded;
        var add = Ui.Button("Add");
        add.Click += async (_, _) =>
        {
            await AppServices.Client!.AddNote(_title.Text, _note.Text);
            _title.Text = ""; _note.Text = "";
            await RefreshAsync();
        };
        var delete = Ui.Button("Delete selected");
        delete.Click += async (_, _) =>
        {
            if (_selectedId > 0) { await AppServices.Client!.DeleteNote(_selectedId); _selectedId = -1; await RefreshAsync(); }
        };
        var refresh = Ui.Button("Refresh");
        refresh.Click += async (_, _) => await RefreshAsync();

        var form = new StackPanel { Spacing = 6 };
        form.Children.Add(_title);
        form.Children.Add(_note);
        form.Children.Add(add);
        form.Children.Add(delete);

        _list.SelectionChanged += (_, _) =>
        {
            if (_list.SelectedItem is string line && int.TryParse(line.Split(':')[0], out int id)) _selectedId = id;
        };

        Content = Ui.Stack("Notes", _list, form, refresh, _status);
    }

    private void OnLoaded(object sender, RoutedEventArgs e) => _ = RefreshAsync();

    private async Task RefreshAsync()
    {
        try
        {
            var notes = await AppServices.Client!.GetNotes();
            _list.ItemsSource = notes.Select(n => $"{n.Id}: {n.Title} — {n.Text ?? ""}").ToList();
            _status.Text = $"{notes.Count} notes (scratchpad only — never part of standings)";
        }
        catch (Exception ex)
        {
            _status.Text = ex.Message;
        }
    }
}
