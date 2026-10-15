import CryptoKit
import Foundation

nonisolated struct LyricLine: Sendable, Codable, Equatable, Identifiable {
    let time: Double
    let text: String
    var id: Double { time }
}

nonisolated struct LyricsResult: Sendable, Codable {
    let synced: [LyricLine]?
    let plain: String?
}

/// Timed and plain lyrics from LRCLIB, with lyrics.ovh as a plain-text backup.
/// Hits survive launches. An offline lookup is never saved as a missing lyric.
final class LyricsService {
    static let shared = LyricsService()

    private struct Cached: Codable {
        let result: LyricsResult?
        let checkedAt: Date
    }

    private struct LrclibTrack: Decodable {
        let trackName: String?
        let artistName: String?
        let albumName: String?
        let duration: Double?
        let syncedLyrics: String?
        let plainLyrics: String?
    }

    private let directory: URL
    private var memory: [String: Cached] = [:]
    private var inFlight: [String: Task<LyricsResult?, Never>] = [:]

    private init() {
        directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "OSTTrackerLyrics", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func lyrics(for ost: Ost, duration: Double?) async -> LyricsResult? {
        let key = Self.cacheKey(for: ost)
        if let cached = memory[key] ?? read(key),
           let result = cached.result, Self.isUsable(result) {
            memory[key] = cached
            return result
        }
        if let running = inFlight[key] { return await running.value }
        let task = Task { [weak self] () -> LyricsResult? in
            let result = await Self.fetch(ost: ost, duration: duration)
            if !Task.isCancelled, let self {
                if result != nil {
                    let cached = Cached(result: result, checkedAt: Date())
                    self.memory[key] = cached
                    self.write(cached, key: key)
                }
                self.inFlight[key] = nil
            }
            return result
        }
        inFlight[key] = task
        return await task.value
    }

    private static func cacheKey(for ost: Ost) -> String {
        let identity = "\(ost.id)|\(ost.title.lowercased())|\(ost.source?.lowercased() ?? "")"
        return SHA256.hash(data: Data(identity.utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    private func read(_ key: String) -> Cached? {
        guard let data = try? Data(contentsOf: directory.appending(path: "\(key).json")) else { return nil }
        return try? JSONDecoder().decode(Cached.self, from: data)
    }

    private func write(_ value: Cached, key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: directory.appending(path: "\(key).json"), options: .atomic)
    }

    private static func fetch(ost: Ost, duration: Double?) async -> LyricsResult? {
        async let titleSearch = searchLRCLIB(ost.title)
        async let sourceSearch = searchLRCLIB([ost.title, ost.source].compactMap { $0 }.joined(separator: " "))
        let candidates = (await titleSearch ?? []) + (await sourceSearch ?? [])
        let matches = candidates.filter { titleMatches($0.trackName, ost.title) }
            .filter { item in
                if let duration, let candidate = item.duration {
                    return abs(candidate - duration) <= 25
                }
                if duration == nil, let source = ost.source, !source.isEmpty {
                    guard let album = item.albumName else { return false }
                    let a = normalize(album), b = normalize(source)
                    return a.contains(b) || b.contains(a)
                }
                return true
            }
            .sorted { matchScore($0, source: ost.source, duration: duration)
                > matchScore($1, source: ost.source, duration: duration) }
        for item in matches {
            if let raw = item.syncedLyrics {
                let lines = parseLRC(raw)
                if lines.count >= 4,
                   !looksLikeCredits(lines.map(\.text).joined(separator: "\n")) {
                    return LyricsResult(synced: lines, plain: nil)
                }
            }
        }
        if let plain = matches.compactMap({ cleanPlain($0.plainLyrics) }).first {
            return LyricsResult(synced: nil, plain: plain)
        }
        var artist = matches.compactMap { $0.artistName }.first { !$0.isEmpty }
        if artist == nil { artist = await appleArtist(for: ost, duration: duration) }
        if let artist, let plain = await lyricsOVH(artist: artist, title: ost.title) {
            return LyricsResult(synced: nil, plain: plain)
        }
        return nil
    }

    private static func matchScore(_ item: LrclibTrack, source: String?, duration: Double?) -> Double {
        var score = 0.0
        if let source, let album = item.albumName, !source.isEmpty {
            let a = normalize(album), b = normalize(source)
            if a.contains(b) || b.contains(a) { score += 10 }
        }
        if let duration, let candidate = item.duration { score += max(0, 8 - abs(candidate - duration) / 3) }
        if !(item.syncedLyrics ?? "").isEmpty { score += 2 }
        return score
    }

    private static func titleMatches(_ candidate: String?, _ title: String) -> Bool {
        guard let candidate else { return false }
        let a = normalize(candidate), b = normalize(title)
        return !a.isEmpty && a == b
    }

    private static func normalize(_ text: String) -> String {
        String(text.lowercased().unicodeScalars.filter(CharacterSet.alphanumerics.contains))
    }

    private static func cleanPlain(_ value: String?) -> String? {
        guard let value else { return nil }
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.count >= 40 && !looksLikeCredits(text) ? text : nil
    }

    private static func isUsable(_ result: LyricsResult) -> Bool {
        if let lines = result.synced, !lines.isEmpty {
            return !looksLikeCredits(lines.map(\.text).joined(separator: "\n"))
        }
        return cleanPlain(result.plain) != nil
    }

    /// Some lyric providers return album personnel as plain lyrics for an
    /// instrumental. Reject those records, including ones already on disk.
    private static func looksLikeCredits(_ text: String) -> Bool {
        let lines = text.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0 != "♪" }
        guard lines.count >= 3 else { return false }
        let creditMarkers = ["saxophone", "recording", "engineer", "mixing", "mastering",
                             "produced by", "guitar", "studio", "vocals", "arranged by",
                             "作曲", "编曲", "录音", "混音", "母带", "制作", "出品"]
        let creditLines = lines.filter { line in
            let lower = line.lowercased()
            return lower.contains(":") || lower.contains("：")
                || creditMarkers.contains(where: lower.contains)
        }.count
        return creditLines >= 3 && creditLines * 2 >= lines.count
    }

    private static func searchLRCLIB(_ query: String) async -> [LrclibTrack]? {
        var components = URLComponents(string: "https://lrclib.net/api/search")!
        components.queryItems = [URLQueryItem(name: "q", value: query)]
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 6)
        request.setValue("OSTTracker/1.0", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONDecoder().decode([LrclibTrack].self, from: data)
    }

    private static func appleArtist(for ost: Ost, duration: Double?) async -> String? {
        var components = URLComponents(string: "https://itunes.apple.com/search")!
        components.queryItems = [URLQueryItem(name: "term", value: ost.title),
                                 URLQueryItem(name: "media", value: "music"),
                                 URLQueryItem(name: "entity", value: "song"),
                                 URLQueryItem(name: "limit", value: "15")]
        guard let url = components.url,
              let (data, response) = try? await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 6)),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = object["results"] as? [[String: Any]] else { return nil }
        let matches = rows.filter { row in
            guard titleMatches(row["trackName"] as? String, ost.title) else { return false }
            guard let duration, let millis = row["trackTimeMillis"] as? Double else { return true }
            return abs(millis / 1_000 - duration) <= 25
        }
        let source = normalize(ost.source ?? "")
        let selected = matches.first { !source.isEmpty
            && normalize($0["collectionName"] as? String ?? "").contains(source) } ?? matches.first
        return selected?["artistName"] as? String
    }

    private static func lyricsOVH(artist: String, title: String) async -> String? {
        let pathSegment = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))
        let artistPath = artist.addingPercentEncoding(withAllowedCharacters: pathSegment) ?? artist
        let titlePath = title.addingPercentEncoding(withAllowedCharacters: pathSegment) ?? title
        guard let url = URL(string: "https://api.lyrics.ovh/v1/\(artistPath)/\(titlePath)"),
              let (data, response) = try? await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 8)),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return cleanPlain(object["lyrics"] as? String)
    }

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
            guard !times.isEmpty else { continue }
            let text = rest.trimmingCharacters(in: .whitespaces)
            for time in times { out.append(LyricLine(time: time, text: text.isEmpty ? "♪" : text)) }
        }
        return out.sorted { $0.time < $1.time }
    }
}
