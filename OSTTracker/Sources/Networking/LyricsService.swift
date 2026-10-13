// Synced lyrics from LRCLIB (lrclib.net — free, no auth, returns LRC-format
// timed lines). This is the one piece of networking the Swift app does itself:
// lyrics are pure UI garnish, not competition state, so they stay out of the
// Python contract. Results are cached per OST for the app's lifetime; misses
// are remembered so we never re-query a track that has no lyrics.

import Foundation

nonisolated struct LyricLine: Sendable, Equatable, Identifiable {
    let time: Double     // seconds from track start
    let text: String
    var id: Double { time }
}

final class LyricsService {
    static let shared = LyricsService()

    private var cache: [Int: [LyricLine]] = [:]
    private var misses: Set<Int> = []
    private var inFlight: [Int: Task<[LyricLine]?, Never>] = [:]

    /// Best-effort synced lyrics for an OST. Returns nil when nothing usable
    /// exists — callers fall back to the plain visualizer layout.
    func lyrics(for ost: Ost, duration: Double?) async -> [LyricLine]? {
        if let hit = cache[ost.id] { return hit }
        if misses.contains(ost.id) { return nil }
        if let running = inFlight[ost.id] { return await running.value }

        let task = Task { [weak self] () -> [LyricLine]? in
            let lines = await Self.fetch(ost: ost, duration: duration)
            // Only cache when we KNEW the duration: a nil-duration pick is an
            // unverified guess (the player was still resolving), and caching
            // it would pin possibly-wrong lyrics to this OST for the whole
            // session. Left uncached, the caller re-fetches and re-validates
            // once the real duration lands.
            if duration != nil {
                if let lines {
                    self?.cache[ost.id] = lines
                } else {
                    self?.misses.insert(ost.id)
                }
            }
            self?.inFlight[ost.id] = nil
            return lines
        }
        inFlight[ost.id] = task
        return await task.value
    }

    // MARK: - LRCLIB

    private struct LrclibTrack: Decodable {
        let trackName: String?
        let artistName: String?
        let albumName: String?
        let duration: Double?
        let syncedLyrics: String?
    }

    private static func fetch(ost: Ost, duration: Double?) async -> [LyricLine]? {
        // Title first; game OSTs rarely match on "artist". A second pass with
        // the source appended helps generic titles find the right track.
        let queries = [ost.title, ost.source.map { "\(ost.title) \($0)" }]
            .compactMap(\.self)
        for query in queries {
            guard let results = await search(query) else { continue }
            let synced = results.filter { !($0.syncedLyrics ?? "").isEmpty }
            guard !synced.isEmpty else { continue }
            let best = pick(from: synced, title: ost.title, source: ost.source, duration: duration)
            if best == nil {
                let metadata = synced.map { "\($0.trackName ?? "?") / \($0.artistName ?? "?") / \($0.albumName ?? "?")" }
                print("LYRICS no metadata match for \"\(query)\" target=\(Int(duration ?? -1))s candidates: \(metadata.joined(separator: "; "))")
            }
            if let raw = best?.syncedLyrics {
                let lines = parseLRC(raw)
                if lines.count >= 4 {
                    print("LYRICS matched \"\(best?.trackName ?? "?")\" by \(best?.artistName ?? "unknown") on \(best?.albumName ?? "unknown album") for \"\(query)\"")
                    return lines
                }
            }
        }
        return nil
    }

    private static func pick(
        from candidates: [LrclibTrack], title: String, source: String?, duration: Double?
    ) -> LrclibTrack? {
        let credible = candidates.filter {
            titleMatches($0.trackName, title) && sourceMatches($0.albumName, source)
        }
        guard let target = duration else { return credible.first }
        return credible
            .compactMap { track -> (LrclibTrack, Double)? in
                guard let trackDuration = track.duration else { return nil }
                let delta = abs(trackDuration - target)
                return delta <= 30 ? (track, delta) : nil
            }
            .min { $0.1 < $1.1 }?.0
    }

    private static func titleMatches(_ candidate: String?, _ ours: String) -> Bool {
        guard let candidate else { return false }
        let a = normalize(candidate), b = normalize(ours)
        guard !a.isEmpty, !b.isEmpty else { return false }
        return a == b
    }

    private static func sourceMatches(_ album: String?, _ source: String?) -> Bool {
        guard let source, !source.isEmpty else { return true }
        guard let album, !album.isEmpty else { return false }
        let a = normalize(album), s = normalize(source)
        return a.contains(s) || s.contains(a)
    }

    private static func normalize(_ s: String) -> String {
        String(s.lowercased().unicodeScalars.filter(CharacterSet.alphanumerics.contains))
    }

    private static func search(_ query: String) async -> [LrclibTrack]? {
        var components = URLComponents(string: "https://lrclib.net/api/search")!
        components.queryItems = [URLQueryItem(name: "q", value: query)]
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.setValue("OSTTracker/1.0 (personal desktop app)", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200
        else { return nil }
        return try? JSONDecoder().decode([LrclibTrack].self, from: data)
    }

    /// LRC: `[mm:ss.xx]line`, possibly several timestamps per line. Empty timed
    /// lines are instrumental gaps — shown as ♪, the lyric-UI convention.
    nonisolated private static func parseLRC(_ raw: String) -> [LyricLine] {
        var out: [LyricLine] = []
        for rawLine in raw.split(separator: "\n", omittingEmptySubsequences: true) {
            var rest = rawLine[...]
            var times: [Double] = []
            while rest.hasPrefix("["), let close = rest.firstIndex(of: "]") {
                let tag = rest[rest.index(after: rest.startIndex)..<close]
                let parts = tag.split(separator: ":")
                if parts.count == 2, let minutes = Double(parts[0]), let seconds = Double(parts[1]) {
                    times.append(minutes * 60 + seconds)
                }
                rest = rest[rest.index(after: close)...]
            }
            guard !times.isEmpty else { continue }   // metadata tags like [ar:…]
            let text = rest.trimmingCharacters(in: .whitespaces)
            for time in times {
                out.append(LyricLine(time: time, text: text.isEmpty ? "♪" : text))
            }
        }
        return out.sorted { $0.time < $1.time }
    }
}
