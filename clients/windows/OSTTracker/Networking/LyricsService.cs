using System.Globalization;
using System.Net.Http.Json;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;

namespace OstTracker.Networking;

/// <summary>
/// LRCLIB lyrics — C# mirror of the macOS LyricsService: synced lines parsed
/// from LRC, plain lyrics as fallback via lyrics.ovh, instrumentation sheets
/// rejected, production hits cached on disk. HTTP is client-side exactly like
/// the Swift app (the sidecar never sees lyrics).
/// </summary>
public static class LyricsService
{
    private const string LrclibSearch = "https://lrclib.net/api/search";
    private const string LyricsOvh = "https://api.lyrics.ovh/v1/{0}/{1}";

    private static readonly string[] CreditMarkers =
    {
        "saxophone", "recording", "engineer", "mixing", "mastering", "produced by",
        "guitar", "studio", "vocals", "arranged by",
    };

    private static readonly HttpClient Http = new() { Timeout = TimeSpan.FromSeconds(10) };

    private static readonly JsonSerializerOptions Wire = new(JsonSerializerDefaults.Web)
    {
        ReadCommentHandling = JsonCommentHandling.Skip,
        AllowTrailingCommas = true,
    };

    public static string CacheKey(Ost ost)
    {
        string identity = $"{ost.Id}|{ost.Title.ToLowerInvariant()}|{(ost.Source ?? "").ToLowerInvariant()}";
        return Convert.ToHexString(MD5.HashData(Encoding.UTF8.GetBytes(identity)));
    }
    public static async Task<LyricsResult?> FetchAsync(Ost ost, double? duration, CancellationToken ct = default)
    {
        var cacheDir = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "OSTTracker", "lyrics");
        var hit = Read(cacheDir, CacheKey(ost));
        if (hit != null) return hit;

        var result = await FetchUncachedAsync(ost, duration, ct);
        if (result != null) Write(cacheDir, CacheKey(ost), result);
        return result;
    }

    internal static async Task<LyricsResult?> FetchUncachedAsync(Ost ost, double? duration, CancellationToken ct)
    {
        var queries = string.IsNullOrEmpty(ost.Source)
            ? new[] { ost.Title }
            : new[] { ost.Title, $"{ost.Title} {ost.Source}" };

        var rows = new List<LrclibTrack>();
        foreach (var query in queries)
        {
            string url = $"{LrclibSearch}?q={Uri.EscapeDataString(query)}";
            try
            {
                using var req = new HttpRequestMessage(HttpMethod.Get, url);
                req.Headers.UserAgent.ParseAdd("OSTTracker/1.0");
                using var resp = await Http.SendAsync(req, ct);
                if (resp.IsSuccessStatusCode)
                {
                    var parsed = await resp.Content.ReadFromJsonAsync<List<LrclibTrack>>(Wire, ct);
                    if (parsed != null) rows.AddRange(parsed);
                }
            }
            catch (Exception ex) when (ex is HttpRequestException or TaskCanceledException) { /* offline */ }
        }

        LyricsResult? synced = null;
        string? plain = null;
        string? artist = null;
        foreach (var row in rows)
        {
            artist ??= EmptyToNull(row.ArtistName);
            if (synced is null && !string.IsNullOrWhiteSpace(row.SyncedLyrics)
                && !LooksLikeCredits(row.SyncedLyrics))
            {
                var lines = ParseLrc(row.SyncedLyrics);
                if (lines.Count >= 4) synced = new LyricsResult(lines, null);
            }
        }
        if (synced is null)
        {
            plain = rows.Select(r => CleanPlain(r.PlainLyrics)).FirstOrDefault(t => t != null)
                   ?? (artist is null ? null : await LyricsOvhAsync(artist, ost.Title, ct));
        }
        if (synced is not null) return synced;
        if (plain is not null) return new LyricsResult(null, plain);
        return null;
    }

    private static async Task<string?> LyricsOvhAsync(string artist, string title, CancellationToken ct)
    {
        string url = string.Format(
            CultureInfo.InvariantCulture, LyricsOvh,
            Uri.EscapeDataString(artist), Uri.EscapeDataString(title));
        try
        {
            using var resp = await Http.GetAsync(url, ct);
            if (!resp.IsSuccessStatusCode) return null;
            var payload = await resp.Content.ReadFromJsonAsync<Dictionary<string, string>>(Wire, ct);
            return CleanPlain(payload?.GetValueOrDefault("lyrics"));
        }
        catch (Exception ex) when (ex is HttpRequestException or TaskCanceledException)
        {
            return null;
        }
    }

    public static List<LyricLine> ParseLrc(string raw)
    {
        var lines = new List<LyricLine>();
        foreach (var rawLine in raw.Split('\n'))
        {
            var match = Regex.Match(rawLine.Trim(), @"^\[(\d+):(\d+(?:\.\d+)?)\](.*)$");
            if (!match.Success) continue;
            double time = double.Parse(match.Groups[1].Value, CultureInfo.InvariantCulture) * 60
                + double.Parse(match.Groups[2].Value, CultureInfo.InvariantCulture);
            string text = match.Groups[3].Value.Trim();
            lines.Add(new LyricLine(time, text.Length == 0 ? "♪" : text));
        }
        return lines.OrderBy(l => l.Time).ToList();
    }

    private static string? CleanPlain(string? text)
    {
        if (string.IsNullOrWhiteSpace(text)) return null;
        var value = text.Trim();
        return value.Length >= 40 && !LooksLikeCredits(value) ? value : null;
    }

    private static bool LooksLikeCredits(string text)
    {
        var lines = text.Split('\n')
            .Select(l => l.Trim())
            .Where(l => l.Length > 0 && l != "♪")
            .ToList();
        if (lines.Count < 3) return false;
        bool IsCredit(string line)
        {
            if (line.Contains(':')) return true;
            var lower = line.ToLowerInvariant();
            return CreditMarkers.Any(lower.Contains);
        }
        int creditLines = lines.Count(IsCredit);
        return creditLines >= 3 && creditLines * 2 >= lines.Count;
    }

    private static string? EmptyToNull(string? value) => string.IsNullOrWhiteSpace(value) ? null : value;

    // --- cache -------------------------------------------------------------

    private static object CacheProject(LyricsResult result) => new
    {
        synced = result.Synced?.Select(l => (object)new { l.Time, l.Text }).ToList(),
        result.Plain,
    };

    private static LyricsResult? Read(string directory, string key)
    {
        try
        {
            var json = File.ReadAllText(Path.Combine(directory, $"{key}.json"));
            var node = JsonSerializer.Deserialize<CacheNode>(json, Wire);
            return node == null ? null : new LyricsResult(node.Synced, node.Plain);
        }
        catch (Exception)
        {
            return null;
        }
    }

    private static void Write(string directory, string key, LyricsResult result)
    {
        try
        {
            Directory.CreateDirectory(directory);
            var payload = JsonSerializer.Serialize(CacheProject(result));
            File.WriteAllText(Path.Combine(directory, $"{key}.json"), payload);
        }
        catch (Exception)
        {
            // cache write failure is harmless
        }
    }

    private sealed class CacheNode
    {
        [JsonPropertyName("synced")] public List<LyricLine>? Synced { get; set; }
        [JsonPropertyName("plain")] public string? Plain { get; set; }
    }

    private sealed record LrclibTrack(string? ArtistName, string? SyncedLyrics, string? PlainLyrics);
}
