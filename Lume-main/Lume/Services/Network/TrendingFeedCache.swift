//
//  TrendingFeedCache.swift
//  Lume
//

import Foundation

/// Session cache for trending feeds. Home tears down whenever the user leaves
/// its tab (inactive tvOS tabs unload their hierarchies), and the hero
/// carousel shouldn't wait on a fresh TMDB round-trip every time it comes
/// back — trending barely moves within an hour.
actor TrendingFeedCache {
    static let shared = TrendingFeedCache()

    private var entries: [String: (fetchedAt: Date, titles: [TrendingTitle])] = [:]

    func titles(for key: String, maxAge: TimeInterval) -> [TrendingTitle]? {
        guard let entry = entries[key], Date().timeIntervalSince(entry.fetchedAt) < maxAge else { return nil }
        return entry.titles
    }

    func store(_ titles: [TrendingTitle], for key: String) {
        entries[key] = (Date(), titles)
    }
}
