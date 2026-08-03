using System.Net.Http.Json;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace OstTracker.Networking;

/// <summary>
/// Thin HTTP client for the sidecar. Every call is delegation only — all
/// business logic stays in Python, exactly like the Swift BackendClient.
/// </summary>
public sealed class OstClient
{
    public static readonly JsonSerializerOptions Json = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.SnakeCaseLower,
        PropertyNameCaseInsensitive = true,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
    };

    private readonly HttpClient _http;

    public OstClient(int port, string token)
    {
        _http = new HttpClient { BaseAddress = new Uri($"http://127.0.0.1:{port}/") };
        _http.DefaultRequestHeaders.Add("X-OST-Token", token);
    }

    private async Task<T> GetAsync<T>(string path, CancellationToken ct = default)
    {
        using var resp = await _http.GetAsync(path, ct);
        await EnsureOk(resp, ct);
        return (await resp.Content.ReadFromJsonAsync<T>(Json, ct))!;
    }

    private async Task<T> SendAsync<T>(HttpMethod method, string path, object? body = null, CancellationToken ct = default)
    {
        using var req = new HttpRequestMessage(method, path);
        if (body != null) req.Content = JsonContent.Create(body, options: Json);
        using var resp = await _http.SendAsync(req, ct);
        await EnsureOk(resp, ct);
        return (await resp.Content.ReadFromJsonAsync<T>(Json, ct))!;
    }

    private async Task SendNoBodyAsync(HttpMethod method, string path, object? body = null, CancellationToken ct = default)
    {
        using var req = new HttpRequestMessage(method, path);
        if (body != null) req.Content = JsonContent.Create(body, options: Json);
        using var resp = await _http.SendAsync(req, ct);
        await EnsureOk(resp, ct);
    }

    private static async Task EnsureOk(HttpResponseMessage resp, CancellationToken ct)
    {
        if (resp.IsSuccessStatusCode) return;
        string detail = "";
        try
        {
            using var doc = await JsonDocument.ParseAsync(await resp.Content.ReadAsStreamAsync(ct), cancellationToken: ct);
            if (doc.RootElement.TryGetProperty("detail", out var d)) detail = d.GetString() ?? "";
        }
        catch (JsonException) { /* non-JSON error body */ }
        throw new OstApiException((int)resp.StatusCode, detail);
    }

    // people
    public Task<List<Person>> GetPeople(CancellationToken ct = default) => GetAsync<List<Person>>("people", ct);
    public Task<Person> AddPerson(string name, CancellationToken ct = default) => SendAsync<Person>(HttpMethod.Post, "people", new PersonIn(name), ct);
    public Task DeletePerson(int id, CancellationToken ct = default) => SendNoBodyAsync(HttpMethod.Delete, $"people/{id}", null, ct);

    // osts
    public Task<List<Ost>> GetOsts(CancellationToken ct = default) => GetAsync<List<Ost>>("osts", ct);
    public Task<Ost> AddOst(OstIn body, CancellationToken ct = default) => SendAsync<Ost>(HttpMethod.Post, "osts", body, ct);
    public Task<Ost> PatchOst(int id, OstPatch body, CancellationToken ct = default) => SendAsync<Ost>(HttpMethod.Patch, $"osts/{id}", body, ct);
    public Task DeleteOst(int id, CancellationToken ct = default) => SendNoBodyAsync(HttpMethod.Delete, $"osts/{id}", null, ct);
    public Task ResolveOst(int id, CancellationToken ct = default) => SendNoBodyAsync(HttpMethod.Post, $"osts/{id}/resolve", null, ct);

    // history
    public Task<List<HistoryEntry>> GetHistory(CancellationToken ct = default) => GetAsync<List<HistoryEntry>>("history", ct);
    public Task<List<HistoryEntry>> HistoryMatches(string? title, string? source, CancellationToken ct = default)
        => GetAsync<List<HistoryEntry>>($"history/matches?title={Uri.EscapeDataString(title ?? "")}&source={Uri.EscapeDataString(source ?? "")}", ct);

    // ratings
    public Task<List<Rating>> GetRatings(CancellationToken ct = default) => GetAsync<List<Rating>>("ratings", ct);
    public Task PutRating(int ostId, int raterId, double? score, CancellationToken ct = default)
        => SendAsync<object>(HttpMethod.Put, "ratings", new RatingIn(ostId, raterId, score), ct);

    // notes
    public Task<List<Note>> GetNotes(CancellationToken ct = default) => GetAsync<List<Note>>("notes", ct);
    public Task<Note> AddNote(string title, string? note, CancellationToken ct = default) => SendAsync<Note>(HttpMethod.Post, "notes", new NoteIn(title, note), ct);
    public Task<Note> PatchNote(int id, NotePatch body, CancellationToken ct = default) => SendAsync<Note>(HttpMethod.Patch, $"notes/{id}", body, ct);
    public Task DeleteNote(int id, CancellationToken ct = default) => SendNoBodyAsync(HttpMethod.Delete, $"notes/{id}", null, ct);

    // leaderboard / elimination
    public Task<List<RankEntry>> GetLeaderboard(CancellationToken ct = default) => GetAsync<List<RankEntry>>("leaderboard", ct);
    public Task<EliminationBoard> GetElimination(CancellationToken ct = default) => GetAsync<EliminationBoard>("elimination", ct);
    public Task<EliminationBoard> PutThreshold(int threshold, CancellationToken ct = default)
        => SendAsync<EliminationBoard>(HttpMethod.Put, "elimination/threshold", new EliminationThresholdIn(threshold), ct);

    // batches
    public Task<Batches> GetBatches(CancellationToken ct = default) => GetAsync<Batches>("batches", ct);
    public Task<Batches> RandomizeBatches(CancellationToken ct = default) => SendAsync<Batches>(HttpMethod.Post, "batches/randomize", null, ct);
    public Task<Batches> PutBatchCount(int count, CancellationToken ct = default) => SendAsync<Batches>(HttpMethod.Put, "batches/count", new BatchCountIn(count), ct);
    public Task<Batches> ArrangeBatches(IReadOnlyList<IReadOnlyList<int>> batches, CancellationToken ct = default)
        => SendAsync<Batches>(HttpMethod.Post, "batches/arrange", new BatchArrangeIn(batches), ct);
    public Task<Batches> PinBatch(int ostId, bool pinned, CancellationToken ct = default)
        => SendAsync<Batches>(HttpMethod.Post, "batches/pin", new BatchPinIn(ostId, pinned), ct);

    // player
    public Task<PlaybackState> Play(int ostId, CancellationToken ct = default) => SendAsync<PlaybackState>(HttpMethod.Post, "player/play", new PlayIn(ostId), ct);
    public Task<PlaybackState> Pause(CancellationToken ct = default) => SendAsync<PlaybackState>(HttpMethod.Post, "player/pause", null, ct);
    public Task<PlaybackState> Seek(double position, CancellationToken ct = default) => SendAsync<PlaybackState>(HttpMethod.Post, "player/seek", new SeekIn(position), ct);
    public Task<PlaybackState> Stop(CancellationToken ct = default) => SendAsync<PlaybackState>(HttpMethod.Post, "player/stop", null, ct);

    // covers
    public Task<List<CoverCandidate>> GetCoverCandidates(int ostId, CancellationToken ct = default)
        => GetAsync<List<CoverCandidate>>($"osts/{ostId}/cover/candidates", ct);
    public Task<Ost> SetCover(int ostId, string imageUrl, CancellationToken ct = default)
        => SendAsync<Ost>(HttpMethod.Post, $"osts/{ostId}/cover", new CoverSetIn(imageUrl), ct);
}

public sealed record CoverCandidate(string ImageUrl, string? ThumbUrl, string Label, string SourceName);

public sealed class OstApiException : Exception
{
    public int Status { get; }
    public OstApiException(int status, string detail) : base(detail) => Status = status;
}
