using OstTracker.Networking;
using OstTracker.Sidecar;

namespace OstTracker;

/// <summary>Shared app state: sidecar handle, HTTP client, WS pump.</summary>
public static class AppServices
{
    public static OstClient? Client { get; private set; }
    public static WsPump? Events { get; private set; }

    /// <summary>Launch the sidecar, then wire the client + event pump.</summary>
    public static async Task<bool> StartAsync()
    {
        try
        {
            var (port, token) = await SidecarProcess.Instance.LaunchAsync();
            Client = new OstClient(port, token);
            Events = new WsPump(port, token);
            Events.Start();
            return true;
        }
        catch (Exception)
        {
            return false;
        }
    }

    public static void Shutdown()
    {
        Events?.DisposeAsync().AsTask().GetAwaiter().GetResult();
        SidecarProcess.Instance.Shutdown();
    }
}
