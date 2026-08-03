using System.Net.WebSockets;
using System.Text;
using System.Text.Json;

namespace OstTracker.Networking;

/// <summary>
/// The /ws event pump: reconnects with backoff and dispatches parsed envelopes
/// to subscribers — the C# mirror of the Swift AppStore event pump.
/// </summary>
public sealed class WsPump : IAsyncDisposable
{
    public event Action<string, JsonElement>? EventReceived;

    private readonly Uri _uri;
    private readonly string _token;
    private CancellationTokenSource _cts = new();
    private Task? _loop;

    public WsPump(int port, string token)
    {
        _uri = new Uri($"ws://127.0.0.1:{port}/ws");
        _token = token;
    }

    public void Start()
    {
        _cts = new CancellationTokenSource();
        _loop = Task.Run(() => RunLoopAsync(_cts.Token));
    }

    private async Task RunLoopAsync(CancellationToken ct)
    {
        int delayMs = 500;
        while (!ct.IsCancellationRequested)
        {
            try
            {
                using var ws = new ClientWebSocket();
                ws.Options.SetRequestHeader("X-OST-Token", _token);
                ws.Options.KeepAliveInterval = TimeSpan.FromSeconds(20);
                await ws.ConnectAsync(_uri, ct);
                delayMs = 500;
                await ReceiveLoopAsync(ws, ct);
            }
            catch (OperationCanceledException) when (ct.IsCancellationRequested)
            {
                return;
            }
            catch (Exception)
            {
                // socket dropped — back off and reconnect
            }
            try { await Task.Delay(delayMs, ct); } catch (OperationCanceledException) { return; }
            delayMs = Math.Min(delayMs * 2, 10_000);
        }
    }

    private async Task ReceiveLoopAsync(ClientWebSocket ws, CancellationToken ct)
    {
        var buffer = new byte[64 * 1024];
        var stream = new MemoryStream();
        while (!ct.IsCancellationRequested && ws.State == WebSocketState.Open)
        {
            stream.SetLength(0);
            WebSocketReceiveResult result;
            do
            {
                result = await ws.ReceiveAsync(new ArraySegment<byte>(buffer), ct);
                if (result.MessageType == WebSocketMessageType.Close) return;
                stream.Write(buffer, 0, result.Count);
            } while (!result.EndOfMessage);

            using var doc = JsonDocument.Parse(stream.ToArray());
            if (doc.RootElement.TryGetProperty("type", out var type) &&
                doc.RootElement.TryGetProperty("payload", out var payload))
            {
                EventReceived?.Invoke(type.GetString() ?? "", payload.Clone());
            }
        }
    }

    public async ValueTask DisposeAsync()
    {
        _cts.Cancel();
        if (_loop != null)
        {
            try { await _loop; } catch { /* cancelled */ }
        }
        _cts.Dispose();
    }
}
