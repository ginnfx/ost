import Foundation

/// The UI talks to this small backend surface. macOS uses the Python service;
/// iOS uses its on-device store so core data work is available offline.
protocol OSTBackend: Sendable {
    func waitUntilHealthy(timeout: Duration) async throws
    func syncSnapshot() async throws -> Data
    func applySyncSnapshot(_ snapshot: Data) async throws
    func people() async throws -> [Person]
    func addPerson(name: String) async throws -> Person
    func deletePerson(id: Int) async throws
    func addOst(_ new: NewOst) async throws -> Ost
    func deleteOst(id: Int) async throws
    func coverCandidates(ostID: Int) async throws -> [CoverCandidate]
    func setCover(ostID: Int, imageURL: String) async throws -> Ost
    func cover(ostID: Int) async throws -> Data
    func ratings(raterID: Int?) async throws -> [Rating]
    func putRating(_ upsert: RatingUpsert) async throws
    func putRatingsBulk(_ upserts: [RatingUpsert]) async throws
    func revealState() async throws -> RevealState
    func setReveal(_ unlocked: Bool) async throws -> RevealState
    func batches() async throws -> Batches
    func randomizeBatches() async throws -> Batches
    func setBatchCount(_ count: Int) async throws -> Batches
    func arrangeBatches(_ batches: [[Int]]) async throws -> Batches
    func setPin(ostID: Int, pinned: Bool) async throws -> Batches
    func notes() async throws -> [Note]
    func searchCatalog(_ query: String) async throws -> [CatalogTrack]
    func addNote(_ new: NewNote) async throws -> Note
    func updateNote(id: Int, _ patch: NotePatch) async throws -> Note
    func deleteNote(id: Int) async throws
    func history() async throws -> [HistoryEntry]
    func renameHistoryLabel(from oldLabel: String, to newLabel: String) async throws
    func roundStatus() async throws -> RoundStatus
    func startRound(name: String) async throws -> RoundStatus
    func retireChallenge() async throws -> RetireChallenge
    func retireRound(challengeId: String, word: String) async throws
    func restoreRound(id: Int) async throws
    func roundArchive(id: Int) async throws -> RoundArchiveDetail
    func importCompetitionHistory(sourceId: String, name: String, entries: [CompetitionHistoryEntry]) async throws
    func leaderboard() async throws -> [RankEntry]
    func elimination() async throws -> EliminationBoard
    func setEliminationThreshold(_ threshold: Int) async throws -> EliminationBoard
    func startResolve(ostID: Int) async throws
    func play(ostID: Int) async throws -> PlaybackState
    func pause() async throws -> PlaybackState
    func seek(position: Double) async throws -> PlaybackState
    func stop() async throws -> PlaybackState
    func events() async -> AsyncThrowingStream<WSEvent, Error>
}

nonisolated extension OSTBackend {
    func roundArchive(id: Int) async throws -> RoundArchiveDetail { throw BackendError.healthTimeout }
    func importCompetitionHistory(sourceId: String, name: String, entries: [CompetitionHistoryEntry]) async throws {
        throw BackendError.healthTimeout
    }
}
