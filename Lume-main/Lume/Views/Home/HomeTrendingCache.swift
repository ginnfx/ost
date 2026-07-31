//
//  HomeTrendingCache.swift
//  Lume
//
//  Session-lived memo of Home's TMDB trending and Trakt watchlist results.
//  tvOS renders only the selected tab, so `HomeView` (and its `@State`) is
//  torn down on every tab switch — without this cache the hero carousel
//  refetched and visibly popped in on each return to Home. Entries are keyed
//  by the same invalidation keys the loading tasks use, so a playlist switch,
//  sync or added playlist still reloads; a cache entry is only read after its
//  key matches, so stale model references from a removed playlist are never
//  touched.
//

import Foundation

@MainActor
@Observable
final class HomeTrendingCache {
    static let shared = HomeTrendingCache()

    private(set) var trendingKey: String?
    private(set) var heroItems: [HeroItem] = []
    private(set) var trendingMovies: [HomeMediaItem] = []
    private(set) var trendingSeries: [HomeMediaItem] = []

    private(set) var watchlistKey: String?
    private(set) var watchlist: [HomeMediaItem] = []

    func trendingEntry(for key: String) -> (heroes: [HeroItem], movies: [HomeMediaItem], series: [HomeMediaItem])? {
        guard key == trendingKey else { return nil }
        return (heroItems, trendingMovies, trendingSeries)
    }

    func storeTrending(key: String, heroes: [HeroItem], movies: [HomeMediaItem], series: [HomeMediaItem]) {
        trendingKey = key
        heroItems = heroes
        trendingMovies = movies
        trendingSeries = series
    }

    func watchlistEntry(for key: String) -> [HomeMediaItem]? {
        guard key == watchlistKey else { return nil }
        return watchlist
    }

    func storeWatchlist(key: String, items: [HomeMediaItem]) {
        watchlistKey = key
        watchlist = items
    }
}
