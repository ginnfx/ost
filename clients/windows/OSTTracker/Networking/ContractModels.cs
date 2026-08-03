using System.Text.Json.Serialization;

namespace OstTracker.Networking;

// DTOs mirroring shared/CONTRACT.md. Wire keys are snake_case; the shared
// serializer (see OstClient.Json) handles the naming — these are plain types.

public sealed record Person(int Id, string Name);

public sealed record Ost(
    int Id,
    string Title,
    string? Source,
    int? SubmitterId,
    string? SubmitterName,
    string? CoverImagePath,
    string? CoverAccentHex,
    string? ExternalLink,
    string CreatedAt);

public sealed record Rating(int OstId, int RaterId, string RaterName, double Score, string UpdatedAt);

public sealed record Note(int Id, string Title, [property: JsonPropertyName("note")] string? Text, string CreatedAt);

public sealed record RankEntry(
    Ost Ost, int RatingCount, double? Average, double? Minimum,
    double? Maximum, double? Stddev, int? Rank);

public sealed record PlaybackState(
    string Status, int? OstId, string? StreamUrl, string? WatchUrl, double Position);

public sealed record BatchSlot(int Slot, Ost Ost, bool Pinned);
public sealed record BatchGroup(int Index, int Day, IReadOnlyList<BatchSlot> Slots);
public sealed record Batches(string? GeneratedAt, [property: JsonPropertyName("batches")] IReadOnlyList<BatchGroup> Groups);

public sealed record SliceTally(int PersonId, string Name, int OutHere, int TotalOut, int Remaining, bool EliminatedHere);
public sealed record RankSlice(int Index, int BottomRank, int TopRank, string Label, IReadOnlyList<int> OstIds, IReadOnlyList<SliceTally> Tallies);
public sealed record Elimination(int PersonId, string Name, int Place, int SliceIndex, int OutAtRank, int TotalOut);
public sealed record Survivor(int PersonId, string Name, int TotalOut, int Remaining);
public sealed record EliminationBoard(int Threshold, int SliceSize, int RankedCount,
    IReadOnlyList<RankSlice> Slices, IReadOnlyList<Elimination> Eliminated, IReadOnlyList<Survivor> Survivors);

public sealed record HistoryEntry(int Id, string Title, string? Source, string? BatchLabel, string? Sender, string CreatedAt);

// --- request bodies ----------------------------------------------------------

public sealed record PersonIn(string Name);
public sealed record OstIn(string Title, string? Source = null, int? SubmitterId = null, string? ExternalLink = null);
public sealed record OstPatch(string? Title = null, string? Source = null, int? SubmitterId = null, string? ExternalLink = null);
public sealed record RatingIn(int OstId, int RaterId, double? Score);
public sealed record RatingUpsertList(IReadOnlyList<RatingIn> Ratings);
public sealed record RevealState(bool Unlocked);
public sealed record NoteIn(string Title, string? Note = null);
public sealed record NotePatch(string? Title = null, string? Note = null);
public sealed record BatchCountIn(int Count);
public sealed record BatchArrangeIn(IReadOnlyList<IReadOnlyList<int>> Batches);
public sealed record BatchPinIn(int OstId, bool Pinned);
public sealed record EliminationThresholdIn(int Threshold);
public sealed record PlayIn(int OstId);
public sealed record SeekIn(double Position);
public sealed record CoverSetIn(string ImageUrl);
