#if os(iOS)
import Foundation

/// Native catalog lookup for the on-device backend. Suggestions use the fast
/// catalogs; a committed search also checks MusicBrainz.
nonisolated enum PhoneCatalogSearch {
    static func search(_ query: String, includeMusicBrainz: Bool) async -> [CatalogTrack] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard term.count >= 3 else { return [] }
        async let apple = fetchApple(term)
        async let deezer = fetchDeezer(term)
        async let musicBrainz = includeMusicBrainz ? fetchMusicBrainz(term) : []
        return await (apple + deezer + musicBrainz)
    }

    static func covers(title: String, source: String?) async -> [CoverCandidate] {
        async let apple = appleCovers(title: title, source: source)
        async let deezer = deezerCovers(title: title, source: source)
        var seen = Set<String>()
        return await (apple + deezer).filter { seen.insert($0.imageUrl).inserted }
    }

    private static func appleCovers(title: String, source: String?) async -> [CoverCandidate] {
        var parts = URLComponents(string: "https://itunes.apple.com/search")!
        parts.queryItems = [
            URLQueryItem(name: "term", value: title),
            URLQueryItem(name: "media", value: "music"),
            URLQueryItem(name: "entity", value: "song"),
            URLQueryItem(name: "limit", value: "30"),
        ]
        guard let payload = await request(parts), let rows = payload["results"] as? [[String: Any]] else { return [] }
        return rows.compactMap { row -> CoverCandidate? in
            guard matches(row["trackName"] as? String, title),
                  let art = row["artworkUrl100"] as? String else { return nil }
            let album = row["collectionName"] as? String ?? ""
            return CoverCandidate(imageUrl: art.replacingOccurrences(of: "100x100", with: "600x600"),
                                  thumbUrl: art, label: album, sourceName: "Apple Music")
        }.sorted { relevance($0.label, source) > relevance($1.label, source) }
    }

    private static func deezerCovers(title: String, source: String?) async -> [CoverCandidate] {
        var parts = URLComponents(string: "https://api.deezer.com/search")!
        parts.queryItems = [URLQueryItem(name: "q", value: title), URLQueryItem(name: "limit", value: "25")]
        guard let payload = await request(parts), let rows = payload["data"] as? [[String: Any]] else { return [] }
        return rows.compactMap { row -> CoverCandidate? in
            guard matches(row["title"] as? String, title),
                  let album = row["album"] as? [String: Any],
                  let art = album["cover_xl"] as? String else { return nil }
            return CoverCandidate(imageUrl: art, thumbUrl: album["cover_medium"] as? String ?? art,
                                  label: album["title"] as? String ?? "", sourceName: "Deezer")
        }.sorted { relevance($0.label, source) > relevance($1.label, source) }
    }

    private static func matches(_ candidate: String?, _ wanted: String) -> Bool {
        guard let candidate else { return false }
        return normalize(candidate) == normalize(wanted)
    }

    private static func relevance(_ album: String, _ source: String?) -> Int {
        guard let source, !source.isEmpty else { return 0 }
        let a = normalize(album), s = normalize(source)
        return a.contains(s) || s.contains(a) ? 1 : 0
    }

    private static func normalize(_ value: String) -> String {
        String(value.lowercased().unicodeScalars.filter(CharacterSet.alphanumerics.contains))
    }

    private static func fetchApple(_ term: String) async -> [CatalogTrack] {
        var parts = URLComponents(string: "https://itunes.apple.com/search")!
        parts.queryItems = [
            URLQueryItem(name: "term", value: term),
            URLQueryItem(name: "country", value: "US"),
            URLQueryItem(name: "media", value: "music"),
            URLQueryItem(name: "entity", value: "song"),
            URLQueryItem(name: "limit", value: "10"),
        ]
        guard let payload = await request(parts), let rows = payload["results"] as? [[String: Any]] else { return [] }
        return rows.compactMap { row in
            guard let id = row["trackId"] as? Int,
                  let title = row["trackName"] as? String, !title.isEmpty else { return nil }
            return CatalogTrack(id: "apple:\(id)", title: title,
                                artist: row["artistName"] as? String ?? "",
                                collection: row["collectionName"] as? String ?? "",
                                storeUrl: row["trackViewUrl"] as? String,
                                artworkURL: row["artworkUrl100"] as? String,
                                provider: "Apple Music")
        }
    }

    private static func fetchDeezer(_ term: String) async -> [CatalogTrack] {
        var parts = URLComponents(string: "https://api.deezer.com/search")!
        parts.queryItems = [URLQueryItem(name: "q", value: term), URLQueryItem(name: "limit", value: "10")]
        guard let payload = await request(parts), let rows = payload["data"] as? [[String: Any]] else { return [] }
        return rows.compactMap { row in
            guard let id = row["id"] as? Int,
                  let title = row["title"] as? String, !title.isEmpty else { return nil }
            return CatalogTrack(id: "deezer:\(id)", title: title,
                                artist: (row["artist"] as? [String: Any])?["name"] as? String ?? "",
                                collection: (row["album"] as? [String: Any])?["title"] as? String ?? "",
                                storeUrl: row["link"] as? String,
                                artworkURL: (row["album"] as? [String: Any])?["cover_medium"] as? String,
                                provider: "Deezer")
        }
    }

    private static func fetchMusicBrainz(_ term: String) async -> [CatalogTrack] {
        var parts = URLComponents(string: "https://musicbrainz.org/ws/2/recording/")!
        parts.queryItems = [URLQueryItem(name: "query", value: term),
                            URLQueryItem(name: "fmt", value: "json"),
                            URLQueryItem(name: "limit", value: "10")]
        guard let payload = await request(parts, userAgent: "OSTTracker/0.1.0 (https://github.com/ginnfx/ost)"),
              let rows = payload["recordings"] as? [[String: Any]] else { return [] }
        return rows.compactMap { row in
            guard let id = row["id"] as? String,
                  let title = row["title"] as? String, !title.isEmpty else { return nil }
            let credits = row["artist-credit"] as? [Any] ?? []
            let artist = credits.map { credit -> String in
                if let text = credit as? String { return text }
                return (credit as? [String: Any])?["name"] as? String ?? ""
            }.joined()
            let releases = row["releases"] as? [[String: Any]] ?? []
            let collection = releases.compactMap { $0["title"] as? String }.first ?? ""
            return CatalogTrack(id: "musicbrainz:\(id)", title: title,
                                artist: artist, collection: collection,
                                storeUrl: "https://musicbrainz.org/recording/\(id)",
                                artworkURL: nil,
                                provider: "MusicBrainz")
        }
    }

    private static func request(_ parts: URLComponents, userAgent: String? = nil) async -> [String: Any]? {
        guard let url = parts.url else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 8)
        if let userAgent { request.setValue(userAgent, forHTTPHeaderField: "User-Agent") }
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
#endif
