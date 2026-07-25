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
            let best = pick(from: synced, title: ost.title, duration: duration)
            if best == nil {
                let durs = synced.map { "\($0.trackName ?? "?")=\(Int($0.duration ?? -1))s" }
                print("LYRICS no duration match for \"\(query)\" target=\(Int(duration ?? -1))s candidates: \(durs.joined(separator: ", "))")
            }
            if let raw = best?.syncedLyrics {
                let lines = parseLRC(raw)
                if lines.count >= 4 {
                    print("LYRICS matched \"\(best?.trackName ?? "?")\" (\(Int(best?.duration ?? -1))s) for \"\(query)\" target=\(Int(duration ?? -1))s")
                    return lines
                }
            }
        }
        return nil
    }

    /// Duration is the strongest same-version signal we have, but our source is
    /// a YouTube stream that routinely runs a few seconds longer than the
    /// official track (intro/outro padding). So: prefer the CLOSEST duration,
    /// accept within 15s outright, stretch to 30s when the track title also
    /// matches ours, and only reject when nothing comes close — wrong-version
    /// lyrics drift out of sync, which is worse than none.
    private static func pick(
        from candidates: [LrclibTrack], title: String, duration: Double?
    ) -> LrclibTrack? {
        guard let target = duration else {
            // No duration yet (player still resolving). A blind first-hit is
            // routinely a different song for generic titles like "Main Theme"
            // — at minimum the track name has to match ours.
            return candidates.first { titleMatches($0.trackName, title) }
        }
        let ranked = candidates
            .map { (track: $0, delta: abs(($0.duration ?? -1000) - target)) }
            .sorted { $0.delta < $1.delta }
        guard let closest = ranked.first else { return nil }
        if closest.delta < 15 { return closest.track }
        return ranked.first {
            $0.delta < 30 && titleMatches($0.track.trackName, title)
        }?.track
    }

    /// Loose containment on lowercased alphanumerics, both directions — so
    /// "Nameless Faces - English Ver." matches "Nameless Faces" and vice versa.
    private static func titleMatches(_ candidate: String?, _ ours: String) -> Bool {
        guard let candidate else { return false }
        let a = normalize(candidate), b = normalize(ours)
        guard !a.isEmpty, !b.isEmpty else { return false }
        return a.contains(b) || b.contains(a)
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
