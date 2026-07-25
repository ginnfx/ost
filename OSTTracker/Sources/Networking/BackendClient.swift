// The app's single networking actor. Every byte to or from the sidecar goes
// through here; the rest of the app never sees URLSession.

import Foundation

nonisolated enum BackendError: Error {
    case badStatus(Int, path: String)
    case healthTimeout
}

actor BackendClient {
    private let baseURL: URL
    private let wsURL: URL
    private let token: String
    private let session: URLSession
    private let wsSession: URLSession
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    init(port: Int, token: String) {
        self.baseURL = URL(string: "http://127.0.0.1:\(port)")!
        self.wsURL = URL(string: "ws://127.0.0.1:\(port)/ws")!
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

    func waitUntilHealthy(timeout: Duration = .seconds(10)) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if let _ = try? await run(request("GET", "/health")) { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw BackendError.healthTimeout
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

    func ratings() async throws -> [Rating] { try await get("/ratings") }

    func putRating(_ upsert: RatingUpsert) async throws {
        _ = try await run(request("PUT", "/ratings", body: try encoder.encode(upsert)))
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
        try await send("POST", "/player/play", body: ["ost_id": ostID])
    }

    func pause() async throws -> PlaybackState { try await send("POST", "/player/pause") }

    func seek(position: Double) async throws -> PlaybackState {
        try await send("POST", "/player/seek", body: ["position": position])
    }

    func stop() async throws -> PlaybackState { try await send("POST", "/player/stop") }

    // MARK: - WebSocket

    /// Connect to /ws and stream decoded envelope events until the socket
    /// drops. Reconnection policy belongs to the caller (the store).
    func events() -> AsyncThrowingStream<WSEvent, Error> {
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
                        } catch let error as DecodingError {
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
