#if os(macOS)
import AuthenticationServices
import AVFoundation
import CryptoKit
import Foundation
import Observation
import Security
import SwiftUI

nonisolated struct CompetitionMembership: Codable, Sendable, Identifiable {
    let competitionId: String
    let name: String
    let status: String
    let nickname: String
    let isTrial: Bool
    let entriesPerParticipant: Int
    var id: String { competitionId }
}

nonisolated struct CompetitionBatch: Codable, Sendable, Identifiable {
    let number: Int
    let status: String
    let releasedAt: String?
    let entryCount: Int
    let ratedCount: Int
    let finalized: Bool
    var id: Int { number }
}

nonisolated struct CompetitionBatchEntry: Codable, Sendable, Identifiable {
    let listeningId: String
    let label: String
    let audioUrl: String
    let durationSeconds: Double
    let own: Bool
    let automaticScore: Int?
    var rating: Int?
    var version: Int
    var id: String { listeningId }
}

nonisolated struct CompetitionArchive: Decodable, Sendable {
    let competitionId: String
    let entries: [CompetitionArchiveEntry]
    let originals: [String]
}

nonisolated struct CompetitionArchiveEntry: Decodable, Encodable, Sendable, Identifiable {
    let listeningId: String
    let label: String
    let franchise: String
    let title: String
    let rank: Int
    let meanScore: String
    let ratingCount: Int
    let group: Int
    var audioUrl: String?
    var audioFilename: String?
    var id: String { listeningId }
}

nonisolated struct CompetitionRatingWrite: Codable, Sendable {
    let competitionId: String
    let batch: Int
    let listeningId: String
    let score: Int
    let expectedVersion: Int
}

private struct CachedCompetitionEntry: Codable, Sendable {
    let listeningId: String
    let label: String
    let durationSeconds: Double
    let own: Bool
    let automaticScore: Int?
    let rating: Int?
    let version: Int
}

private struct CachedCompetitionState: Codable, Sendable {
    let userId: String
    let memberships: [CompetitionMembership]
    let batches: [CompetitionBatch]
    let isHost: Bool
    let selectedCompetitionId: String?
    let selectedBatch: Int?
    let entries: [CachedCompetitionEntry]
}

private struct CachedPendingQueue: Codable, Sendable {
    let userId: String
    let items: [PendingCompetitionRating]
}

private struct PendingCompetitionRating: Codable, Sendable, Identifiable {
    var write: CompetitionRatingWrite
    var needsResolution = false
    var id: String { "\(write.competitionId):\(write.batch):\(write.listeningId)" }
}

private struct NativeSession: Codable, Sendable {
    let accessToken: String
    let refreshToken: String
    let expiresAt: Int
    let userId: String
}

private struct NativeExchange: Decodable {
    let accessToken: String
    let refreshToken: String
    let expiresAt: Int
    let userId: String
}

private struct CompetitionListResponse: Decodable { let competitions: [CompetitionMembership] }
private struct CompetitionBatchListResponse: Decodable { let batches: [CompetitionBatch] }
private struct CompetitionEntryListResponse: Decodable { let entries: [CompetitionBatchEntry] }
private struct RatingWriteResponse: Decodable { let version: Int }

private enum CompetitionAccountError: LocalizedError {
    case invalidServer
    case signInCancelled
    case invalidCallback
    case staleRating
    case requestFailed(Int)
    case archiveUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidServer: "Enter the permanent HTTPS competition website address."
        case .signInCancelled: "Passkey sign-in was cancelled."
        case .invalidCallback: "The competition sign-in response was invalid."
        case .staleRating: "This rating changed on another device. Your value was not saved; refresh the batch and try again."
        case .requestFailed(let code): "The competition server returned HTTP \(code)."
        case .archiveUnavailable: "The completed competition archive is unavailable."
        }
    }
}

private final class CompetitionPresentationAnchor: NSObject, ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApp.keyWindow ?? NSWindow()
    }
}

@MainActor
@Observable
final class CompetitionAccount {
    static let shared = CompetitionAccount()
    private static let cacheKey = "ost.competition.offline-state"
    private static let pendingRatingsKey = "ost.competition.pending-ratings"

    var serverURL = UserDefaults.standard.string(forKey: "ost.competition.server") ?? "" {
        didSet { UserDefaults.standard.set(serverURL, forKey: "ost.competition.server") }
    }
    private(set) var memberships: [CompetitionMembership] = []
    private(set) var batches: [CompetitionBatch] = []
    private(set) var entries: [CompetitionBatchEntry] = []
    private(set) var selectedCompetitionId: String?
    private(set) var selectedBatch: Int?
    private(set) var isHost = false
    private(set) var isBusy = false
    private(set) var isOffline = false
    private(set) var pendingRatingCount = 0
    private(set) var message: String?
    @ObservationIgnored private var nativeSession = CompetitionKeychain.load()
    @ObservationIgnored private var cachingAudioIds: Set<String> = []
    @ObservationIgnored private var webSession: ASWebAuthenticationSession?
    @ObservationIgnored private var competitionPlayer: AVPlayer?
    @ObservationIgnored private var pendingRatings: [PendingCompetitionRating] = []
    @ObservationIgnored private let presentationAnchor = CompetitionPresentationAnchor()

    private init() { restoreLocalState() }

    var isSignedIn: Bool { nativeSession != nil }

    func signIn() {
        do {
            let base = try validatedBaseURL()
            var components = URLComponents(url: base.appending(path: "/login"), resolvingAgainstBaseURL: false)!
            components.queryItems = [URLQueryItem(name: "native", value: "1")]
            guard let url = components.url else { throw CompetitionAccountError.invalidServer }
            let auth = ASWebAuthenticationSession(url: url, callbackURLScheme: "osttracker") { [weak self] callback, error in
                Task { @MainActor in
                    guard let self else { return }
                    if error != nil { self.message = CompetitionAccountError.signInCancelled.localizedDescription; return }
                    guard let callback, callback.host == "competition",
                          let code = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "code" })?.value else {
                        self.message = CompetitionAccountError.invalidCallback.localizedDescription
                        return
                    }
                    await self.exchange(code: code)
                }
            }
            auth.presentationContextProvider = presentationAnchor
            auth.prefersEphemeralWebBrowserSession = false
            webSession = auth
            if !auth.start() { throw CompetitionAccountError.invalidServer }
            message = "Finish passkey sign-in in the secure browser window."
        } catch {
            message = error.localizedDescription
        }
    }

    func signOut() async {
        competitionPlayer?.pause()
        competitionPlayer = nil
        nativeSession = nil
        CompetitionKeychain.clear()
        memberships = []
        batches = []
        entries = []
        selectedCompetitionId = nil
        selectedBatch = nil
        isHost = false
        isOffline = false
        pendingRatingCount = 0
        pendingRatings = []
        UserDefaults.standard.removeObject(forKey: Self.cacheKey)
        UserDefaults.standard.removeObject(forKey: Self.pendingRatingsKey)
        try? FileManager.default.removeItem(at: audioCacheDirectory())
        message = "Signed out of competition. OSTTracker cloud sync is unchanged."
    }

    func refresh() async {
        do {
            let result: CompetitionListResponse = try await get("/api/competitions")
            memberships = result.competitions
            if selectedCompetitionId == nil || !memberships.contains(where: { $0.id == selectedCompetitionId }) {
                selectedCompetitionId = memberships.first?.id
            }
            if let selectedCompetitionId {
                let response = await fetchHostState(selectedCompetitionId)
                isHost = response
                try await loadBatches(competitionId: selectedCompetitionId)
            }
            isOffline = false
            await flushPendingRatings()
            persistLocalState()
            if pendingRatingCount > 0 {
                message = "\(pendingRatingCount) rating(s) are not saved yet. Review conflicts or try again."
            } else {
                message = memberships.isEmpty ? "No competition rounds are available for this account." : "Competition data is up to date."
            }
        } catch {
            isOffline = isNetworkError(error)
            message = isOffline
                ? "Offline. Showing the latest cached competition data. Ratings will be marked not saved until the server confirms them."
                : error.localizedDescription
        }
    }

    func selectCompetition(_ id: String) async {
        selectedCompetitionId = id
        selectedBatch = nil
        entries = []
        isHost = await fetchHostState(id)
        do { try await loadBatches(competitionId: id) }
        catch { message = error.localizedDescription }
    }

    func openBatch(_ number: Int) async {
        guard let competitionId = selectedCompetitionId else { return }
        selectedBatch = number
        do {
            let response: CompetitionEntryListResponse = try await get("/api/competitions/\(competitionId)/batches/\(number)")
            entries = response.entries
            for pending in pendingRatings where pending.write.competitionId == competitionId && pending.write.batch == number {
                if let index = entries.firstIndex(where: { $0.id == pending.write.listeningId }) {
                    entries[index].rating = pending.write.score
                }
            }
            isOffline = false
            persistLocalState()
            message = "Batch \(number) loaded. Ratings are 1 to 10."
        } catch {
            isOffline = isNetworkError(error)
            if !isOffline { entries = [] }
            message = isOffline
                ? "Offline. Showing the latest saved batch."
                : error.localizedDescription
        }
    }

    func rate(_ entry: CompetitionBatchEntry, score: Int) async {
        guard let competitionId = selectedCompetitionId, let selectedBatch else { return }
        let write = CompetitionRatingWrite(competitionId: competitionId, batch: selectedBatch,
                                           listeningId: entry.listeningId, score: score,
                                           expectedVersion: entry.version)
        do {
            let body = try JSONEncoder().encode(write)
            let _: RatingWriteResponse = try await send("PUT", "/api/ratings", body: body)
            isOffline = false
            await openBatch(selectedBatch)
        } catch CompetitionAccountError.staleRating {
            await openBatch(selectedBatch)
            queue(write, needsResolution: true)
            if let index = entries.firstIndex(where: { $0.id == entry.id }) { entries[index].rating = score }
            message = "This rating changed on another device. Use the server's rating or explicitly save your value over it."
        } catch {
            guard isNetworkError(error) else { message = error.localizedDescription; return }
            queue(write)
            if let index = entries.firstIndex(where: { $0.id == entry.id }) { entries[index].rating = score }
            isOffline = true
            message = "Not saved yet. Tap Refresh competitions when you're back online to retry."
        }
    }

    func hasPendingRating(_ entry: CompetitionBatchEntry) -> Bool {
        pendingRatings.contains(where: { $0.write.listeningId == entry.id })
    }

    func needsRatingResolution(_ entry: CompetitionBatchEntry) -> Bool {
        pendingRatings.contains(where: { $0.write.listeningId == entry.id && $0.needsResolution })
    }

    func useServerRating(for entry: CompetitionBatchEntry) async {
        guard !isOffline else {
            message = "Reconnect and refresh before resolving this rating conflict."
            return
        }
        pendingRatings.removeAll(where: { $0.write.listeningId == entry.id })
        persistPendingQueue()
        pendingRatingCount = pendingRatings.count
        if let selectedBatch { await openBatch(selectedBatch) }
        message = "Using the server's saved rating."
    }

    func saveMyPendingRating(for entry: CompetitionBatchEntry) async {
        guard let index = pendingRatings.firstIndex(where: { $0.write.listeningId == entry.id }),
              let competitionId = selectedCompetitionId else { return }
        let queued = pendingRatings[index]
        let write = CompetitionRatingWrite(competitionId: competitionId, batch: queued.write.batch,
                                           listeningId: entry.id, score: queued.write.score,
                                           expectedVersion: entry.version)
        do {
            let body = try JSONEncoder().encode(write)
            let _: RatingWriteResponse = try await send("PUT", "/api/ratings", body: body)
            pendingRatings.removeAll(where: { $0.id == queued.id })
            persistPendingQueue()
            pendingRatingCount = pendingRatings.count
            if let selectedBatch { await openBatch(selectedBatch) }
            message = "Your rating was saved."
        } catch {
            isOffline = isNetworkError(error)
            if let accountError = error as? CompetitionAccountError, case .staleRating = accountError {
                if let selectedBatch { await openBatch(selectedBatch) }
                if let fresh = entries.first(where: { $0.id == entry.id }) {
                    pendingRatings[index].write = CompetitionRatingWrite(
                        competitionId: competitionId, batch: queued.write.batch,
                        listeningId: entry.id, score: queued.write.score,
                        expectedVersion: fresh.version
                    )
                    pendingRatings[index].needsResolution = true
                    persistPendingQueue()
                }
                message = "This rating changed elsewhere. Review the server value before retrying yours."
            } else {
                message = isOffline ? "Not saved yet. Try again when the server is reachable." : error.localizedDescription
            }
        }
    }

    private func queue(_ write: CompetitionRatingWrite, needsResolution: Bool = false) {
        let item = PendingCompetitionRating(write: write, needsResolution: needsResolution)
        if let index = pendingRatings.firstIndex(where: { $0.id == item.id }) {
            pendingRatings[index] = item
        } else {
            pendingRatings.append(item)
        }
        pendingRatingCount = pendingRatings.count
        persistPendingQueue()
        persistLocalState()
    }

    private func flushPendingRatings() async {
        guard let competitionId = selectedCompetitionId else { return }
        for item in pendingRatings where item.write.competitionId == competitionId && !item.needsResolution {
            do {
                let body = try JSONEncoder().encode(item.write)
                let response: RatingWriteResponse = try await send("PUT", "/api/ratings", body: body)
                pendingRatings.removeAll(where: { $0.id == item.id })
                if let index = entries.firstIndex(where: { $0.id == item.write.listeningId }) {
                    entries[index].rating = item.write.score
                    entries[index].version = response.version
                }
                persistPendingQueue()
            } catch CompetitionAccountError.staleRating {
                if let index = pendingRatings.firstIndex(where: { $0.id == item.id }) {
                    pendingRatings[index].needsResolution = true
                }
                if let selectedBatch { await openBatch(selectedBatch) }
                persistPendingQueue()
            } catch {
                isOffline = isNetworkError(error)
                if isOffline { break }
            }
        }
        pendingRatingCount = pendingRatings.count
        persistLocalState()
    }

    private func restoreLocalState() {
        guard let userId = nativeSession?.userId else { return }
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: Self.cacheKey),
           let cached = try? JSONDecoder().decode(CachedCompetitionState.self, from: data),
           cached.userId == userId {
            memberships = cached.memberships
            batches = cached.batches
            isHost = cached.isHost
            selectedCompetitionId = cached.selectedCompetitionId
            selectedBatch = cached.selectedBatch
            entries = cached.entries.map {
                let local = audioCacheURL($0.listeningId)
                return CompetitionBatchEntry(
                    listeningId: $0.listeningId, label: $0.label,
                    audioUrl: FileManager.default.fileExists(atPath: local.path) ? local.absoluteString : "",
                    durationSeconds: $0.durationSeconds, own: $0.own,
                    automaticScore: $0.automaticScore, rating: $0.rating, version: $0.version
                )
            }
            isOffline = true
            message = "Offline. Showing cached competition data from the last successful sync."
        }
        if let data = defaults.data(forKey: Self.pendingRatingsKey),
           let queue = try? JSONDecoder().decode(CachedPendingQueue.self, from: data),
           queue.userId == userId {
            pendingRatings = queue.items
            pendingRatingCount = pendingRatings.count
            for pending in pendingRatings {
                if let index = entries.firstIndex(where: { $0.id == pending.write.listeningId }) {
                    entries[index].rating = pending.write.score
                }
            }
        }
    }

    private func persistLocalState() {
        guard let userId = nativeSession?.userId else { return }
        let cached = CachedCompetitionState(
            userId: userId, memberships: memberships, batches: batches, isHost: isHost,
            selectedCompetitionId: selectedCompetitionId, selectedBatch: selectedBatch,
            entries: entries.map {
                CachedCompetitionEntry(
                    listeningId: $0.listeningId, label: $0.label,
                    durationSeconds: $0.durationSeconds, own: $0.own,
                    automaticScore: $0.automaticScore, rating: $0.rating, version: $0.version
                )
            }
        )
        if let data = try? JSONEncoder().encode(cached) {
            UserDefaults.standard.set(data, forKey: Self.cacheKey)
        }
    }

    private func persistPendingQueue() {
        guard let userId = nativeSession?.userId else { return }
        let queue = CachedPendingQueue(userId: userId, items: pendingRatings)
        if let data = try? JSONEncoder().encode(queue) {
            UserDefaults.standard.set(data, forKey: Self.pendingRatingsKey)
        }
    }

    private func isNetworkError(_ error: Error) -> Bool {
        (error as? URLError) != nil || (error as NSError).domain == NSURLErrorDomain
    }

    private func audioCacheDirectory() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "OSTTracker/CompetitionOfflineAudio", directoryHint: .isDirectory)
    }

    private func audioCacheURL(_ listeningId: String) -> URL {
        audioCacheDirectory().appending(path: "\(listeningId).m4a")
    }

    func play(_ entry: CompetitionBatchEntry) {
        let cachedURL = audioCacheURL(entry.listeningId)
        if FileManager.default.fileExists(atPath: cachedURL.path) {
            competitionPlayer?.pause()
            competitionPlayer = AVPlayer(url: cachedURL)
            competitionPlayer?.play()
            message = "Playing the audio cached on this Mac."
            return
        }
        guard !entry.audioUrl.isEmpty, let url = URL(string: entry.audioUrl), url.scheme == "https" else {
            message = "This clip is not cached yet. Connect once and play it to make the audio available offline."
            return
        }
        if cachingAudioIds.insert(entry.listeningId).inserted {
            message = "Loading and saving this clip on the Mac."
            Task { await cacheAudioAndPlay(entry, from: url) }
        }
    }

    private func cacheAudioAndPlay(_ entry: CompetitionBatchEntry, from url: URL) async {
        defer { cachingAudioIds.remove(entry.listeningId) }
        do {
            let (temporary, response) = try await URLSession.shared.download(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                message = "The audio link expired. Refresh the batch and try again."
                return
            }
            let directory = audioCacheDirectory()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let destination = audioCacheURL(entry.listeningId)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: temporary, to: destination)
            competitionPlayer?.pause()
            competitionPlayer = AVPlayer(url: destination)
            competitionPlayer?.play()
            message = "Playing the clip saved on this Mac for offline listening."
            persistLocalState()
        } catch {
            isOffline = isNetworkError(error)
            message = isOffline
                ? "Offline. This clip has not been saved on this Mac yet."
                : "The clip could not be downloaded. Refresh the batch and try again."
        }
    }

    func archiveCompleted(_ membership: CompetitionMembership) async {
        guard membership.status == "complete" else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            let archive: CompetitionArchive = try await get("/api/competitions/\(membership.id)/archive")
            guard !archive.entries.isEmpty else { throw CompetitionAccountError.archiveUnavailable }
            let archiveDirectory = try await saveArchive(archive, name: membership.name)
            let entries = archive.entries.map {
                CompetitionHistoryEntry(title: $0.title, source: $0.franchise, rank: $0.rank,
                                        meanScore: Double($0.meanScore) ?? 0)
            }
            try await AppStore.shared.importCompetitionHistory(sourceId: membership.id, name: membership.name, entries: entries)
            if isHost {
                let manifest = try Data(contentsOf: archiveDirectory.appending(path: "manifest.json"))
                let digest = SHA256.hash(data: manifest).map { String(format: "%02x", $0) }.joined()
                let payload = try JSONSerialization.data(withJSONObject: ["confirmation": "ARCHIVE VERIFIED", "digest": digest])
                let _: [String: Int] = try await send("POST", "/api/host/competitions/\(membership.id)/archive-originals", body: payload)
                message = "Archive saved on this Mac, imported into OSTTracker history, and cloud originals removed."
            } else {
                message = "Archive saved on this Mac and imported into OSTTracker history."
            }
        } catch { message = "Archive was kept locally where possible. \(error.localizedDescription)" }
    }

    func importLegacyRounds() async {
        guard isHost else { message = "Host access is required to import old OSTTracker rounds."; return }
        isBusy = true
        defer { isBusy = false }
        do {
            let legacyRounds = try await AppStore.shared.legacyRoundArchives()
            guard !legacyRounds.isEmpty else { message = "This Mac has no retired OSTTracker rankings to import."; return }
            let cloudSession = try await CloudAccount.shared.client.auth.session
            let cloudUserId = cloudSession.user.id.uuidString
            var imported = 0
            for archive in legacyRounds {
                guard let payload = try JSONSerialization.jsonObject(with: Data(archive.payloadJson.utf8)) as? [String: Any] else { continue }
                let sourceId = Self.legacySourceId(userId: cloudUserId, roundId: archive.id)
                let body = try JSONSerialization.data(withJSONObject: ["sourceId": sourceId, "name": archive.name, "payload": payload])
                let response: LegacyImportResponse = try await send("POST", "/api/host/legacy-import", body: body)
                if response.imported { imported += 1 }
            }
            message = "Imported \(imported) past OSTTracker ranking(s) into the private legacy archive list."
        } catch { message = error.localizedDescription }
    }

    private static func legacySourceId(userId: String, roundId: Int) -> String {
        let digest = Array(SHA256.hash(data: Data("osttracker-legacy-\(userId)-\(roundId)".utf8)))
        var hex = digest.prefix(16).map { String(format: "%02x", $0) }.joined()
        var chars = Array(hex)
        chars[12] = "5"
        chars[16] = "8"
        hex = String(chars)
        return "\(hex.prefix(8))-\(hex.dropFirst(8).prefix(4))-\(hex.dropFirst(12).prefix(4))-\(hex.dropFirst(16).prefix(4))-\(hex.dropFirst(20))"
    }

    private func exchange(code: String) async {
        do {
            let payload = try JSONSerialization.data(withJSONObject: ["code": code])
            let response: NativeExchange = try await sendUnauthenticated("POST", "/api/auth/native/exchange", body: payload)
            nativeSession = NativeSession(accessToken: response.accessToken, refreshToken: response.refreshToken,
                                          expiresAt: response.expiresAt, userId: response.userId)
            CompetitionKeychain.save(nativeSession!)
            await refresh()
        } catch { message = error.localizedDescription }
    }

    private func loadBatches(competitionId: String) async throws {
        let result: CompetitionBatchListResponse = try await get("/api/competitions/\(competitionId)/batches")
        batches = result.batches
        selectedBatch = batches.first(where: { $0.status == "released" })?.number
        if let selectedBatch { await openBatch(selectedBatch) }
    }

    private func fetchHostState(_ id: String) async -> Bool {
        struct HostResponse: Decodable { let state: HostRoundState? }
        struct HostRoundState: Decodable { let name: String; let status: String }
        do {
            let _: HostResponse = try await get("/api/host/competitions/\(id)")
            return true
        } catch { return false }
    }

    private func saveArchive(_ archive: CompetitionArchive, name: String) async throws -> URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "OSTTracker/CompetitionArchives/\(archive.competitionId)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var entries = archive.entries
        for index in entries.indices {
            guard let audio = URL(string: entries[index].audioUrl ?? "") else { throw CompetitionAccountError.archiveUnavailable }
            let (data, response) = try await URLSession.shared.data(from: audio)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw CompetitionAccountError.archiveUnavailable }
            let filename = "\(entries[index].listeningId).m4a"
            try data.write(to: root.appending(path: filename), options: .atomic)
            entries[index].audioFilename = filename
            entries[index].audioUrl = nil
        }
        var originalFiles: [String] = []
        for (index, urlString) in archive.originals.enumerated() {
            guard let url = URL(string: urlString) else { throw CompetitionAccountError.archiveUnavailable }
            let (temporary, response) = try await URLSession.shared.download(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw CompetitionAccountError.archiveUnavailable }
            let suffix = URLComponents(url: url, resolvingAgainstBaseURL: false)?.path.split(separator: "/").last.map { URL(fileURLWithPath: String($0)).pathExtension } ?? "bin"
            let filename = String(format: "original-%03d.%@", index + 1, suffix.isEmpty ? "bin" : suffix)
            try FileManager.default.moveItem(at: temporary, to: root.appending(path: filename))
            originalFiles.append(filename)
        }
        let manifest = CompetitionArchiveManifest(competitionId: archive.competitionId, name: name, archivedAt: Date(), entries: entries, originalFiles: originalFiles)
        let data = try JSONEncoder().encode(manifest)
        try data.write(to: root.appending(path: "manifest.json"), options: .atomic)
        return root
    }

    private struct CompetitionArchiveManifest: Encodable {
        let competitionId: String
        let name: String
        let archivedAt: Date
        let entries: [CompetitionArchiveEntry]
        let originalFiles: [String]
    }

    private struct LegacyImportResponse: Decodable { let imported: Bool }

    private func validatedBaseURL() throws -> URL {
        guard let url = URL(string: serverURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme == "https", url.host != nil, url.user == nil, url.password == nil,
              url.path.isEmpty || url.path == "/" else { throw CompetitionAccountError.invalidServer }
        return URL(string: "https://\(url.host!)")!
    }

    private func origin() throws -> String {
        let url = try validatedBaseURL()
        return "\(url.scheme ?? "https")://\(url.host ?? "")"
    }

    private func get<T: Decodable>(_ path: String) async throws -> T {
        try await request("GET", path, body: nil, allowRefresh: true)
    }

    private func send<T: Decodable>(_ method: String, _ path: String, body: Data) async throws -> T {
        try await request(method, path, body: body, allowRefresh: true)
    }

    private func sendUnauthenticated<T: Decodable>(_ method: String, _ path: String, body: Data) async throws -> T {
        var request = URLRequest(url: try validatedBaseURL().appending(path: path))
        request.httpMethod = method
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(try origin(), forHTTPHeaderField: "Origin")
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func request<T: Decodable>(_ method: String, _ path: String, body: Data?, allowRefresh: Bool) async throws -> T {
        guard var session = nativeSession ?? CompetitionKeychain.load() else { throw CompetitionAccountError.invalidCallback }
        if session.expiresAt <= Int(Date().timeIntervalSince1970) + 60 {
            session = try await refreshSession(session)
        }
        var request = URLRequest(url: try validatedBaseURL().appending(path: path))
        request.httpMethod = method
        request.httpBody = body
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        if body != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(try origin(), forHTTPHeaderField: "Origin")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        if (response as? HTTPURLResponse)?.statusCode == 401, allowRefresh {
            nativeSession = try await refreshSession(session)
            return try await self.request(method, path, body: body, allowRefresh: false)
        }
        try validate(response)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func refreshSession(_ current: NativeSession) async throws -> NativeSession {
        let body = try JSONSerialization.data(withJSONObject: ["refreshToken": current.refreshToken])
        let refreshed: NativeExchange = try await sendUnauthenticated("POST", "/api/auth/native/refresh", body: body)
        let session = NativeSession(accessToken: refreshed.accessToken, refreshToken: refreshed.refreshToken,
                                    expiresAt: refreshed.expiresAt, userId: refreshed.userId)
        nativeSession = session
        CompetitionKeychain.save(session)
        return session
    }

    private func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw CompetitionAccountError.requestFailed(0) }
        if http.statusCode == 409 { throw CompetitionAccountError.staleRating }
        guard (200..<300).contains(http.statusCode) else { throw CompetitionAccountError.requestFailed(http.statusCode) }
    }
}

private enum CompetitionKeychain {
    private static let service = "com.brajanzalta.OSTTracker.competition"
    private static let account = "native-session"

    static func load() -> NativeSession? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account,
                                    kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(NativeSession.self, from: data)
    }

    static func save(_ session: NativeSession) {
        guard let data = try? JSONEncoder().encode(session) else { return }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account]
        let update: [String: Any] = [kSecValueData as String: data,
                                    kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        if SecItemUpdate(query as CFDictionary, update as CFDictionary) == errSecItemNotFound {
            var item = query
            update.forEach { item[$0.key] = $0.value }
            SecItemAdd(item as CFDictionary, nil)
        }
    }

    static func clear() {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword,
                       kSecAttrService as String: service,
                       kSecAttrAccount as String: account] as CFDictionary)
    }
}

struct CompetitionAccountSection: View {
    @State private var account = CompetitionAccount.shared
    @State private var pendingArchive: CompetitionMembership?

    var body: some View {
        Section("Competition account") {
            TextField("Permanent HTTPS website", text: $account.serverURL)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Permanent competition website")
            HStack {
                if account.isSignedIn {
                    Button("Refresh competitions") { Task { await account.refresh() } }
                    Button("Sign out") { Task { await account.signOut() } }
                } else {
                    Button("Sign in with passkey") { account.signIn() }
                        .disabled(account.serverURL.isEmpty)
                }
            }
            if let message = account.message { Text(message).font(.caption).foregroundStyle(.secondary) }
            if account.isOffline {
                Label("Offline · cached competition data", systemImage: "wifi.slash")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if account.pendingRatingCount > 0 {
                Label("\(account.pendingRatingCount) rating(s) not saved yet", systemImage: "arrow.clockwise")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Theme.accent)
            }
            if account.isHost {
                Button("Import past OSTTracker rankings") { Task { await account.importLegacyRounds() } }
                    .disabled(account.isBusy)
            }
            ForEach(account.memberships) { round in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(round.name).font(.headline)
                        if round.isTrial { Text("TRIAL").font(.caption2.bold()).foregroundStyle(Theme.accent) }
                        Spacer()
                        Text(round.status.replacingOccurrences(of: "_", with: " ")).font(.caption).foregroundStyle(.secondary)
                    }
                    if round.status == "listening", account.selectedCompetitionId == round.id {
                        HStack {
                            ForEach(account.batches) { batch in
                                Button("Batch \(batch.number)") { Task { await account.openBatch(batch.number) } }
                                    .disabled(batch.status != "released")
                            }
                        }
                        ForEach(account.entries) { entry in
                            VStack(alignment: .leading, spacing: 5) {
                                HStack {
                                    Text(entry.label).font(.subheadline.weight(.semibold))
                                    Button("Play") { account.play(entry) }
                                    if entry.own { Text("Your entry · automatic 10").font(.caption).foregroundStyle(.secondary) }
                                    Spacer()
                                    if account.hasPendingRating(entry) {
                                        Text("Not saved yet · \(entry.rating ?? 0)/10").font(.caption).foregroundStyle(Theme.accent)
                                    } else if let rating = entry.rating {
                                        Text("Saved \(rating)/10").font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                if account.needsRatingResolution(entry) {
                                    HStack {
                                        Text("The server has a newer rating.").font(.caption).foregroundStyle(.secondary)
                                        Button("Use server") { Task { await account.useServerRating(for: entry) } }
                                            .disabled(account.isOffline)
                                        Button("Save mine") { Task { await account.saveMyPendingRating(for: entry) } }
                                            .disabled(account.isOffline)
                                    }
                                }
                                if !entry.own {
                                    HStack(spacing: 4) {
                                        ForEach(1...10, id: \.self) { score in
                                            Button("\(score)") { Task { await account.rate(entry, score: score) } }
                                                .buttonStyle(.bordered)
                                                .controlSize(.small)
                                                .accessibilityLabel("\(entry.label), rating \(score) of 10")
                                        }
                                    }
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    } else if round.status == "listening" {
                        Button("Open listening") { Task { await account.selectCompetition(round.id) } }
                    }
                    if round.status == "complete" {
                        Button("Archive and remove cloud originals…") { pendingArchive = round }
                            .disabled(account.isBusy)
                    }
                }
                .padding(.vertical, 6)
            }
        }
        .task { if account.isSignedIn { await account.refresh() } }
        .confirmationDialog(
            "Archive this completed competition?",
            isPresented: Binding(get: { pendingArchive != nil }, set: { if !$0 { pendingArchive = nil } }),
            titleVisibility: .visible,
        ) {
            Button("Archive and remove cloud originals", role: .destructive) {
                guard let round = pendingArchive else { return }
                pendingArchive = nil
                Task { await account.archiveCompleted(round) }
            }
            Button("Cancel", role: .cancel) { pendingArchive = nil }
        } message: {
            Text("This saves every released audio clip and, for the host, each original video to this Mac. It imports the ranking titles into OSTTracker history, then removes original videos from cloud storage. Original uploads can be as large as 500 MB each.")
        }
    }
}
#endif
