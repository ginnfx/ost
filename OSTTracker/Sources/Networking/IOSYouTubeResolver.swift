#if os(iOS)
import Foundation
@preconcurrency import YouTubeKit

/// On-device iOS counterpart to the Mac's YouTube lookup and stream resolver.
/// It uses YouTubeKit's local extractor only; no third-party extraction server
/// or Mac connection is required.
@MainActor
enum IOSYouTubeResolver {
    struct Result {
        let streamURL: URL
        let watchURL: URL
    }

    static func resolve(title: String, source: String?, externalLink: String?, cachedWatchURL: String?) async throws -> Result {
        let directCandidates = [cachedWatchURL, externalLink].compactMap { value -> URL? in
            guard let value, let url = URL(string: value), isYouTubeURL(url) else { return nil }
            return url
        }

        var lastError: Error?
        for watchURL in directCandidates {
            do {
                if let result = try await extract(from: watchURL) { return result }
            } catch {
                lastError = error
            }
        }

        do {
            for watchURL in try await search(title: title, source: source) {
                do {
                    if let result = try await extract(from: watchURL) { return result }
                } catch {
                    lastError = error
                }
            }
        } catch {
            if directCandidates.isEmpty { throw error }
            lastError = error
        }

        if let lastError { throw lastError }
        throw ResolverError.noPlayableStream
    }

    private static func extract(from watchURL: URL) async throws -> Result? {
        if let cached = cachedStream(for: watchURL) {
            return Result(streamURL: cached, watchURL: watchURL)
        }
        let youtube = YouTube(url: watchURL, methods: [.local])
        let streams = try await youtube.streams
        let audioOnly = streams.filterAudioOnly().filter(\.isNativelyPlayable)
        let m4a = audioOnly.filter { $0.fileExtension == .m4a }
        guard let stream = m4a.highestAudioBitrateStream() ?? audioOnly.highestAudioBitrateStream() else {
            return nil
        }
        remember(stream.url, for: watchURL)
        return Result(streamURL: stream.url, watchURL: watchURL)
    }

    private struct StreamRecord: Codable {
        let url: URL
        let validUntil: Date
    }

    private static let streamCacheKey = "ost.ios.playback.streams.v1"

    static func invalidateStream(for watchURL: URL) {
        guard let data = UserDefaults.standard.data(forKey: streamCacheKey),
              var records = try? JSONDecoder().decode([String: StreamRecord].self, from: data) else { return }
        records[watchURL.absoluteString] = nil
        if let encoded = try? JSONEncoder().encode(records) {
            UserDefaults.standard.set(encoded, forKey: streamCacheKey)
        }
    }

    private static func cachedStream(for watchURL: URL) -> URL? {
        guard let data = UserDefaults.standard.data(forKey: streamCacheKey),
              let records = try? JSONDecoder().decode([String: StreamRecord].self, from: data),
              let record = records[watchURL.absoluteString],
              record.validUntil > Date() else { return nil }
        return record.url
    }

    private static func remember(_ streamURL: URL, for watchURL: URL) {
        let now = Date()
        let expiry = URLComponents(url: streamURL, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "expire" })?.value
            .flatMap(TimeInterval.init)
        let validUntil = min(now.addingTimeInterval(30 * 60),
                             expiry.map { Date(timeIntervalSince1970: $0 - 90) } ?? now.addingTimeInterval(10 * 60))
        guard validUntil > now else { return }
        let existing = UserDefaults.standard.data(forKey: streamCacheKey)
            .flatMap { try? JSONDecoder().decode([String: StreamRecord].self, from: $0) } ?? [:]
        var records = existing.filter { $0.value.validUntil > now }
        records[watchURL.absoluteString] = StreamRecord(url: streamURL, validUntil: validUntil)
        if let data = try? JSONEncoder().encode(records) {
            UserDefaults.standard.set(data, forKey: streamCacheKey)
        }
    }

    private static func search(title: String, source: String?) async throws -> [URL] {
        let query = [title, source, "OST"].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !query.isEmpty else { throw ResolverError.emptySearch }

        // YouTube's HTML results page can be a consent/challenge page on a
        // phone, with no videoId fields. Query the same InnerTube endpoint that
        // YouTubeKit uses, and broaden to the bare title for obscure OSTs.
        async let specific = innerTubeSearch(query)
        async let broad = innerTubeSearch(title)
        let found = ((try? await specific) ?? []) + ((try? await broad) ?? [])
        if !found.isEmpty { return uniqueURLs(found, limit: 10) }

        let htmlFound = (try? await webSearch(query)) ?? []
        if !htmlFound.isEmpty { return uniqueURLs(htmlFound, limit: 10) }
        let bareHTML = (try? await webSearch(title)) ?? []
        guard !bareHTML.isEmpty else { throw ResolverError.noSearchResults }
        return uniqueURLs(bareHTML, limit: 10)
    }

    private static func innerTubeSearch(_ query: String) async throws -> [URL] {
        var components = URLComponents(string: "https://www.youtube.com/youtubei/v1/search")!
        components.queryItems = [
            URLQueryItem(name: "key", value: "AIzaSyAO_FJ2SlqU8Q4STEHLGCilw_Y9_11qcW8"),
            URLQueryItem(name: "prettyPrint", value: "false"),
        ]
        let version = "2.20260708.00.00"
        let body: [String: Any] = [
            "context": ["client": [
                "clientName": "WEB", "clientVersion": version,
                "hl": "en", "gl": "US",
            ]],
            "query": query,
        ]
        var request = URLRequest(url: components.url!, timeoutInterval: 9)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "X-YouTube-Client-Name")
        request.setValue(version, forHTTPHeaderField: "X-YouTube-Client-Version")
        request.setValue("https://www.youtube.com", forHTTPHeaderField: "Origin")
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let payload = try? JSONSerialization.jsonObject(with: data) else {
            throw ResolverError.searchFailed
        }
        var ids: [String] = []
        var seen = Set<String>()
        collectVideoIDs(payload, into: &ids, seen: &seen)
        return ids.prefix(8).compactMap { URL(string: "https://www.youtube.com/watch?v=\($0)") }
    }

    private static func collectVideoIDs(_ value: Any, into ids: inout [String], seen: inout Set<String>) {
        if let object = value as? [String: Any] {
            if let video = object["videoRenderer"] as? [String: Any],
               let id = video["videoId"] as? String, id.count == 11,
               seen.insert(id).inserted {
                ids.append(id)
            }
            if let endpoint = object["watchEndpoint"] as? [String: Any],
               let id = endpoint["videoId"] as? String, id.count == 11,
               seen.insert(id).inserted {
                ids.append(id)
            }
            for nested in object.values { collectVideoIDs(nested, into: &ids, seen: &seen) }
        } else if let array = value as? [Any] {
            for nested in array { collectVideoIDs(nested, into: &ids, seen: &seen) }
        }
    }

    private static func uniqueURLs(_ urls: [URL], limit: Int) -> [URL] {
        var seen = Set<String>()
        return Array(urls.filter { seen.insert($0.absoluteString).inserted }.prefix(limit))
    }

    private static func webSearch(_ query: String) async throws -> [URL] {
        var components = URLComponents(string: "https://www.youtube.com/results")!
        components.queryItems = [URLQueryItem(name: "search_query", value: query)]
        var request = URLRequest(url: components.url!, timeoutInterval: 15)
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")
        request.setValue("en-US,en;q=0.8", forHTTPHeaderField: "Accept-Language")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let html = String(data: data, encoding: .utf8) else {
            throw ResolverError.searchFailed
        }

        // Search results include their video IDs in the initial page payload,
        // so the first result can be extracted without a separate API key.
        let expression = try NSRegularExpression(pattern: #""videoId"\s*:\s*"([A-Za-z0-9_-]{11})""#)
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        var seen = Set<String>()
        let ids = expression.matches(in: html, range: range).compactMap { match -> String? in
            guard let idRange = Range(match.range(at: 1), in: html) else { return nil }
            let id = String(html[idRange])
            return seen.insert(id).inserted ? id : nil
        }
        let urls = ids.prefix(10).compactMap { URL(string: "https://www.youtube.com/watch?v=\($0)") }
        return Array(urls)
    }

    static func isYouTubeURL(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return ["youtube.com", "www.youtube.com", "m.youtube.com", "music.youtube.com", "youtu.be"].contains(host)
    }

    enum ResolverError: LocalizedError {
        case emptySearch
        case searchFailed
        case noSearchResults
        case noPlayableStream

        var errorDescription: String? {
            switch self {
            case .emptySearch: "Enter a track title to search."
            case .searchFailed: "YouTube search is temporarily unavailable."
            case .noSearchResults: "No YouTube results were found for this OST."
            case .noPlayableStream: "YouTube returned no playable audio stream. Try again later or connect the Mac music service."
            }
        }
    }
}
#endif
