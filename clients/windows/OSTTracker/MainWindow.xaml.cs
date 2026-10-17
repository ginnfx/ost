using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using OstTracker.Sidecar;

namespace OstTracker;

public sealed partial class MainWindow : Window
{
    public static MainWindow? Instance { get; private set; }
    public static Frame? NavigationFrame { get; private set; }

    public MainWindow()
    {
        Instance = this;
        InitializeComponent();
        NavigationFrame = ContentFrame;

        // Bottom now-playing bar in the second grid row.
        var bar = new Views.NowPlayingBar();
        Grid.SetRow(bar, 1);
        ((Grid)Content).Children.Add(bar);

        // Idle attract overlay floats across both rows.
        var attract = new Views.AttractOverlay();
        Grid.SetRow(attract, 0);
        Grid.SetRowSpan(attract, 2);
        ((Grid)Content).Children.Add(attract);
        attract.Start(NavigationFrame);

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
                case "roster": NavigationFrame!.Navigate(typeof(Views.RosterPage)); break;
                case "people": NavigationFrame!.Navigate(typeof(Views.PeoplePage)); break;
                case "entry": NavigationFrame!.Navigate(typeof(Views.EntryPage)); break;
                case "addost": NavigationFrame!.Navigate(typeof(Views.AddOstPage)); break;
                case "stats": NavigationFrame!.Navigate(typeof(Views.StatsPage)); break;
                case "batches": NavigationFrame!.Navigate(typeof(Views.BatchesPage)); break;
                case "slices": NavigationFrame!.Navigate(typeof(Views.SlicesPage)); break;
                case "reveal": NavigationFrame!.Navigate(typeof(Views.RevealPage)); break;
                case "history": NavigationFrame!.Navigate(typeof(Views.HistoryPage)); break;
                case "cover": NavigationFrame!.Navigate(typeof(Views.CoverPickerPage)); break;
                case "notes": NavigationFrame!.Navigate(typeof(Views.NotesPage)); break;
                case "settings": NavigationFrame!.Navigate(typeof(Views.SettingsPage)); break;
            }
        }
    }

    private void OnClosed(object sender, WindowEventArgs args)
    {
        // Job Object teardown: kills the whole sidecar tree.
        SidecarProcess.Instance.Shutdown();
    }
}
