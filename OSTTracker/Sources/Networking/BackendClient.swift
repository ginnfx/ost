// The app's single networking actor. Every byte to or from the sidecar goes
// through here; the rest of the app never sees URLSession.

import Foundation

nonisolated enum BackendError: LocalizedError {
    case badStatus(Int, path: String)
    case healthTimeout

    var errorDescription: String? {
        switch self {
        case .badStatus(401, _): "The pairing code is incorrect."
        case .badStatus(let status, let path): "The Mac returned HTTP \(status) for \(path)."
        case .healthTimeout: "The Mac did not respond. Check its address and local network access."
        }
    }
}

nonisolated struct RoundArchive: Codable, Sendable, Identifiable {
    let id: Int
    let retiredAt: String
    let ostCount: Int
    let restoredAt: String?
    let name: String
}

nonisolated struct HistoryLabelRename: Encodable, Sendable {
    let oldLabel: String
    let newLabel: String
}

nonisolated struct RoundStatus: Codable, Sendable {
    let activeOstCount: Int
    let currentName: String?
    let needsStart: Bool
    let archives: [RoundArchive]
}

nonisolated struct StartRound: Encodable, Sendable {
    let name: String
}

nonisolated struct RetireChallenge: Codable, Sendable, Identifiable {
    let challengeId: String
    let word: String
    var id: String { challengeId }
}

nonisolated struct RetireConfirmation: Encodable, Sendable {
    let challengeId: String
    let word: String
}

actor BackendClient: OSTBackend {
    private let baseURL: URL
    private let wsURL: URL
    private let token: String
    private let session: URLSession
    private let wsSession: URLSession
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    init(port: Int, token: String) {
        self.init(baseURL: URL(string: "http://127.0.0.1:\(port)")!, token: token)
    }

    init(baseURL: URL, token: String) {
        self.baseURL = baseURL
        var ws = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        ws.scheme = baseURL.scheme == "https" ? "wss" : "ws"
        ws.path = "/ws"
        self.wsURL = ws.url!
        self.token = token
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        self.session = URLSession(configuration: config)
        // /ws gets its own session: timeoutIntervalForRequest ticks between
        // MESSAGES on a websocket task, so the REST session's 30s would tear
        // down a quiet socket every ~30s into a reconnect/resync churn loop.
        let wsConfig = URLSessionConfiguration.ephemeral
        wsConfig.timeoutIntervalForRequest = 86_400
        self.wsSession = URLSession(configuration: wsConfig)
        self.decoder = JSONDecoder()
        self.decoder.keyDecodingStrategy = .convertFromSnakeCase
        self.encoder = JSONEncoder()
        self.encoder.keyEncodingStrategy = .convertToSnakeCase
    }

    // MARK: - Plumbing

    private func request(_ method: String, _ path: String, body: Data? = nil) -> URLRequest {
        var req = URLRequest(url: baseURL.appending(path: path))
        req.httpMethod = method
        req.setValue(token, forHTTPHeaderField: "X-OST-Token")
        if let body {
            req.httpBody = body
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return req
    }

    private func run(_ req: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(status) else {
            throw BackendError.badStatus(status, path: req.url?.path() ?? "?")
        }
        return data
    }

    private func get<T: Decodable>(_ path: String) async throws -> T {
        try decoder.decode(T.self, from: try await run(request("GET", path)))
    }

    private func send<T: Decodable>(
        _ method: String, _ path: String, body: (some Encodable)? = Optional<Int>.none
    ) async throws -> T {
        let data = try body.map { try encoder.encode($0) }
        return try decoder.decode(T.self, from: try await run(request(method, path, body: data)))
    }

    // MARK: - Health

    func checkHealth() async throws {
        _ = try await run(request("GET", "/health"))
    }

    func syncSnapshot() async throws -> Data {
        try await run(request("GET", "/sync/state"))
    }

    func applySyncSnapshot(_ snapshot: Data) async throws {
        _ = try await run(request("PUT", "/sync/state", body: snapshot))
    }

    func waitUntilHealthy(timeout: Duration = .seconds(10)) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                while true {
                    if (try? await self.run(self.request("GET", "/health"))) != nil { return }
                    try await Task.sleep(for: .milliseconds(100))
                }
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw BackendError.healthTimeout
            }
            try await group.next()
            group.cancelAll()
        }
    }

    // MARK: - REST (1:1 with the contract)

    func people() async throws -> [Person] { try await get("/people") }

    func addPerson(name: String) async throws -> Person {
        try await send("POST", "/people", body: NewPerson(name: name))
    }

    func deletePerson(id: Int) async throws {
        _ = try await run(request("DELETE", "/people/\(id)"))
    }

    func osts() async throws -> [Ost] { try await get("/osts") }

    func addOst(_ new: NewOst) async throws -> Ost {
        try await send("POST", "/osts", body: new)
    }

    func deleteOst(id: Int) async throws {
        _ = try await run(request("DELETE", "/osts/\(id)"))
    }

    func coverCandidates(ostID: Int) async throws -> [CoverCandidate] {
        try await get("/osts/\(ostID)/cover/candidates")
    }

    func setCover(ostID: Int, imageURL: String) async throws -> Ost {
        try await send("POST", "/osts/\(ostID)/cover", body: CoverSet(imageUrl: imageURL))
    }

    func cover(ostID: Int) async throws -> Data {
        try await run(request("GET", "/covers/\(ostID)"))
    }

    func ratings(raterID: Int? = nil) async throws -> [Rating] {
        if let raterID {
            return try await get("/ratings?rater_id=\(raterID)")
        }
        return try await get("/ratings")
    }

    func putRating(_ upsert: RatingUpsert) async throws {
        _ = try await run(request("PUT", "/ratings", body: try encoder.encode(upsert)))
    }

    func putRatingsBulk(_ upserts: [RatingUpsert]) async throws {
        _ = try await run(request("POST", "/ratings/bulk", body: try encoder.encode(RatingUpsertList(ratings: upserts))))
    }

    func revealState() async throws -> RevealState {
        try await get("/settings/reveal")
    }

    func setReveal(_ unlocked: Bool) async throws -> RevealState {
        try await send("PUT", "/settings/reveal", body: RevealState(unlocked: unlocked))
    }

    func batches() async throws -> Batches { try await get("/batches") }

    func randomizeBatches() async throws -> Batches {
        try await send("POST", "/batches/randomize")
    }

    func setBatchCount(_ count: Int) async throws -> Batches {
        try await send("PUT", "/batches/count", body: BatchCount(count: count))
    }

    func arrangeBatches(_ batches: [[Int]]) async throws -> Batches {
        try await send("POST", "/batches/arrange", body: BatchArrangement(batches: batches))
    }

    func setPin(ostID: Int, pinned: Bool) async throws -> Batches {
        try await send("POST", "/batches/pin", body: BatchPin(ostId: ostID, pinned: pinned))
    }

    func notes() async throws -> [Note] { try await get("/notes") }

    func searchCatalog(_ query: String) async throws -> [CatalogTrack] {
        var components = URLComponents(url: baseURL.appending(path: "/notes/catalog-search"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "q", value: query)]
        var req = URLRequest(url: components.url!)
        req.setValue(token, forHTTPHeaderField: "X-OST-Token")
        return try decoder.decode([CatalogTrack].self, from: try await run(req))
    }

    func addNote(_ new: NewNote) async throws -> Note {
        try await send("POST", "/notes", body: new)
    }

    func updateNote(id: Int, _ patch: NotePatch) async throws -> Note {
        try await send("PATCH", "/notes/\(id)", body: patch)
    }

    func deleteNote(id: Int) async throws {
        _ = try await run(request("DELETE", "/notes/\(id)"))
    }

    func history() async throws -> [HistoryEntry] { try await get("/history") }

    func renameHistoryLabel(from oldLabel: String, to newLabel: String) async throws {
        _ = try await run(request("PATCH", "/history/label", body: try encoder.encode(
            HistoryLabelRename(oldLabel: oldLabel, newLabel: newLabel)
        )))
    }

    func roundStatus() async throws -> RoundStatus { try await get("/rounds") }

    func startRound(name: String) async throws -> RoundStatus {
        try await send("POST", "/rounds/start", body: StartRound(name: name))
    }

    func retireChallenge() async throws -> RetireChallenge { try await get("/rounds/retire-challenge") }

    func retireRound(challengeId: String, word: String) async throws {
        let _: RoundArchive = try await send("POST", "/rounds/retire", body: RetireConfirmation(challengeId: challengeId, word: word))
    }

    func restoreRound(id: Int) async throws {
        _ = try await run(request("POST", "/rounds/\(id)/restore"))
    }

    // GET /history/matches (?title=&source=) has no Swift caller — the
    // Add-OST pre-submit hint matches locally against store.history (see
    // AddOstRules.historyConflict). The endpoint stays server-side for
    // debugging/parity with the Python match rule.

    func leaderboard() async throws -> [RankEntry] { try await get("/leaderboard") }

    func elimination() async throws -> EliminationBoard { try await get("/elimination") }

    func setEliminationThreshold(_ threshold: Int) async throws -> EliminationBoard {
        try await send(
            "PUT", "/elimination/threshold", body: EliminationThreshold(threshold: threshold)
        )
    }

    func startResolve(ostID: Int) async throws {
        _ = try await run(request("POST", "/osts/\(ostID)/resolve"))
    }

    func play(ostID: Int) async throws -> PlaybackState {
        var state: PlaybackState = try await send("POST", "/player/play", body: ["ost_id": ostID])
        // The Mac backend's range relay is local to the host. Its default
        // loopback URL would resolve to the iPhone itself, so route the relay
        // through the same paired LAN address used for API requests.
        #if os(iOS)
        if let stream = state.streamUrl, var parts = URLComponents(string: stream),
           parts.host == "127.0.0.1" || parts.host == "localhost" {
            parts.host = baseURL.host
            parts.port = baseURL.port
            if let routed = parts.url?.absoluteString {
                state = PlaybackState(status: state.status, ostId: state.ostId, streamUrl: routed, watchUrl: state.watchUrl, position: state.position)
            }
        }
        #endif
        return state
    }

    func pause() async throws -> PlaybackState { try await send("POST", "/player/pause") }

    func seek(position: Double) async throws -> PlaybackState {
        try await send("POST", "/player/seek", body: ["position": position])
    }

    func stop() async throws -> PlaybackState { try await send("POST", "/player/stop") }

    // MARK: - WebSocket

    /// Connect to /ws and stream decoded envelope events until the socket
    /// drops. Reconnection policy belongs to the caller (the store).
    func events() async -> AsyncThrowingStream<WSEvent, Error> {
        var req = URLRequest(url: wsURL)
        req.setValue(token, forHTTPHeaderField: "X-OST-Token")
        let task = wsSession.webSocketTask(with: req)
        task.resume()
        let decoder = self.decoder
        return AsyncThrowingStream { continuation in
            let pump = Task {
                do {
                    while !Task.isCancelled {
                        let message = try await task.receive()
                        let data: Data
                        switch message {
                        case .string(let text): data = Data(text.utf8)
                        case .data(let raw): data = raw
                        @unknown default: continue
                        }
                        // One undecodable event (a type this build doesn't
                        // know, payload-shape drift) must not tear down the
                        // socket — skip it and keep pumping. Transport errors
                        // still exit the loop and trigger the reconnect path.
                        do {
                            continuation.yield(try decoder.decode(WSEvent.self, from: data))
                        } catch {
                            print("GATE ws skipped undecodable event: \(error)")
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                pump.cancel()
                task.cancel(with: .goingAway, reason: nil)
            }
        }
    }
}
