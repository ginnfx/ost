#if os(iOS)
import CryptoKit
import Foundation

/// Audio files are written only after playback has already started, so a cache
/// miss never delays the first play. Caches can be evicted by iOS at any time.
actor IOSAudioCache {
    static let shared = IOSAudioCache()

    private let directory: URL
    private var downloads: Set<String> = []
    private let maxFileBytes: Int64 = 60 * 1_024 * 1_024
    private let maxCacheBytes: Int64 = 240 * 1_024 * 1_024

    private init() {
        directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "OSTTrackerAudio", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    static func key(for row: [String: Any]) -> String {
        let identity = [row["id"], row["title"], row["source"], row["external_link"]]
            .map { value in value is NSNull ? "" : String(describing: value ?? "") }
            .joined(separator: "\u{1f}")
        return SHA256.hash(data: Data(identity.utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    func cachedURL(for key: String) -> URL? {
        for ext in ["m4a", "mp3", "aac", "mp4", "wav"] {
            let url = directory.appending(path: "\(key).\(ext)")
            if FileManager.default.fileExists(atPath: url.path) {
                try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
                return url
            }
        }
        return nil
    }

    func remove(for key: String) {
        for ext in ["m4a", "mp3", "aac", "mp4", "wav"] {
            try? FileManager.default.removeItem(at: directory.appending(path: "\(key).\(ext)"))
        }
    }

    func store(_ streamURL: URL, for key: String) async {
        guard cachedURL(for: key) == nil, downloads.insert(key).inserted else { return }
        defer { downloads.remove(key) }

        var request = URLRequest(url: streamURL)
        request.timeoutInterval = 30
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForResource = 180
        config.waitsForConnectivity = false
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        do {
            let (temporary, response) = try await session.download(for: request)
            guard let http = response as? HTTPURLResponse,
                  http.statusCode == 200,
                  (http.mimeType?.hasPrefix("audio/") == true
                   || http.mimeType?.hasPrefix("video/") == true
                   || http.mimeType == "application/octet-stream"),
                  http.expectedContentLength <= 0 || http.expectedContentLength <= maxFileBytes else { return }
            let size = (try FileManager.default.attributesOfItem(atPath: temporary.path)[.size] as? NSNumber)?.int64Value ?? 0
            guard size > 0, size <= maxFileBytes else { return }
            let candidate = streamURL.pathExtension.lowercased()
            let ext = ["m4a", "mp3", "aac", "mp4", "wav"].contains(candidate) ? candidate : "m4a"
            let destination = directory.appending(path: "\(key).\(ext)")
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: temporary, to: destination)
            trimIfNeeded()
        } catch {
            // The signed stream may expire while downloading; the next play
            // still resolves and streams normally.
        }
    }

    private func trimIfNeeded() {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]
        ) else { return }
        let entries = files.compactMap { url -> (URL, Date, Int64)? in
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
                  let bytes = values.fileSize else { return nil }
            return (url, values.contentModificationDate ?? .distantPast, Int64(bytes))
        }.sorted { $0.1 < $1.1 }
        var total = entries.reduce(Int64(0)) { $0 + $1.2 }
        for (url, _, bytes) in entries where total > maxCacheBytes {
            try? FileManager.default.removeItem(at: url)
            total -= bytes
        }
    }
}
#endif
