using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using OstTracker.Sidecar;

namespace OstTracker;

public sealed partial class MainWindow : Window
{
    public static MainWindow? Instance { get; private set; }
    public static Frame? ContentFrame { get; private set; }

    public MainWindow()
    {
        Instance = this;
        InitializeComponent();
        ContentFrame = this.FindName("ContentFrame") as Frame;

        // Bottom now-playing bar in the second grid row.
        var bar = new Views.NowPlayingBar();
        Grid.SetRow(bar, 1);
        ((Grid)Content).Children.Add(bar);

        Closed += OnClosed;
    }

    private void Nav_Loaded(object sender, RoutedEventArgs e)
    {
        Nav.SelectedItem = Nav.MenuItems[0];
    }

    private void Nav_SelectionChanged(NavigationView sender, NavigationViewSelectionChangedEventArgs args)
    {
        if (args.SelectedItem is NavigationViewItem item && item.Tag is string tag)
        {
            switch (tag)
            {
                case "roster": ContentFrame.Navigate(typeof(Views.RosterPage)); break;
                case "people": ContentFrame.Navigate(typeof(Views.PeoplePage)); break;
                case "entry": ContentFrame.Navigate(typeof(Views.EntryPage)); break;
                case "stats": ContentFrame.Navigate(typeof(Views.StatsPage)); break;
                case "batches": ContentFrame.Navigate(typeof(Views.BatchesPage)); break;
                case "slices": ContentFrame.Navigate(typeof(Views.SlicesPage)); break;
                case "reveal": ContentFrame.Navigate(typeof(Views.RevealPage)); break;
                case "history": ContentFrame.Navigate(typeof(Views.HistoryPage)); break;
                case "cover": ContentFrame.Navigate(typeof(Views.CoverPickerPage)); break;
                case "notes": ContentFrame.Navigate(typeof(Views.NotesPage)); break;
                case "settings": ContentFrame.Navigate(typeof(Views.SettingsPage)); break;
            }
        }
    }

    private void OnClosed(object sender, WindowEventArgs args)
    {
        // Job Object teardown: kills the whole sidecar tree.
        SidecarProcess.Instance.Shutdown();
    }
}
