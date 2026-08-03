// The app's central store. Owns the sidecar lifecycle, the networking
// actor, the /ws event pump, and the AVPlayer sink. Views read state and call
// intents; every business decision happens in Python.

import Foundation
import Observation

@Observable
final class AppStore {
    static let shared = AppStore()

    enum Phase: Equatable {
        case launching
        case running(port: Int)
        case failed(String)
    }

    private(set) var phase: Phase = .launching
    private(set) var people: [Person] = []
    private(set) var leaderboard: [RankEntry] = []
    private(set) var notes: [Note] = []
    // Private batch key (host-only). Loaded on launch, replaced on randomize.
    private(set) var batches: [BatchGroup] = []
    private(set) var batchesGeneratedAt: String?
    /// Slice-elimination board (rank slices, per-slice out-tallies, placements).
    /// Derived from the leaderboard server-side, so it is re-fetched alongside it.
    private(set) var elimination: EliminationBoard?
    /// Every OST ever ranked, past or current — the dedup exclusion list.
    /// Read-only display data; the hard block itself is enforced server-side.
    private(set) var history: [HistoryEntry] = []
    private(set) var scores: [Int: [Int: Double]] = [:]     // ost -> rater -> score (0–10 decimal)
    private(set) var playback: PlaybackState?
    private(set) var resolutionPhase: [Int: ResolutionPhase] = [:]
    private(set) var lastEventDescription = "none yet"
    // The backend rewrites covers IN PLACE (always cover_<id>.jpg), so the path
    // string never changes when the art does. Per-OST counters are folded into
    // CoverImage's identity; bumping one forces a fresh disk read for THAT cover
    // only — a global counter would re-decode every visible cover on any change.
    private(set) var coverEpochs: [Int: Int] = [:]
    private(set) var hasRevealed = false                    // roster reveal ran once
    /// Rank movement since the previous leaderboard state (ost -> delta,
    /// positive = climbed). Populated on re-sorts, swept clean ~4s later so the
    /// ▲/▼ chips read as news, then leave.
    private(set) var rankDeltas: [Int: Int] = [:]
    private var rankDeltaSweep: Task<Void, Never>?
    /// One-line failure banner (RootView renders it). Every intent that talks
    /// to the backend reports rejected writes here; auto-clears after a beat.
    private(set) var lastError: String?
    private var errorSweep: Task<Void, Never>?

    let player = PlayerSink()

    #if os(macOS)
    private let sidecar = SidecarProcess()
    #endif
    private(set) var client: BackendClient?
    private var eventPump: Task<Void, Never>?
    // Ordering token for leaderboard fetches: without it, two in-flight GETs can
    // land out of issue order and a stale response clobbers a fresher one.
    private var leaderboardFetchSeq = 0
    private var leaderboardRefreshTask: Task<Void, Never>?
    // Last time a leaderboardResorted push landed on /ws. rate() skips the
    // HTTP re-fetch when a push for the same write is likely on its way.
    private var lastBoardEventAt = Date.distantPast
    private var eliminationRefreshTask: Task<Void, Never>?
    // Same last-issued-wins guard for the elimination board, which is fetched
    // right behind every leaderboard change.
    private var eliminationFetchSeq = 0

    var nowPlayingEntry: RankEntry? {
        guard let id = playback?.ostId else { return nil }
        return leaderboard.first { $0.ost.id == id }
    }

    // MARK: - Lifecycle

    func start() async {
        // When a track plays to its end, tell Python to leave the .playing state
        // so every audio-reactive animation quiets down instead of compositing on
        // silence forever.
        player.onEnded = { [weak self] in
            Task { await self?.stop() }
        }
        // Packaged builds refresh the writable yt-dlp layer in the background
        // on every launch; yt-dlp ages poorly and lives outside the
        // signed bundle. Dev builds use the repo venv untouched.
        #if os(macOS)
        if SidecarConfiguration.packaged() != nil {
            Task.detached(priority: .utility) { try? await WritableLayer.update() }
        }
        #endif
        do {
            #if os(iOS)
            let shake = try await EmbeddedSidecar.start()
            #else
            let shake = try await sidecar.launch()
            #endif
            let client = BackendClient(port: shake.port, token: shake.token)
            self.client = client
            try await client.waitUntilHealthy()
            print("GATE health ok")
            try await refreshAll(client)
            print("GATE osts count=\(leaderboard.count)")
            startEventPump(client)
            phase = .running(port: shake.port)
        } catch {
            phase = .failed(String(describing: error))
            print("GATE failed error=\(error)")
        }
    }

    func shutdown() {
        eventPump?.cancel()
        #if os(macOS)
        sidecar.terminate()
        #endif
    }

    func markRevealed() { hasRevealed = true }

    private func refreshAll(_ client: BackendClient) async throws {
        async let people = client.people()
        async let board = client.leaderboard()
        async let ratings = client.ratings()
        async let notes = client.notes()
        async let batches = client.batches()
        // Never fatal to launch: an elimination board that fails to load just
        // leaves the roster's slice mode empty until the next refresh.
        async let elimination = client.elimination()
        async let history = client.history()
        self.people = try await people
        self.leaderboard = Self.rosterOrder(try await board)
        self.elimination = try? await elimination
        self.history = (try? await history) ?? []
        self.notes = try await notes
        self.scores = Self.index(try await ratings)
        let batchData = try await batches
        self.batches = batchData.batches
        self.batchesGeneratedAt = batchData.generatedAt
    }

    nonisolated static func index(_ ratings: [Rating]) -> [Int: [Int: Double]] {
        ratings.reduce(into: [:]) { acc, r in
            acc[r.ostId, default: [:]][r.raterId] = r.score
        }
    }

    /// Roster display order: by server-computed rank, unranked last (by
    /// title). Pure presentation ordering of Python's numbers.
    nonisolated static func rosterOrder(_ entries: [RankEntry]) -> [RankEntry] {
        entries.sorted {
            ($0.rank ?? .max, $0.ost.title.lowercased())
                < ($1.rank ?? .max, $1.ost.title.lowercased())
        }
    }

    // MARK: - Intents (thin passthroughs to Python)

    func rate(ostID: Int, raterID: Int, score: Double?) async {
        guard let client else { return }
        // Optimistic: reflect the tap immediately so the digit highlights without
        // waiting on the /ws round-trip (and works even while the socket is down).
        let previous = scores[ostID]?[raterID]
        setLocalScore(ostID: ostID, raterID: raterID, score: score)
        do {
            try await client.putRating(RatingUpsert(ostId: ostID, raterId: raterID, score: score))
            // The server broadcasts leaderboardResorted for this write; when the
            // socket is up that push re-renders the board. Only fall back to an
            // HTTP re-fetch when the push hasn't landed (socket down) so a burst
            // of entry taps doesn't double-fetch every time.
            if Date().timeIntervalSince(lastBoardEventAt) > 1.5 {
                await refreshLeaderboard()
            }
        } catch {
            // Server rejected the write — roll the optimistic change back and surface it.
            setLocalScore(ostID: ostID, raterID: raterID, score: previous)
            reportError("Couldn't save rating (\(error.localizedDescription)). Reverted.")
        }
    }

    private func reportError(_ message: String) {
        lastError = message
        errorSweep?.cancel()
        errorSweep = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            self?.lastError = nil
        }
    }

    private func setLocalScore(ostID: Int, raterID: Int, score: Double?) {
        if let score {
            scores[ostID, default: [:]][raterID] = score
        } else {
            scores[ostID]?[raterID] = nil
        }
    }

    func play(ostID: Int) async {
        guard let client else { return }
        do {
            _ = try await client.play(ostID: ostID)
        } catch {
            reportError("Couldn't start playback (\(error.localizedDescription)).")
        }
    }

    func pause() async {
        do { _ = try await client?.pause() } catch { reportError("Couldn't pause (\\(error.localizedDescription)).") }
    }

    func stop() async {
        do { _ = try await client?.stop() } catch { reportError("Couldn't stop (\\(error.localizedDescription)).") }
    }

    func seek(to seconds: Double) async {
        player.seek(to: seconds)
        do { _ = try await client?.seek(position: seconds) } catch { reportError("Couldn't seek (\\(error.localizedDescription)).") }
    }

    /// Returns false when the backend rejected the add, so the sheet can stay
    /// open instead of playing the success ding over a failure.
    @discardableResult
    func addOst(title: String, source: String?, submitterID: Int?, link: String?) async -> Bool {
        guard let client else { return false }
        do {
            _ = try await client.addOst(NewOst(
                title: title, source: source, submitterId: submitterID, externalLink: link
            ))
        } catch {
            reportError("Couldn't add \"\(title)\" (\(error.localizedDescription)).")
            return false
        }
        // Show the new card (and its seeded self-rating) immediately, /ws or not.
        await resync()
        await refreshHistory()
        return true
    }

    /// Distinct franchise/source values across all loaded OSTs, for the Add-OST
    /// source autocomplete. Derived from already-loaded leaderboard data — no
    /// extra round-trip. Case-insensitive de-dupe, first spelling wins.
    var distinctSources: [String] {
        var seen = Set<String>()
        var out: [String] = []
        for entry in leaderboard {
            guard let raw = entry.ost.source?.trimmingCharacters(in: .whitespaces),
                  !raw.isEmpty, seen.insert(raw.lowercased()).inserted else { continue }
            out.append(raw)
        }
        return out.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    func coverCandidates(ostID: Int) async -> [CoverCandidate] {
        (try? await client?.coverCandidates(ostID: ostID)) ?? []
    }

    /// Epoch for one OST's cover file; part of CoverImage's identity so bumping
    /// it forces that cover (and only that cover) to re-read from disk.
    func coverEpoch(for ostID: Int?) -> Int {
        guard let ostID else { return 0 }
        return coverEpochs[ostID, default: 0]
    }

    private func bumpCoverEpoch(_ ostID: Int) {
        coverEpochs[ostID, default: 0] += 1
    }

    func setCover(ostID: Int, imageURL: String) async {
        guard let client else { return }
        // Only refresh + bump on success: a failed apply must not force cover
        // re-reads, and the user needs to hear about it.
        guard (try? await client.setCover(ostID: ostID, imageURL: imageURL)) != nil else {
            reportError("Couldn't apply that cover (bad URL or the image failed to download).")
            return
        }
        // Pull the refreshed leaderboard so the new cover path + accent land even
        // if the /ws coverArtReady event is missed.
        await resync()
        bumpCoverEpoch(ostID)
    }

    func addPerson(name: String) async {
        guard let client else { return }
        do {
            let person = try await client.addPerson(name: name)
            people = (people + [person]).sorted { $0.name.lowercased() < $1.name.lowercased() }
        } catch {
            reportError("Couldn't add \"\(name)\" (\(error.localizedDescription)).")
        }
    }

    func deletePerson(id: Int) async {
        guard let client else { return }
        // Local state only changes on a confirmed delete: dropping the person
        // optimistically after a failed DELETE leaves their ratings haunting
        // the leaderboard with no row in People until relaunch.
        do {
            try await client.deletePerson(id: id)
        } catch {
            reportError("Couldn't delete that person (\(error.localizedDescription)).")
            return
        }
        people.removeAll { $0.id == id }
        // Their ratings cascade away and their OSTs lose their submitter server-side;
        // resync pulls the recomputed leaderboard + ratings.
        await resync()
    }

    /// Returns false when there's no client or the DELETE is rejected, so the
    /// confirmation dialog can leave the panel open instead of closing over a
    /// failure.
    @discardableResult
    func deleteOst(id: Int) async -> Bool {
        guard let client else { return false }
        // Same confirmed-delete-only rule as deletePerson: dropping the card
        // before the server agrees leaves a ghost row that resurrects on resync.
        do {
            try await client.deleteOst(id: id)
        } catch {
            reportError("Couldn't delete that OST (\(error.localizedDescription)).")
            return false
        }
        if playback?.ostId == id {
            // Ask the server to stop too, but tear down locally unconditionally:
            // if the server stop fails or /ws is down, a deleted OST must not
            // keep making sound regardless of that round-trip's outcome.
            await stop()
            playback = nil
            player.reset()
        }
        // Don't mutate leaderboard/scores here — DetailView is likely still open
        // and re-renders off `entry` immediately, which would flash
        // ContentUnavailableView during this round-trip. Resync (or the
        // backend's own leaderboardResorted broadcast) lands asynchronously instead.
        Task { await resync() }
        return true
    }

    func addNote(title: String, body: String) async {
        guard let client else { return }
        do {
            let note = try await client.addNote(NewNote(title: title, note: body))
            notes = [note] + notes
        } catch {
            reportError("Couldn't save that note (\(error.localizedDescription)).")
        }
    }

    func updateNote(id: Int, title: String, body: String) async {
        guard let client else { return }
        do {
            let updated = try await client.updateNote(id: id, NotePatch(title: title, note: body))
            notes = notes.map { $0.id == id ? updated : $0 }
        } catch {
            reportError("Couldn't update that note (\(error.localizedDescription)).")
        }
    }

    func deleteNote(id: Int) async {
        guard let client else { return }
        do {
            try await client.deleteNote(id: id)
        } catch {
            reportError("Couldn't delete that note (\(error.localizedDescription)).")
            return
        }
        notes.removeAll { $0.id == id }
    }

    /// Re-shuffle the private batch key. Pins stay fixed server-side; every
    /// other OST lands in a fresh random slot. The new arrangement is persisted
    /// by the backend and returned here in one round-trip.
    func randomizeBatches() async {
        guard let client else { return }
        do {
            let result = try await client.randomizeBatches()
            batches = result.batches
            batchesGeneratedAt = result.generatedAt
        } catch {
            reportError("Couldn't randomize batches (\(error.localizedDescription)).")
        }
    }

    /// Change how many batches the OSTs split into (2/3/4…). The server re-flows
    /// the current order into the new sizes and echoes the arrangement back.
    func setBatchCount(_ count: Int) async {
        guard let client else { return }
        do {
            let result = try await client.setBatchCount(count)
            batches = result.batches
            batchesGeneratedAt = result.generatedAt
        } catch {
            reportError("Couldn't change batch count (\(error.localizedDescription)).")
        }
    }

    /// Persist a hand-placed arrangement (drag-and-drop). `arrangement` is the
    /// full nested list of OST ids in host order. Server validates + echoes.
    func arrangeBatches(_ arrangement: [[Int]]) async {
        guard let client else { return }
        do {
            let result = try await client.arrangeBatches(arrangement)
            batches = result.batches
            batchesGeneratedAt = result.generatedAt
        } catch {
            reportError("Couldn't save that arrangement (\(error.localizedDescription)).")
        }
    }

    /// Pin/unpin one OST so it keeps its slot through re-randomize + slide-in.
    func setPin(ostID: Int, pinned: Bool) async {
        guard let client else { return }
        do {
            let result = try await client.setPin(ostID: ostID, pinned: pinned)
            batches = result.batches
            batchesGeneratedAt = result.generatedAt
        } catch {
            reportError("Couldn't \(pinned ? "pin" : "unpin") that OST (\(error.localizedDescription)).")
        }
    }

    // MARK: - /ws pump

    /// Long-lived /ws pump that survives socket drops. On any drop it resyncs
    /// missed state over HTTP and reconnects with capped exponential backoff, so
    /// a sleep/wake or network blip never leaves the UI permanently stale.
    private func startEventPump(_ client: BackendClient) {
        eventPump = Task { [weak self] in
            var needsResync = false
            var backoffMs: UInt64 = 400
            while !Task.isCancelled {
                if needsResync {
                    await self?.resync()   // re-fetch anything missed while disconnected
                    needsResync = false
                }
                var sawEvents = false
                do {
                    for try await event in await client.events() {
                        self?.apply(event)
                        sawEvents = true
                        backoffMs = 400    // healthy traffic resets the backoff
                    }
                    self?.lastEventDescription = "ws closed; reconnecting"
                    print("GATE ws closed_by_server, reconnecting")
                } catch {
                    self?.lastEventDescription = "ws dropped: \(error.localizedDescription)"
                    print("GATE ws dropped=\(error.localizedDescription), reconnecting")
                }
                if Task.isCancelled { break }
                // Only pay for a full server resync when this connection actually
                // delivered events (a genuine healthy-then-dropped session). A
                // socket that closes immediately on accept, over and over, must
                // not trigger a leaderboard+ratings+batches+people recompute every
                // few seconds — that pegs the sidecar/SQLite and warms the CPU.
                if sawEvents { needsResync = true }
                try? await Task.sleep(for: .milliseconds(backoffMs))
                backoffMs = min(backoffMs * 2, 8_000)
            }
        }
    }

    private func restartEventPump() {
        eventPump?.cancel()
        if let client { startEventPump(client) }
    }

    /// Re-fetch server-authoritative state over HTTP (used after a /ws reconnect
    /// and on scene re-activation). Never recomputes anything locally.
    /// Fetch the leaderboard guarded by a sequence token: only the most recently
    /// ISSUED fetch may assign, so a slow stale response can never overwrite a
    /// fresher one (last-issued wins, not last-landed).
    private func refreshLeaderboard() async {
        guard let client else { return }
        leaderboardFetchSeq += 1
        let seq = leaderboardFetchSeq
        guard let board = try? await client.leaderboard() else { return }
        guard seq == leaderboardFetchSeq else { return }   // superseded while in flight
        applyLeaderboard(board)
        scheduleEliminationRefresh()
    }

    /// Pull the recomputed slice/elimination board. Same last-issued-wins rule
    /// as the leaderboard so a slow response can't overwrite a fresher one.
    private func refreshElimination() async {
        guard let client else { return }
        eliminationFetchSeq += 1
        let seq = eliminationFetchSeq
        guard let board = try? await client.elimination() else { return }
        guard seq == eliminationFetchSeq else { return }
        elimination = board
    }

    /// Coalesces refreshElimination() calls that land close together — a
    /// local rating triggers one via refreshLeaderboard() while the
    /// leaderboardResorted WS broadcast (echoing that same change, or one
    /// from another client) triggers another; without this both fire a
    /// GET /elimination. Same debounce shape as scheduleLeaderboardRefresh.
    private func scheduleEliminationRefresh() {
        eliminationRefreshTask?.cancel()
        eliminationRefreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            await self?.refreshElimination()
        }
    }

    /// Change how many OSTs a person may lose before elimination. Persisted in
    /// Python; the recomputed board comes back in the same round-trip.
    func setEliminationThreshold(_ threshold: Int) async {
        guard let client else { return }
        eliminationRefreshTask?.cancel()
        do {
            elimination = try await client.setEliminationThreshold(threshold)
            eliminationFetchSeq += 1   // this response is the freshest board
        } catch {
            reportError("Couldn't change the elimination threshold (\(error.localizedDescription)).")
        }
    }

    /// Assign a fresh leaderboard and record rank movement vs. the outgoing one.
    private func applyLeaderboard(_ entries: [RankEntry]) {
        let oldRanks = Dictionary(
            uniqueKeysWithValues: leaderboard.compactMap { e in e.rank.map { (e.ost.id, $0) } }
        )
        leaderboard = Self.rosterOrder(entries)
        guard !oldRanks.isEmpty else { return }   // initial load isn't "movement"
        var moved: [Int: Int] = [:]
        for entry in leaderboard {
            if let old = oldRanks[entry.ost.id], let new = entry.rank, old != new {
                moved[entry.ost.id] = old - new   // positive = climbed
            }
        }
        guard !moved.isEmpty else { return }
        rankDeltas.merge(moved) { _, new in new }
        rankDeltaSweep?.cancel()
        rankDeltaSweep = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.rankDeltas = [:]
        }
    }

    /// Coalesce bursts of refresh triggers (e.g. many coverArtReady events while
    /// covers resolve after a batch add) into a single fetch shortly after the
    /// last trigger, instead of N full round-trips.
    private func scheduleLeaderboardRefresh() {
        leaderboardRefreshTask?.cancel()
        leaderboardRefreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            await self?.refreshLeaderboard()
        }
    }

    // History is append-only and written only by this app's own addOst path
    // (a rename can also touch it, but only via PATCH /osts, which no Swift
    // caller uses today) — unlike the leaderboard/batches/ratings, it can't
    // change out from under a WS reconnect, so resync() doesn't refetch it.
    // It's loaded at launch (refreshAll) and refreshed after each successful
    // add; an out-of-band API rename self-corrects on next launch.
    func resync() async {
        guard let client else { return }
        await refreshLeaderboard()
        await refreshBatches()
        if let ratings = try? await client.ratings() { scores = Self.index(ratings) }
        print("GATE ws resynced osts=\(leaderboard.count)")
    }

    private func refreshHistory() async {
        guard let client, let history = try? await client.history() else { return }
        self.history = history
    }

    /// Reload the batch key (non-throwing). New OSTs are slid into the existing
    /// arrangement server-side, so this reflects adds without a re-randomize.
    private func refreshBatches() async {
        guard let client, let data = try? await client.batches() else { return }
        batches = data.batches
        batchesGeneratedAt = data.generatedAt
    }

    /// Called on scenePhase == .active (e.g. sleep/wake): reconnect the socket
    /// immediately rather than waiting out the backoff, and resync.
    func onBecameActive() {
        guard case .running = phase, client != nil else { return }
        restartEventPump()
        Task { await resync() }
    }

    private func apply(_ event: WSEvent) {
        switch event {
        case .playbackState(let state):
            playback = state
            player.apply(state)
            if let id = state.ostId, state.status == .playing {
                resolutionPhase[id] = nil
            }
            lastEventDescription = "playbackState(\(state.status.rawValue))"
        case .resolutionProgress(let ostID, let phase):
            resolutionPhase[ostID] = phase
            if phase == .ready || phase == .failed {
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    if resolutionPhase[ostID] == phase { resolutionPhase[ostID] = nil }
                }
            }
            lastEventDescription = "resolutionProgress(ost \(ostID): \(phase.rawValue))"
        case .ratingUpdated(let ostID, let raterID, let score):
            scores[ostID, default: [:]][raterID] = score
            lastEventDescription = "ratingUpdated(ost \(ostID), rater \(raterID))"
        case .leaderboardResorted(let entries):
            applyLeaderboard(entries)   // views animate the re-sort + ▲/▼ chips
            lastBoardEventAt = Date()
            // This push is fresher than any GET issued before it landed —
            // advance the token so an in-flight fetch can't overwrite it.
            leaderboardFetchSeq += 1
            // The board is derived from these ranks, so it moved too.
            scheduleEliminationRefresh()
            lastEventDescription = "leaderboardResorted(\(entries.count))"
        case .coverArtReady(let ostID, _, _):
            bumpCoverEpoch(ostID)
            scheduleLeaderboardRefresh()
            lastEventDescription = "coverArtReady(ost \(ostID))"
        }
        print("GATE ws event=\(lastEventDescription)")
    }
}
