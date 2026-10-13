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
        let youtube = YouTube(url: watchURL, methods: [.local])
        let streams = try await youtube.streams
        let audioOnly = streams.filterAudioOnly().filter(\.isNativelyPlayable)
        let m4a = audioOnly.filter { $0.fileExtension == .m4a }
        guard let stream = m4a.highestAudioBitrateStream() ?? audioOnly.highestAudioBitrateStream() else {
            return nil
        }
        return Result(streamURL: stream.url, watchURL: watchURL)
    }

    private static func search(title: String, source: String?) async throws -> [URL] {
        let query = [title, source, "OST"].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !query.isEmpty else { throw ResolverError.emptySearch }

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
        guard !urls.isEmpty else { throw ResolverError.noSearchResults }
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
