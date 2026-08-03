using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using OstTracker.Networking;

namespace OstTracker.Views;

public sealed class CoverPickerPage : Page
{
    private readonly ComboBox _osts = new() { PlaceholderText = "Pick an OST" };
    private readonly ListView _candidates = Ui.StringList("Pick an OST, then load candidates.");
    private readonly TextBlock _status = new();

    private List<Ost> _all = new();
    private List<CoverCandidate> _cands = new();

    public CoverPickerPage()
    {
        Loaded += OnLoaded;
        _osts.SelectionChanged += async (_, _) => await LoadCandidatesAsync();
        var set = Ui.Button("Apply selected candidate");
        set.Click += async (_, _) =>
        {
            int idx = _candidates.SelectedIndex;
            if (idx >= 0 && idx < _cands.Count && _osts.SelectedIndex >= 0)
            {
                await AppServices.Client!.SetCover(_all[_osts.SelectedIndex].Id, _cands[idx].ImageUrl);
                _status.Text = "cover updated";
            }
        };
        Content = Ui.Stack("Cover picker", _osts, _candidates, set, _status);
    }

    private void OnLoaded(object sender, RoutedEventArgs e) => _ = LoadOstsAsync();

    private async Task LoadOstsAsync()
    {
        try
        {
            _all = await AppServices.Client!.GetOsts();
            _osts.ItemsSource = _all.Select(o => $"{o.Title} ({o.SubmitterName ?? "?"})").ToList();
        }
        catch (Exception ex)
        {
            _status.Text = ex.Message;
        }
    }

    private async Task LoadCandidatesAsync()
    {
        if (_osts.SelectedIndex < 0 || _osts.SelectedIndex >= _all.Count) return;
        try
        {
            _cands = await AppServices.Client!.GetCoverCandidates(_all[_osts.SelectedIndex].Id);
            _candidates.ItemsSource = _cands.Select(c => $"{c.Label}  [{c.SourceName}]").ToList();
            _status.Text = $"{_cands.Count} candidates";
        }
        catch (Exception ex)
        {
            _status.Text = ex.Message;
        }
    }
}
