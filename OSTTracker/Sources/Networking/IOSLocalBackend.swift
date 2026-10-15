#if os(iOS)
import Foundation
import UIKit

/// Small, durable on-device implementation of the app's data API. The JSON
/// snapshot format is shared with the Mac database and Supabase, which keeps
/// offline edits mergeable without making the phone depend on a Mac process.
@MainActor
final class IOSLocalBackend: OSTBackend {
    static let shared = IOSLocalBackend()
    private let fileURL: URL
    private let coversDirectory: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var document: [String: Any]
    private(set) var isFreshInstall: Bool
    private var pendingRetirement: (id: String, word: String, expiresAt: Date)?
    private var playbackState = PlaybackState(status: .idle, ostId: nil, streamUrl: nil, watchUrl: nil, position: 0)

    private init() {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "OSTTracker", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appending(path: "offline-state.json")
        coversDirectory = directory.appending(path: "Covers", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: coversDirectory, withIntermediateDirectories: true)
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        encoder.keyEncodingStrategy = .convertToSnakeCase
        if let data = try? Data(contentsOf: fileURL),
           let loaded = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           loaded["version"] as? Int == 1, loaded["tables"] is [String: Any] {
            document = loaded
            isFreshInstall = false
        } else {
            document = Self.emptyDocument
            isFreshInstall = true
        }
        rebaseCachedCoverPaths()
    }

    private static let tableNames = ["people", "osts", "ratings", "notes", "ost_history", "app_settings", "retired_rounds"]
    private static var emptyDocument: [String: Any] {
        ["version": 1, "tables": Dictionary(uniqueKeysWithValues: tableNames.map { ($0, [[String: Any]]()) })]
    }

    /// An app update can move its data container. The filenames are stable,
    /// while absolute paths saved by an older build are not.
    private func rebaseCachedCoverPaths() {
        var tables = document["tables"] as? [String: [[String: Any]]] ?? [:]
        var osts = tables["osts"] ?? []
        var changed = false
        for index in osts.indices {
            let id = Self.int(osts[index]["id"])
            let current = coversDirectory.appending(path: "cover_\(id).jpg")
            guard FileManager.default.fileExists(atPath: current.path) else { continue }
            if osts[index]["cover_image_path"] as? String != current.path {
                osts[index]["cover_image_path"] = current.path
                changed = true
            }
        }
        guard changed else { return }
        tables["osts"] = osts
        document["tables"] = tables
        try? persist()
    }

    func waitUntilHealthy(timeout: Duration = .seconds(10)) async throws {}

    func syncSnapshot() async throws -> Data {
        // File paths point into one device's sandbox; cloud snapshots never
        // contain them. The local file still retains its own cover paths.
        var portable = document
        var tables = portable["tables"] as? [String: [[String: Any]]] ?? [:]
        tables["osts"] = (tables["osts"] ?? []).map { row in
            var copy = row
            copy.removeValue(forKey: "cover_image_path")
            return copy
        }
        tables["retired_rounds"] = (tables["retired_rounds"] ?? []).map { row in
            var copy = row
            guard let text = row["payload"] as? String,
                  let data = text.data(using: .utf8),
                  var payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  var archivedOsts = payload["osts"] as? [[String: Any]] else { return copy }
            archivedOsts = archivedOsts.map { ost in
                var portableOst = ost
                portableOst.removeValue(forKey: "cover_image_path")
                return portableOst
            }
            payload["osts"] = archivedOsts
            if let portableData = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) {
                copy["payload"] = String(data: portableData, encoding: .utf8) ?? text
            }
            return copy
        }
        portable["tables"] = tables
        return try JSONSerialization.data(withJSONObject: portable, options: [.sortedKeys])
    }

    func applySyncSnapshot(_ snapshot: Data) async throws {
        let incoming = try JSONSerialization.jsonObject(with: snapshot) as? [String: Any] ?? [:]
        guard incoming["version"] as? Int == 1,
              var incomingTables = incoming["tables"] as? [String: [[String: Any]]],
              Self.tableNames.allSatisfy({ incomingTables[$0] != nil }) else {
            throw Self.error("Cloud data has an unsupported format.")
        }
        let localTables = rowsByTable
        var paths: [String: String] = Dictionary(uniqueKeysWithValues: (localTables["osts"] ?? []).compactMap { row in
            guard let id = row["id"], let path = row["cover_image_path"] as? String else { return nil }
            return (String(describing: id), path)
        })
        for archive in localTables["retired_rounds"] ?? [] {
            guard let text = archive["payload"] as? String,
                  let data = text.data(using: .utf8),
                  let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let osts = payload["osts"] as? [[String: Any]] else { continue }
            for ost in osts {
                guard let id = ost["id"], let path = ost["cover_image_path"] as? String else { continue }
                paths[String(describing: id)] = path
            }
        }
        incomingTables["osts"] = (incomingTables["osts"] ?? []).map { row in
            var copy = row
            if let id = row["id"], let path = paths[String(describing: id)] as? String {
                copy["cover_image_path"] = path
            }
            return copy
        }
        incomingTables["retired_rounds"] = (incomingTables["retired_rounds"] ?? []).map { row in
            var copy = row
            guard let text = row["payload"] as? String,
                  let data = text.data(using: .utf8),
                  var payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  var osts = payload["osts"] as? [[String: Any]] else { return copy }
            osts = osts.map { ost in
                var localOst = ost
                if let id = ost["id"], let path = paths[String(describing: id)] {
                    localOst["cover_image_path"] = path
                } else {
                    localOst.removeValue(forKey: "cover_image_path")
                }
                return localOst
            }
            payload["osts"] = osts
            if let localData = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) {
                copy["payload"] = String(data: localData, encoding: .utf8) ?? text
            }
            return copy
        }
        var replacement = incoming
        replacement["tables"] = incomingTables
        document = replacement
        try persist()
    }

    func snapshotHasPortableData(_ snapshot: Data) -> Bool {
        guard let value = try? JSONSerialization.jsonObject(with: snapshot) as? [String: Any],
              let tables = value["tables"] as? [String: [[String: Any]]] else { return false }
        return tables.values.contains { !$0.isEmpty }
    }

    private var rowsByTable: [String: [[String: Any]]] {
        document["tables"] as? [String: [[String: Any]]] ?? [:]
    }
    private func rows(_ table: String) -> [[String: Any]] { rowsByTable[table] ?? [] }
    private func setRows(_ values: [[String: Any]], for table: String) {
        var tables = rowsByTable
        tables[table] = values
        document["tables"] = tables
    }
    private func persist() throws {
        try persist(document)
    }
    private func persist(_ next: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: next, options: [.sortedKeys])
        try data.write(to: fileURL, options: .atomic)
        document = next
        isFreshInstall = false
    }
    private func replaceRows(_ values: [[String: Any]], for table: String, in target: inout [String: Any]) {
        var tables = target["tables"] as? [String: [[String: Any]]] ?? [:]
        tables[table] = values
        target["tables"] = tables
    }
    private func saveRows(_ values: [[String: Any]], for table: String) throws {
        setRows(values, for: table)
        try persist()
    }
    private func nextID(_ table: String) -> Int {
        let key = "ost.ios.local-id.\(table)"
        let start = UserDefaults.standard.object(forKey: key) as? Int ?? Int.random(in: 1_000_000_000...1_900_000_000)
        let next = start + 1
        UserDefaults.standard.set(next, forKey: key)
        return -next
    }
    private func now() -> String { ISO8601DateFormatter().string(from: Date()) }
    private func utcLabelDate() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd HH:mm 'UTC'"
        return formatter.string(from: Date())
    }
    nonisolated private static func error(_ message: String) -> NSError {
        NSError(domain: "OSTTrackerOffline", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
    private func decode<T: Decodable>(_ value: Any, as: T.Type) throws -> T {
        try decoder.decode(T.self, from: JSONSerialization.data(withJSONObject: value))
    }
    private func setting(_ key: String) -> String? {
        rows("app_settings").first { $0["key"] as? String == key }?["value"] as? String
    }
    private func setSetting(_ key: String, _ value: String) throws {
        var settings = rows("app_settings").filter { $0["key"] as? String != key }
        settings.append(["key": key, "value": value])
        try saveRows(settings, for: "app_settings")
    }

    func people() async throws -> [Person] {
        try decode(rows("people").sorted { ($0["name"] as? String ?? "").localizedCaseInsensitiveCompare($1["name"] as? String ?? "") == .orderedAscending }, as: [Person].self)
    }
    func addPerson(name: String) async throws -> Person {
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { throw Self.error("Person name cannot be empty.") }
        guard !rows("people").contains(where: { ($0["name"] as? String)?.caseInsensitiveCompare(cleaned) == .orderedSame }) else { throw Self.error("That person already exists.") }
        var values = rows("people"); values.append(["id": nextID("people"), "name": cleaned])
        try saveRows(values, for: "people")
        return Person(id: (values.last?["id"] as? Int) ?? -1, name: cleaned)
    }
    func deletePerson(id: Int) async throws {
        try saveRows(rows("people").filter { Self.int($0["id"]) != id }, for: "people")
        try saveRows(rows("ratings").filter { Self.int($0["rater_id"]) != id }, for: "ratings")
        try saveRows(rows("osts").map { row in var copy = row; if Self.int(row["submitter_id"]) == id { copy["submitter_id"] = NSNull() }; return copy }, for: "osts")
    }
    func addOst(_ new: NewOst) async throws -> Ost {
        let title = new.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw Self.error("OST title cannot be empty.") }
        guard !rows("ost_history").contains(where: { ($0["title"] as? String)?.localizedCaseInsensitiveCompare(title) == .orderedSame && ((($0["source"] as? String) ?? "").localizedCaseInsensitiveCompare(new.source ?? "") == .orderedSame) }) else { throw Self.error("That OST is already in history.") }
        let id = nextID("osts")
        let createdAt = now()
        let row: [String: Any] = ["id": id, "title": title, "source": new.source ?? NSNull() as Any, "submitter_id": new.submitterId ?? NSNull() as Any, "cover_image_path": NSNull(), "cover_accent_hex": NSNull(), "external_link": new.externalLink ?? NSNull() as Any, "playback_watch_url": NSNull(), "created_at": createdAt]
        var osts = rows("osts"); osts.append(row); try saveRows(osts, for: "osts")
        if let submitter = new.submitterId { try upsertRating(ostID: id, raterID: submitter, score: 10) }
        var history = rows("ost_history"); history.append(["id": nextID("ost_history"), "title": title, "source": new.source ?? NSNull() as Any, "batch_label": "Current Ranking", "sender": peopleByID[new.submitterId ?? Int.min]?["name"] ?? NSNull(), "created_at": createdAt]); try saveRows(history, for: "ost_history")
        return try decode(ostOutput(row), as: Ost.self)
    }
    func deleteOst(id: Int) async throws {
        try saveRows(rows("osts").filter { Self.int($0["id"]) != id }, for: "osts")
        try saveRows(rows("ratings").filter { Self.int($0["ost_id"]) != id }, for: "ratings")
    }
    func coverCandidates(ostID: Int) async throws -> [CoverCandidate] {
        guard let row = rows("osts").first(where: { Self.int($0["id"]) == ostID }) else {
            throw Self.error("OST not found.")
        }
        return await PhoneCatalogSearch.covers(title: row["title"] as? String ?? "",
                                                source: row["source"] as? String)
    }
    func setCover(ostID: Int, imageURL: String) async throws -> Ost {
        guard let url = URL(string: imageURL), url.scheme?.lowercased() == "https" else {
            throw Self.error("Use an HTTPS image URL.")
        }
        let (data, response) = try await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 12))
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              data.count <= 8 * 1_024 * 1_024,
              let image = UIImage(data: data),
              let jpeg = image.jpegData(compressionQuality: 0.88) else {
            throw Self.error("The cover image could not be downloaded.")
        }
        try cacheCover(ostID: ostID, data: jpeg)
        guard let row = rows("osts").first(where: { Self.int($0["id"]) == ostID }) else {
            throw Self.error("OST not found.")
        }
        return try decode(ostOutput(row), as: Ost.self)
    }
    func cover(ostID: Int) async throws -> Data {
        guard let path = rows("osts").first(where: { Self.int($0["id"]) == ostID })?["cover_image_path"] as? String,
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { throw Self.error("Cover art is not cached on this iPhone.") }
        return data
    }
    func cacheCover(ostID: Int, data: Data) throws {
        let destination = coversDirectory.appending(path: "cover_\(ostID).jpg")
        try data.write(to: destination, options: .atomic)
        var osts = rows("osts")
        guard let index = osts.firstIndex(where: { Self.int($0["id"]) == ostID }) else { return }
        osts[index]["cover_image_path"] = destination.path
        try saveRows(osts, for: "osts")
    }
    func ratings(raterID: Int? = nil) async throws -> [Rating] {
        let names = peopleByID
        let selected = rows("ratings").filter { raterID == nil || Self.int($0["rater_id"]) == raterID }
        let output = selected.compactMap { row -> [String: Any]? in
            let id = Self.int(row["rater_id"])
            guard let person = names[id] else { return nil }
            var copy = row; copy["rater_name"] = person["name"]
            return copy
        }
        return try decode(output, as: [Rating].self)
    }
    func putRating(_ upsert: RatingUpsert) async throws { try upsertRating(ostID: upsert.ostId, raterID: upsert.raterId, score: upsert.score) }
    func putRatingsBulk(_ upserts: [RatingUpsert]) async throws { for item in upserts { try upsertRating(ostID: item.ostId, raterID: item.raterId, score: item.score) }; try persist() }
    private func upsertRating(ostID: Int, raterID: Int, score: Double?) throws {
        guard rows("osts").contains(where: { Self.int($0["id"]) == ostID }), rows("people").contains(where: { Self.int($0["id"]) == raterID }) else { throw Self.error("Choose an existing OST and person.") }
        guard score == nil || (score! >= 0 && score! <= 10) else { throw Self.error("Score must be between 0 and 10.") }
        var values = rows("ratings").filter { !(Self.int($0["ost_id"]) == ostID && Self.int($0["rater_id"]) == raterID) }
        if let score { values.append(["id": nextID("ratings"), "ost_id": ostID, "rater_id": raterID, "score": (score * 100).rounded() / 100, "updated_at": now()]) }
        try saveRows(values, for: "ratings")
    }
    func revealState() async throws -> RevealState { RevealState(unlocked: setting("reveal_unlocked") == "true") }
    func setReveal(_ unlocked: Bool) async throws -> RevealState { try setSetting("reveal_unlocked", unlocked ? "true" : "false"); return RevealState(unlocked: unlocked) }
    func batches() async throws -> Batches { await makeBatches() }
    func randomizeBatches() async throws -> Batches {
        let entries = try await leaderboard()
        let count = min(8, max(1, Int(setting("batch_count") ?? "3") ?? 3))
        let old = currentArrangement
        let pins = pinnedIDs(entries)
        var grids = (0..<count).map { _ in [Int?]() }
        if let old {
            for (batchIndex, ids) in old.enumerated() where batchIndex < count {
                for (slot, id) in ids.enumerated() where pins.contains(id) {
                    while grids[batchIndex].count <= slot { grids[batchIndex].append(nil) }
                    grids[batchIndex][slot] = id
                }
            }
        } else {
            if let id = entries.first(where: { $0.ost.title.localizedCaseInsensitiveContains("At the Limit") && ($0.ost.source ?? "").localizedCaseInsensitiveContains("Peace Walker") })?.ost.id ?? entries.first(where: { $0.ost.title.localizedCaseInsensitiveContains("At the Limit") })?.ost.id {
                while grids[0].count < 1 { grids[0].append(nil) }; grids[0][0] = id
            }
            if let id = entries.first(where: { $0.ost.title.localizedCaseInsensitiveContains("Shining Star") && ($0.ost.source ?? "").localizedCaseInsensitiveContains("Marvel Rivals") })?.ost.id ?? entries.first(where: { $0.ost.title.localizedCaseInsensitiveContains("Shining Star") })?.ost.id {
                while grids[0].count < 3 { grids[0].append(nil) }; grids[0][2] = id
            }
        }
        var pool = entries.map(\.ost.id).filter { !pins.contains($0) }.shuffled()
        for batch in grids.indices {
            while grids[batch].count < entries.count / count { grids[batch].append(nil) }
        }
        let sizes = Array(repeating: entries.count / count, count: count).enumerated().map { idx, size in idx == count - 1 ? size + entries.count % count : size }
        for batch in grids.indices {
            if grids[batch].count > sizes[batch] { grids[batch] = Array(grids[batch].prefix(sizes[batch])) }
            while grids[batch].count < sizes[batch] { grids[batch].append(nil) }
        }
        for batch in grids.indices {
            for slot in grids[batch].indices where grids[batch][slot] == nil {
                if !pool.isEmpty { grids[batch][slot] = pool.removeFirst() }
            }
        }
        let assignment = grids.map { $0.compactMap { $0 } }
        try persistArrangement(assignment)
        return await makeBatches()
    }
    func setBatchCount(_ count: Int) async throws -> Batches {
        let newCount = min(8, max(1, count))
        try setSetting("batch_count", String(newCount))
        if let old = currentArrangement {
            let flat = old.flatMap { $0 }
            let base = flat.count / newCount
            var result: [[Int]] = []
            var offset = 0
            for index in 0..<newCount {
                let size = index == newCount - 1 ? flat.count - offset : base
                result.append(Array(flat.dropFirst(offset).prefix(size)))
                offset += size
            }
            try persistArrangement(result)
        }
        return await makeBatches()
    }
    func arrangeBatches(_ batches: [[Int]]) async throws -> Batches {
        let ids = (try await leaderboard()).map { $0.ost.id }
        let arranged = batches.flatMap { $0 }
        guard arranged.count == ids.count, Set(arranged) == Set(ids), batches.count <= 8 else { throw Self.error("Every OST must appear in exactly one batch.") }
        try persistArrangement(batches)
        return await makeBatches()
    }
    func setPin(ostID: Int, pinned: Bool) async throws -> Batches {
        let entries = try await leaderboard()
        guard entries.contains(where: { $0.ost.id == ostID }) else { throw Self.error("OST not found.") }
        var pins = pinnedIDs(entries)
        if pinned { pins.insert(ostID) } else { pins.remove(ostID) }
        try setSetting("batch_pins", String(data: JSONSerialization.data(withJSONObject: Array(pins).sorted()), encoding: .utf8) ?? "[]")
        return await makeBatches()
    }
    private var currentArrangement: [[Int]]? {
        guard let raw = setting("batch_assignment"), let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let batches = object["batches"] as? [[Int]] else { return nil }
        return batches
    }
    private func persistArrangement(_ batches: [[Int]]) throws {
        let payload: [String: Any] = ["generated_at": now(), "batches": batches]
        try setSetting("batch_assignment", String(data: JSONSerialization.data(withJSONObject: payload), encoding: .utf8) ?? "{}")
    }
    private func pinnedIDs(_ entries: [RankEntry]) -> Set<Int> {
        if let raw = setting("batch_pins"), let data = raw.data(using: .utf8),
           let ids = try? JSONSerialization.jsonObject(with: data) as? [Int] { return Set(ids) }
        let limit = Set(entries.compactMap { entry -> Int? in
            let title = entry.ost.title.lowercased(), source = (entry.ost.source ?? "").lowercased()
            if title.contains("at the limit") && source.contains("peace walker") { return entry.ost.id }
            if title.contains("shining star") && source.contains("marvel rivals") { return entry.ost.id }
            return nil
        })
        return limit
    }
    private func makeBatches() async -> Batches {
        let count = min(8, max(1, Int(setting("batch_count") ?? "3") ?? 3))
        let entries = (try? await leaderboard()) ?? []
        guard let arrangement = currentArrangement else { return Batches(generatedAt: nil, batches: []) }
        var groups = (0..<count).map { _ in [BatchSlot]() }
        let byID = Dictionary(uniqueKeysWithValues: entries.map { ($0.ost.id, $0.ost) })
        let pins = pinnedIDs(entries)
        for (index, ids) in arrangement.enumerated() where index < count {
            groups[index] = ids.enumerated().compactMap { slot, id in byID[id].map { BatchSlot(slot: slot + 1, ost: $0, pinned: pins.contains(id)) } }
        }
        let assigned = Set(arrangement.flatMap { $0 })
        for entry in entries where !assigned.contains(entry.ost.id) {
            let index = groups.indices.min(by: { groups[$0].count < groups[$1].count }) ?? 0
            groups[index].append(BatchSlot(slot: groups[index].count + 1, ost: entry.ost, pinned: pins.contains(entry.ost.id)))
        }
        let createdData = setting("batch_assignment")?.data(using: .utf8) ?? Data("{}".utf8)
        let created = (try? JSONSerialization.jsonObject(with: createdData)) as? [String: Any]
        let generatedAt = created?["generated_at"] as? String
        return Batches(generatedAt: generatedAt, batches: groups.enumerated().map { BatchGroup(index: $0.offset + 1, day: $0.offset + 1, slots: $0.element) })
    }
    func notes() async throws -> [Note] { try decode(rows("notes").sorted { ($0["created_at"] as? String ?? "") > ($1["created_at"] as? String ?? "") }, as: [Note].self) }
    func searchCatalog(_ query: String) async throws -> [CatalogTrack] {
        await PhoneCatalogSearch.search(query, includeMusicBrainz: true)
    }
    func addNote(_ new: NewNote) async throws -> Note {
        let row: [String: Any] = ["id": nextID("notes"), "title": new.title.trimmingCharacters(in: .whitespacesAndNewlines), "note": new.note, "source": new.source ?? NSNull() as Any, "artist": new.artist ?? NSNull() as Any, "external_link": new.externalLink ?? NSNull() as Any, "created_at": now()]
        var values = rows("notes"); values.append(row); try saveRows(values, for: "notes")
        return try decode(row, as: Note.self)
    }
    func updateNote(id: Int, _ patch: NotePatch) async throws -> Note {
        var values = rows("notes")
        guard let index = values.firstIndex(where: { Self.int($0["id"]) == id }) else { throw Self.error("Note not found.") }
        if let title = patch.title { values[index]["title"] = title }
        if let note = patch.note { values[index]["note"] = note }
        try saveRows(values, for: "notes"); return try decode(values[index], as: Note.self)
    }
    func deleteNote(id: Int) async throws { try saveRows(rows("notes").filter { Self.int($0["id"]) != id }, for: "notes") }
    func history() async throws -> [HistoryEntry] { try decode(rows("ost_history").sorted { ($0["created_at"] as? String ?? "") > ($1["created_at"] as? String ?? "") }, as: [HistoryEntry].self) }
    func renameHistoryLabel(from oldLabel: String, to newLabel: String) async throws {
        let old = oldLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        let new = newLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !old.isEmpty, !new.isEmpty, new.count <= 80,
              old.caseInsensitiveCompare("Current Ranking") != .orderedSame,
              new.caseInsensitiveCompare("Current Ranking") != .orderedSame else {
            throw Self.error("Enter a ranking name between 1 and 80 characters. Current Ranking is reserved.")
        }
        let history = rows("ost_history")
        let matchingIDs = Set(history.filter { $0["batch_label"] as? String == old }.map { Self.int($0["id"]) })
        guard !matchingIDs.isEmpty else { throw Self.error("That history ranking was not found.") }
        guard old == new || !history.contains(where: { ($0["batch_label"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(new) == .orderedSame }) else {
            throw Self.error("Another history ranking already has that name.")
        }
        let updatedHistory = history.map { row -> [String: Any] in
            var copy = row
            if row["batch_label"] as? String == old { copy["batch_label"] = new }
            return copy
        }
        var settings = rows("app_settings")
        if let index = settings.firstIndex(where: { $0["key"] as? String == "active_round_name" && $0["value"] as? String == old }) {
            settings[index]["value"] = new
        }
        var archives = rows("retired_rounds")
        for index in archives.indices where (archives[index]["restored_at"] is NSNull || archives[index]["restored_at"] == nil) {
            guard let text = archives[index]["payload"] as? String,
                  let data = text.data(using: .utf8),
                  var payload = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            let archiveIDs = Set((payload["changed_history"] as? [Int] ?? []) + (payload["created_history"] as? [Int] ?? []))
            guard !archiveIDs.isDisjoint(with: matchingIDs) else { continue }
            var savedSettings = payload["settings"] as? [[String: Any]] ?? []
            savedSettings.removeAll { $0["key"] as? String == "active_round_name" }
            savedSettings.append(["key": "active_round_name", "value": new])
            payload["settings"] = savedSettings
            archives[index]["name"] = new
            archives[index]["payload"] = String(data: try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]), encoding: .utf8) ?? text
        }
        var next = document
        replaceRows(updatedHistory, for: "ost_history", in: &next)
        replaceRows(settings, for: "app_settings", in: &next)
        replaceRows(archives, for: "retired_rounds", in: &next)
        try persist(next)
    }
    func roundStatus() async throws -> RoundStatus {
        let count = rows("osts").count
        let needsStart = count == 0 && setting("round_state") != "active"
        let history = rows("ost_history")
        let archives = try rows("retired_rounds").map { row -> [String: Any] in
            var value = row
            if (value["name"] as? String)?.isEmpty != false {
                let payload = (value["payload"] as? String).flatMap { $0.data(using: .utf8) }
                    .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
                let changed = payload["changed_history"] as? [Int] ?? []
                let created = payload["created_history"] as? [Int] ?? []
                let historyID = (changed + created).first
                let historyName = history.first { Self.int($0["id"]) == historyID }?["batch_label"] as? String
                value["name"] = historyName ?? "Retired \(value["retired_at"] as? String ?? "ranking")"
            }
            return value
        }
        return RoundStatus(activeOstCount: count,
                           currentName: needsStart ? nil : (setting("active_round_name") ?? "Current Ranking"),
                           needsStart: needsStart,
                           archives: try decode(archives, as: [RoundArchive].self))
    }
    func startRound(name: String) async throws -> RoundStatus {
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, cleaned.count <= 80, cleaned.caseInsensitiveCompare("Current Ranking") != .orderedSame else {
            throw Self.error("Choose a ranking name between 1 and 80 characters; Current Ranking is reserved.")
        }
        guard rows("osts").isEmpty else { throw Self.error("Retire the current rating before starting another one.") }
        guard !rows("ost_history").contains(where: { ($0["batch_label"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(cleaned) == .orderedSame }) else {
            throw Self.error("A history ranking already has that name.")
        }
        var next = document
        var settings = rows("app_settings").filter { !["active_round_name", "round_state"].contains($0["key"] as? String ?? "") }
        settings.append(["key": "active_round_name", "value": cleaned])
        settings.append(["key": "round_state", "value": "active"])
        replaceRows(settings, for: "app_settings", in: &next)
        try persist(next)
        return try await roundStatus()
    }
    func retireChallenge() async throws -> RetireChallenge {
        guard !rows("osts").isEmpty else { throw Self.error("There are no active OSTs to retire.") }
        let words = ["HARBOR", "LANTERN", "ORBIT", "MEADOW", "PAPER", "RIVER", "SUNSET", "WILLOW"]
        let challenge = RetireChallenge(challengeId: UUID().uuidString, word: words.randomElement()!)
        pendingRetirement = (challenge.challengeId, challenge.word, Date().addingTimeInterval(300))
        return challenge
    }
    func retireRound(challengeId: String, word: String) async throws {
        guard let pending = pendingRetirement,
              pending.id == challengeId,
              pending.expiresAt > Date(),
              pending.word == word else {
            pendingRetirement = nil
            throw Self.error("Confirmation word was incorrect or expired.")
        }
        pendingRetirement = nil

        let activeOsts = rows("osts").sorted { Self.int($0["id"]) < Self.int($1["id"]) }
        guard !activeOsts.isEmpty else { throw Self.error("There are no active OSTs to retire.") }
        let activeRatings = rows("ratings").sorted { Self.int($0["id"]) < Self.int($1["id"]) }
        let roundKeys: Set<String> = ["reveal_unlocked", "batch_assignment", "batch_pins", "batch_count", "active_round_name", "round_state"]
        let savedSettings = rows("app_settings").filter { roundKeys.contains($0["key"] as? String ?? "") }
        let activeLabel = setting("active_round_name") ?? "Current Ranking"
        let currentHistory = rows("ost_history").filter { $0["batch_label"] as? String == activeLabel }
        let label = activeLabel.caseInsensitiveCompare("Current Ranking") == .orderedSame ? "Retired \(utcLabelDate())" : activeLabel
        var history = rows("ost_history")
        var changedHistory: [Int] = []
        var createdHistory: [Int] = []
        var used = Set<Int>()
        for ost in activeOsts {
            let title = ((ost["title"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let source = ((ost["source"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if let match = currentHistory.first(where: {
                let id = Self.int($0["id"])
                return !used.contains(id)
                    && (($0["title"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == title)
                    && (($0["source"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == source)
            }) {
                let id = Self.int(match["id"])
                used.insert(id)
                changedHistory.append(id)
                history = history.map { row in
                    var copy = row
                    if Self.int(row["id"]) == id { copy["batch_label"] = label }
                    return copy
                }
            } else {
                let submitter = Self.int(ost["submitter_id"])
                let sender = peopleByID[submitter]?["name"] as? String
                let id = nextID("ost_history")
                history.append(["id": id, "title": ost["title"] ?? "", "source": ost["source"] ?? NSNull(), "batch_label": label, "sender": sender ?? NSNull(), "created_at": now()])
                createdHistory.append(id)
            }
        }

        let payload: [String: Any] = ["osts": activeOsts, "ratings": activeRatings, "settings": savedSettings,
                                      "changed_history": changedHistory, "created_history": createdHistory]
        let payloadData = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        let archiveID = nextID("retired_rounds")
        var archives = rows("retired_rounds")
        archives.append(["id": archiveID, "retired_at": now(), "ost_count": activeOsts.count,
                         "payload": String(data: payloadData, encoding: .utf8) ?? "{}", "name": label,
                         "restored_at": NSNull()])

        var next = document
        replaceRows([], for: "osts", in: &next)
        replaceRows([], for: "ratings", in: &next)
        replaceRows(history, for: "ost_history", in: &next)
        replaceRows(archives, for: "retired_rounds", in: &next)
        let settings = rows("app_settings").filter { !roundKeys.contains($0["key"] as? String ?? "") }
        replaceRows(settings + [["key": "round_state", "value": "retired"]], for: "app_settings", in: &next)
        try persist(next)
    }
    func restoreRound(id: Int) async throws {
        guard rows("osts").isEmpty else { throw Self.error("Retire the current round before restoring an older one.") }
        var archives = rows("retired_rounds")
        guard let archiveIndex = archives.firstIndex(where: { Self.int($0["id"]) == id }) else { throw Self.error("That retired round was not found.") }
        guard archives[archiveIndex]["restored_at"] is NSNull || archives[archiveIndex]["restored_at"] == nil else {
            throw Self.error("That round has already been restored.")
        }
        guard let text = archives[archiveIndex]["payload"] as? String,
              let data = text.data(using: .utf8),
              let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let osts = payload["osts"] as? [[String: Any]],
              let ratings = payload["ratings"] as? [[String: Any]],
              let savedSettings = payload["settings"] as? [[String: Any]] else {
            throw Self.error("That archive is damaged and cannot be restored.")
        }
        let restoreName = savedSettings.first { $0["key"] as? String == "active_round_name" }?["value"] as? String ?? "Current Ranking"
        let roundKeys: Set<String> = ["reveal_unlocked", "batch_assignment", "batch_pins", "batch_count", "active_round_name", "round_state"]
        var settings = rows("app_settings").filter { !roundKeys.contains($0["key"] as? String ?? "") }
        settings.append(contentsOf: savedSettings)
        settings.removeAll { $0["key"] as? String == "round_state" }
        settings.append(["key": "round_state", "value": "active"])
        var history = rows("ost_history")
        let historyIDs = Set((payload["changed_history"] as? [Int] ?? []) + (payload["created_history"] as? [Int] ?? []))
        history = history.map { row in
            var copy = row
            if historyIDs.contains(Self.int(row["id"])) { copy["batch_label"] = restoreName }
            return copy
        }
        archives[archiveIndex]["restored_at"] = now()
        var next = document
        replaceRows(osts, for: "osts", in: &next)
        replaceRows(ratings, for: "ratings", in: &next)
        replaceRows(settings, for: "app_settings", in: &next)
        replaceRows(history, for: "ost_history", in: &next)
        replaceRows(archives, for: "retired_rounds", in: &next)
        try persist(next)
    }
    func leaderboard() async throws -> [RankEntry] {
        let people = peopleByID
        let ratingsByOst = Dictionary(grouping: rows("ratings"), by: { Self.int($0["ost_id"]) })
        var entries: [RankEntry] = try rows("osts").map { row in
            let ost = try decode(ostOutput(row), as: Ost.self)
            let ratings = ratingsByOst[ost.id] ?? []
            let scores = ratings.compactMap { $0["score"] as? Double }
            let average = scores.isEmpty ? nil : scores.reduce(0, +) / Double(scores.count)
            let _ = people
            return RankEntry(ost: ost, ratingCount: scores.count, average: average, minimum: scores.min(), maximum: scores.max(), stddev: scores.isEmpty ? nil : (scores.map { pow($0 - (average ?? 0), 2) }.reduce(0, +) / Double(scores.count)).squareRoot(), rank: nil)
        }
        let ranked = entries.filter { $0.average != nil }.sorted { lhs, rhs in
            if lhs.average != rhs.average { return (lhs.average ?? 0) > (rhs.average ?? 0) }
            let own: (RankEntry) -> Double = { entry in
                guard let id = entry.ost.submitterId else { return -.infinity }
                let ownScores = entries.filter { $0.ost.submitterId == id }.compactMap(\.average)
                return ownScores.isEmpty ? -.infinity : ownScores.reduce(0, +) / Double(ownScores.count)
            }
            if own(lhs) != own(rhs) { return own(lhs) > own(rhs) }
            return lhs.ost.title.localizedCaseInsensitiveCompare(rhs.ost.title) == .orderedAscending
        }
        let ranks = Dictionary(uniqueKeysWithValues: ranked.enumerated().map { ($0.element.ost.id, $0.offset + 1) })
        entries = entries.map { entry in RankEntry(ost: entry.ost, ratingCount: entry.ratingCount, average: entry.average, minimum: entry.minimum, maximum: entry.maximum, stddev: entry.stddev, rank: ranks[entry.ost.id]) }
        return entries
    }
    private func ostOutput(_ row: [String: Any]) -> [String: Any] {
        var copy = row
        copy["submitter_name"] = peopleByID[Self.int(row["submitter_id"])]?["name"] ?? NSNull()
        return copy
    }
    private var peopleByID: [Int: [String: Any]] { Dictionary(uniqueKeysWithValues: rows("people").compactMap { row in guard let id = row["id"] as? Int else { return nil }; return (id, row) }) }
    nonisolated private static func int(_ value: Any?) -> Int { (value as? NSNumber)?.intValue ?? (value as? Int ?? Int.min) }
    func elimination() async throws -> EliminationBoard {
        let parsedThreshold = Int(setting("elimination_threshold") ?? "5") ?? 5
        let threshold = min(20, max(1, parsedThreshold))
        return EliminationBuilder.build(try await leaderboard(), threshold: threshold)
    }
    func setEliminationThreshold(_ threshold: Int) async throws -> EliminationBoard { try setSetting("elimination_threshold", String(min(20, max(1, threshold)))); return try await elimination() }
    func startResolve(ostID: Int) async throws {
        guard let row = rows("osts").first(where: { Self.int($0["id"]) == ostID }) else {
            throw Self.error("OST not found.")
        }
        let key = IOSAudioCache.key(for: row)
        if await IOSAudioCache.shared.cachedURL(for: key) != nil { return }
        let result = try await resolve(row)
        try rememberPlaybackWatchURL(result.watchURL, for: ostID)
        Task { await IOSAudioCache.shared.store(result.streamURL, for: key) }
    }
    func play(ostID: Int) async throws -> PlaybackState {
        guard let row = rows("osts").first(where: { Self.int($0["id"]) == ostID }) else {
            throw Self.error("OST not found.")
        }
        let key = IOSAudioCache.key(for: row)
        if let cached = await IOSAudioCache.shared.cachedURL(for: key) {
            playbackState = PlaybackState(status: .playing, ostId: ostID,
                                          streamUrl: cached.absoluteString,
                                          watchUrl: row["playback_watch_url"] as? String,
                                          position: 0)
            return playbackState
        }
        let external = row["external_link"] as? String
        if let external, let url = URL(string: external), Self.isDirectAudioURL(url) {
            playbackState = PlaybackState(status: .playing, ostId: ostID, streamUrl: external, watchUrl: external, position: 0)
            Task { await IOSAudioCache.shared.store(url, for: key) }
            return playbackState
        }
        let resolved = try await resolve(row)
        try rememberPlaybackWatchURL(resolved.watchURL, for: ostID)
        Task { await IOSAudioCache.shared.store(resolved.streamURL, for: key) }
        playbackState = PlaybackState(
            status: .playing,
            ostId: ostID,
            streamUrl: resolved.streamURL.absoluteString,
            watchUrl: resolved.watchURL.absoluteString,
            position: 0
        )
        return playbackState
    }

    private func resolve(_ row: [String: Any]) async throws -> IOSYouTubeResolver.Result {
        try await IOSYouTubeResolver.resolve(
            title: row["title"] as? String ?? "",
            source: row["source"] as? String,
            externalLink: row["external_link"] as? String,
            cachedWatchURL: row["playback_watch_url"] as? String
        )
    }

    private func rememberPlaybackWatchURL(_ url: URL, for ostID: Int) throws {
        var osts = rows("osts")
        guard let index = osts.firstIndex(where: { Self.int($0["id"]) == ostID }) else { return }
        osts[index]["playback_watch_url"] = url.absoluteString
        try saveRows(osts, for: "osts")
    }

    func invalidatePlaybackCache(ostID: Int) async {
        guard let row = rows("osts").first(where: { Self.int($0["id"]) == ostID }) else { return }
        await IOSAudioCache.shared.remove(for: IOSAudioCache.key(for: row))
        if let value = playbackState.watchUrl ?? row["playback_watch_url"] as? String,
           let url = URL(string: value), IOSYouTubeResolver.isYouTubeURL(url) {
            IOSYouTubeResolver.invalidateStream(for: url)
        }
    }

    private static func isDirectAudioURL(_ url: URL) -> Bool {
        ["mp3", "m4a", "aac", "wav", "mp4"].contains(url.pathExtension.lowercased())
    }
    func pause() async throws -> PlaybackState { playbackState = PlaybackState(status: .paused, ostId: playbackState.ostId, streamUrl: playbackState.streamUrl, watchUrl: playbackState.watchUrl, position: playbackState.position); return playbackState }
    func seek(position: Double) async throws -> PlaybackState { playbackState = PlaybackState(status: playbackState.status, ostId: playbackState.ostId, streamUrl: playbackState.streamUrl, watchUrl: playbackState.watchUrl, position: position); return playbackState }
    func stop() async throws -> PlaybackState { playbackState = PlaybackState(status: .stopped, ostId: nil, streamUrl: nil, watchUrl: nil, position: 0); return playbackState }
    func events() async -> AsyncThrowingStream<WSEvent, Error> { AsyncThrowingStream { $0.finish() } }
}
#endif
