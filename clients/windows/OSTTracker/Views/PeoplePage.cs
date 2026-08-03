using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using OstTracker.Networking;

namespace OstTracker.Views;

public sealed class PeoplePage : Page
{
    private readonly ListView _list = Ui.StringList("No people yet.");
    private readonly TextBox _name = new() { PlaceholderText = "Name" };
    private readonly TextBlock _status = new();

    public PeoplePage()
    {
        Loaded += OnLoaded;
        var add = Ui.Button("Add");
        add.Click += async (_, _) => await AddAsync();
        var remove = Ui.Button("Remove selected");
        remove.Click += async (_, _) => await RemoveAsync();
        var refresh = Ui.Button("Refresh");
        refresh.Click += async (_, _) => await RefreshAsync();

        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        row.Children.Add(new TextBlock { Text = "New person:", VerticalAlignment = VerticalAlignment.Center });
        row.Children.Add(_name);
        row.Children.Add(add);

        Content = Ui.Stack("People", _list, row, remove, refresh, _status);
    }

    private void OnLoaded(object sender, RoutedEventArgs e) => _ = RefreshAsync();

    private async Task RefreshAsync()
    {
        try
        {
            var people = await AppServices.Client!.GetPeople();
            _list.ItemsSource = people.Select(p => $"{p.Id}: {p.Name}").ToList();
            _status.Text = $"{people.Count} people";
        }
        catch (Exception ex)
        {
            _status.Text = ex.Message;
        }
    }

    private async Task AddAsync()
    {
        if (string.IsNullOrWhiteSpace(_name.Text)) return;
        await AppServices.Client!.AddPerson(_name.Text.Trim());
        _name.Text = "";
        await RefreshAsync();
    }

    private async Task RemoveAsync()
    {
        if (_list.SelectedItem is not string selected) return;
        if (!int.TryParse(selected.Split(':')[0], out int id)) return;
        await AppServices.Client!.DeletePerson(id);
        await RefreshAsync();
    }
}
