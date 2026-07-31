import Foundation
import SwiftData

// MARK: - MDBList Ratings Enrichment

extension ContentSyncManager {
    /// Fetches aggregator ratings (IMDb / Rotten Tomatoes / Metacritic / Trakt /
    /// Letterboxd / TMDB) for a TMDB id without persisting. The caller applies
    /// the data directly to its own context to avoid cross-context merge timing
    /// issues. Returns an empty array when MDBList is unconfigured or the title
    /// is unknown.
    func fetchMDBListRatings(tmdbId: Int, type: MDBListClient.MediaType) async throws -> [ExternalRating] {
        let client = MDBListClient.shared
        guard client.isConfigured else { return [] }
        return try await client.ratings(tmdbId: tmdbId, type: type)
    }

    /// Fetches and persists MDBList ratings for a movie **off the main thread**,
    /// on the engine actor's own background context (the save auto-merges into
    /// the main context). Keeps the rating write off a detail view's hot path.
    func enrichMovieRatings(movieId: String, tmdbId: Int) async {
        guard let ratings = try? await fetchMDBListRatings(tmdbId: tmdbId, type: .movie) else { return }
        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false
        var descriptor = FetchDescriptor<Movie>(predicate: #Predicate { $0.id == movieId })
        descriptor.fetchLimit = 1
        guard let movie = try? context.fetch(descriptor).first else { return }
        movie.externalRatings = ratings
        movie.ratingsEnrichedAt = Date()
        try? context.save()
    }

    /// Series counterpart of ``enrichMovieRatings(movieId:tmdbId:)``.
    func enrichSeriesRatings(seriesId: String, tmdbId: Int) async {
        guard let ratings = try? await fetchMDBListRatings(tmdbId: tmdbId, type: .show) else { return }
        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false
        var descriptor = FetchDescriptor<Series>(predicate: #Predicate { $0.id == seriesId })
        descriptor.fetchLimit = 1
        guard let series = try? context.fetch(descriptor).first else { return }
        series.externalRatings = ratings
        series.ratingsEnrichedAt = Date()
        try? context.save()
    }
}

// MARK: - Detail-screen enrichment

/// 14 days — ratings rarely move, so revisits within the window skip the fetch.
private let ratingsCacheWindow: TimeInterval = 14 * 24 * 3600

/// Fetches MDBList ratings for a movie and persists them, keyed directly by
/// the TMDB id we already store. No-ops when MDBList is unconfigured, the TMDB
/// id is missing, or the cache is still fresh. Call from a detail view's
/// `.task` after TMDB enrichment.
@MainActor
func enrichMovieRatingsIfNeeded(_ movie: Movie, context: ModelContext) async {
    guard let tmdbId = movie.tmdbId, MDBListClient.shared.isConfigured else { return }
    if let enrichedAt = movie.ratingsEnrichedAt, Date().timeIntervalSince(enrichedAt) < ratingsCacheWindow { return }
    // Fetch + persist on the manager's background context (off the main thread);
    // the save auto-merges back so `movie.externalRatings` updates in the view.
    let manager = ContentSyncManager(modelContainer: context.container)
    await manager.enrichMovieRatings(movieId: movie.id, tmdbId: tmdbId)
}

/// Series counterpart of ``enrichMovieRatingsIfNeeded(_:context:)``.
@MainActor
func enrichSeriesRatingsIfNeeded(_ series: Series, context: ModelContext) async {
    guard let tmdbId = series.tmdbId, MDBListClient.shared.isConfigured else { return }
    if let enrichedAt = series.ratingsEnrichedAt, Date().timeIntervalSince(enrichedAt) < ratingsCacheWindow { return }
    let manager = ContentSyncManager(modelContainer: context.container)
    await manager.enrichSeriesRatings(seriesId: series.id, tmdbId: tmdbId)
}
