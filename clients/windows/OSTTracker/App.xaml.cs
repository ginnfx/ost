using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace OstTracker;

public partial class App : Application
{
    private Window? _window;

    public App()
    {
        InitializeComponent();
    }

    protected override async void OnLaunched(LaunchActivatedEventArgs args)
    {
        bool ok = await AppServices.StartAsync();
        _window = new MainWindow();
        _window.Activate();

        if (!ok)
        {
            var dialog = new ContentDialog
            {
                Title = "Sidecar failed to start",
                Content = "Could not launch the Python backend. Check the install (python-runtime + backend) and try again.",
                CloseButtonText = "Exit",
                XamlRoot = _window.Content.XamlRoot,
            };
            await dialog.ShowAsync();
            AppServices.Shutdown();
            _window.Close();
        }
    }
}
