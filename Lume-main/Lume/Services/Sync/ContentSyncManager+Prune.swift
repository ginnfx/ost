//
//  ContentSyncManager+Prune.swift
//  Lume
//
//  Prunes stale catalog content with a mark-and-sweep pass. The batched upsert
//  in the Xtream and m3u pipelines only ever inserts or updates the items a
//  fetch returns — it never removes items the provider has since dropped. Left
//  alone, a movie pulled from the provider's library, or a whole category that
//  no longer exists, lingers in the local store forever (storage bloat; the
//  indexer keeps resolving dead titles; browsing shows content that 404s on
//  playback).
//
//  Each sync builds the set of ids the provider returned for a content kind
//  ("seen"), then sweeps the playlist's local rows of that kind, deleting any id
//  not in the set. Episodes cascade from their `Series`; cast cascades from its
//  parent — same cascade `PlaylistDeletion` relies on.
//
//  SAFETY: a sweep against an empty/partial fetch would wipe the playlist's
//  catalog, so the *caller* must gate the sweep on a healthy fetch (see the
//  guards in syncMovies/…/importM3UFile) before handing a `seenIds` set here.
//  Pruning is confined to the local-only catalog store, so a delete never
//  propagates to CloudKit; and user state (favorites, progress, watchlist)
//  lives in `UserContentState` in the cloud mirror keyed by `contentId`, so it
//  survives a prune and is re-applied if the content ever returns.
//

import Foundation
import OSLog
import SwiftData

extension ContentSyncManager {
    // MARK: - Xtream sweep entry points

    // These wrap the per-kind sweep with the seen-set construction and the
    // non-empty-fetch guard, so the batch-sync functions stay a single call.
    // A working Xtream provider never returns zero of a kind, so an empty fetch
    // is a transient failure — skipping the sweep then keeps the library.

    func pruneMovies(playlistId: UUID, against movieDTOs: [XtreamVODStream]) {
        guard !movieDTOs.isEmpty else { return }
        let seenIds = Set(movieDTOs.compactMap { dto -> String? in
            guard let streamId = dto.streamId else { return nil }
            return "\(playlistId.uuidString)-movie-\(streamId)"
        })
        pruneStaleMovies(playlistId: playlistId, seenIds: seenIds)
    }

    func pruneSeries(playlistId: UUID, against seriesDTOs: [XtreamSeries]) {
        guard !seriesDTOs.isEmpty else { return }
        let seenIds = Set(seriesDTOs.compactMap { dto -> String? in
            guard let seriesId = dto.seriesId else { return nil }
            return "\(playlistId.uuidString)-series-\(seriesId)"
        })
        pruneStaleSeries(playlistId: playlistId, seenIds: seenIds)
    }

    func pruneLiveStreams(playlistId: UUID, against streamDTOs: [XtreamLiveStream]) {
        guard !streamDTOs.isEmpty else { return }
        let seenIds = Set(streamDTOs.compactMap { dto -> String? in
            guard let streamId = dto.streamId else { return nil }
            return "\(playlistId.uuidString)-live-\(streamId)"
        })
        pruneStaleLiveStreams(playlistId: playlistId, seenIds: seenIds)
    }

    // MARK: - Per-kind sweeps

    /// Deletes movies for `playlistId` whose id is absent from `seenIds`.
    func pruneStaleMovies(playlistId: UUID, seenIds: Set<String>) {
        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false

        // Scope to the playlist via its UUID, which anchors every id this
        // playlist produced (see PlaylistDeletion). `starts(with:)` compiles to
        // a range seek on the unique `id` index; the substring match used before
        // was a LIKE-%…% scan that touched every row on each sync's sweep.
        let prefix = playlistId.uuidString
        let descriptor = FetchDescriptor<Movie>(
            predicate: #Predicate { $0.id.starts(with: prefix) }
        )
        var removed = 0
        for movie in (try? context.fetch(descriptor)) ?? [] where !seenIds.contains(movie.id) {
            context.delete(movie)
            removed += 1
        }
        guard removed > 0 else { return }
        try? context.save()
        Logger.database.info("Pruned \(removed) stale movie(s) for playlist \(prefix)")
    }

    /// Deletes series for `playlistId` whose id is absent from `seenIds`. Each
    /// removed series' episodes and cast cascade from the series.
    func pruneStaleSeries(playlistId: UUID, seenIds: Set<String>) {
        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false

        let prefix = playlistId.uuidString
        let descriptor = FetchDescriptor<Series>(
            predicate: #Predicate { $0.id.starts(with: prefix) }
        )
        var removed = 0
        for show in (try? context.fetch(descriptor)) ?? [] where !seenIds.contains(show.id) {
            context.delete(show)
            removed += 1
        }
        guard removed > 0 else { return }
        try? context.save()
        Logger.database.info("Pruned \(removed) stale series for playlist \(prefix)")
    }

    /// Deletes live streams for `playlistId` whose id is absent from `seenIds`.
    func pruneStaleLiveStreams(playlistId: UUID, seenIds: Set<String>) {
        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false

        let prefix = playlistId.uuidString
        let descriptor = FetchDescriptor<LiveStream>(
            predicate: #Predicate { $0.id.starts(with: prefix) }
        )
        var removed = 0
        for stream in (try? context.fetch(descriptor)) ?? [] where !seenIds.contains(stream.id) {
            context.delete(stream)
            removed += 1
        }
        guard removed > 0 else { return }
        try? context.save()
        Logger.database.info("Pruned \(removed) stale live stream(s) for playlist \(prefix)")
    }

    /// Deletes episodes for `playlistId` whose id is absent from `seenIds`,
    /// leaving their series in place. Used by the m3u pipeline, where episodes
    /// are imported alongside the rest of the catalog; the Xtream pipeline pulls
    /// episodes lazily per-series and so isn't swept here.
    func pruneStaleEpisodes(playlistId: UUID, seenIds: Set<String>) {
        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false

        // Episode.id is "\(seriesId)-episode-…" and seriesId starts with the
        // playlist UUID, so the same prefix scope applies.
        let prefix = playlistId.uuidString
        let descriptor = FetchDescriptor<Episode>(
            predicate: #Predicate { $0.id.starts(with: prefix) }
        )
        var removed = 0
        for episode in (try? context.fetch(descriptor)) ?? [] where !seenIds.contains(episode.id) {
            context.delete(episode)
            removed += 1
        }
        guard removed > 0 else { return }
        try? context.save()
        Logger.database.info("Pruned \(removed) stale episode(s) for playlist \(prefix)")
    }

    /// Deletes categories of `type` for `playlistId` whose `apiId` is absent
    /// from `seenApiIds`. Scoped per type — VOD / series / live categories sync
    /// from separate provider calls, so a `seenApiIds` set for one type must not
    /// reach another type's rows.
    func pruneStaleCategories(playlistId: UUID, type: CategoryType, seenApiIds: Set<String>) {
        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false

        // Match buildExistingCategoryLookup: fetch by indexed typeRaw, then
        // filter to this playlist by the id prefix in memory.
        let prefix = "\(playlistId.uuidString)-\(type.rawValue)-"
        let typeRaw = type.rawValue
        let descriptor = FetchDescriptor<Category>(
            predicate: #Predicate { $0.typeRaw == typeRaw }
        )
        var removed = 0
        for category in (try? context.fetch(descriptor)) ?? []
            where category.id.hasPrefix(prefix) && !seenApiIds.contains(category.apiId)
        {
            context.delete(category)
            removed += 1
        }
        guard removed > 0 else { return }
        try? context.save()
        Logger.database.info("Pruned \(removed) stale \(typeRaw) category/ies for playlist \(prefix)")
    }
}
