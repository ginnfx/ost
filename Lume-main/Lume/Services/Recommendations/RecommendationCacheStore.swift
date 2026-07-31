//
//  RecommendationCacheStore.swift
//  Lume
//
//  Persists the last computed "For You" list per profile so the rail survives
//  between the (deliberately infrequent) recomputes the engine throttles to.
//  It's derived cache, not user content — re-derivable at any time — so it lives
//  in UserDefaults as JSON, like the iCloud shadow baseline.
//

import Foundation

/// A cached recommendation list plus when it was produced.
nonisolated struct RecommendationCache: Codable, Equatable {
    var computedAt: Date
    var items: [ScoredRecommendation]
}

nonisolated struct RecommendationCacheStore {
    private let defaults: UserDefaults
    private let keyPrefix = "recommendations.cache.v1."

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func cache(for profileID: UUID?) -> RecommendationCache? {
        guard let data = defaults.data(forKey: key(for: profileID)) else { return nil }
        return try? JSONDecoder().decode(RecommendationCache.self, from: data)
    }

    func save(_ cache: RecommendationCache, for profileID: UUID?) {
        guard let data = try? JSONEncoder().encode(cache) else { return }
        defaults.set(data, forKey: key(for: profileID))
    }

    /// Drops the cached list so the next request recomputes regardless of the
    /// recalculation interval. Used by the DEBUG "Recalculate" action.
    func clear(for profileID: UUID?) {
        defaults.removeObject(forKey: key(for: profileID))
    }

    private func key(for profileID: UUID?) -> String {
        keyPrefix + (profileID?.uuidString ?? "default")
    }
}
