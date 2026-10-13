import Foundation
import Observation
import Supabase
import SwiftUI
import CryptoKit

@MainActor
@Observable
final class CloudAccount {
    static let shared = CloudAccount()

    let client: SupabaseClient
    var email = ""
    private(set) var signedInEmail: String?
    private(set) var message: String?
    private(set) var isSendingLink = false
    private(set) var syncStatus = "Sign in on both devices to sync your data."
    private var lastHandledCallback: String?

    private init() {
        client = SupabaseClient(
            supabaseURL: SupabaseConfig.url,
            supabaseKey: SupabaseConfig.publishableKey,
            options: SupabaseClientOptions(auth: .init(flowType: .pkce))
        )
        Task { await refreshSession() }
    }

    var isSignedIn: Bool { signedInEmail != nil }

    func sendSignInLink() async {
        let address = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard address.contains("@") else {
            message = "Enter your Gmail address."
            return
        }
        isSendingLink = true
        message = nil
        defer { isSendingLink = false }
        do {
            try await client.auth.signInWithOTP(
                email: address,
                redirectTo: SupabaseConfig.authRedirect,
                shouldCreateUser: true
            )
            message = "Check your inbox and open the sign-in link on this device."
        } catch {
            let detail = error.localizedDescription
            if detail.localizedCaseInsensitiveContains("rate limit") {
                message = "Supabase's free email sender is rate-limited. Try again later, or configure custom SMTP for reliable sign-in links."
            } else {
                message = detail
            }
        }
    }

    func handle(_ url: URL) {
        guard url.scheme == SupabaseConfig.authRedirect.scheme else { return }
        guard lastHandledCallback != url.absoluteString else { return }
        lastHandledCallback = url.absoluteString
        message = "Completing sign-in…"
        Task {
            do {
                // Supabase's handle(_:) starts an unobserved Task. Await the
                // PKCE exchange here so the account UI and first sync see the
                // new session only after it has actually been persisted.
                let session = try await client.auth.session(from: url)
                signedInEmail = session.user.email
                message = nil
            } catch {
                signedInEmail = nil
                message = "Sign-in link failed: \(error.localizedDescription)"
            }
        }
    }

    func refreshSession() async {
        do {
            let session = try await client.auth.session
            signedInEmail = session.user.email
            message = nil
        } catch {
            signedInEmail = nil
        }
    }

    func reportSyncFailure(_ error: Error) {
        syncStatus = "Cloud sync will retry: \(error.localizedDescription)"
    }

    /// Keep image bytes in private Storage rather than bloating the frequently
    /// polled JSON snapshot. The Mac uploads changed covers; iPhone downloads
    /// and keeps a local copy so artwork remains available offline.
    func synchronizeCoverAssets(using backend: any OSTBackend, localSnapshot: Data, isMac: Bool) async throws -> Set<Int> {
        let session = try await client.auth.session
        let owner = session.user.id.uuidString.lowercased()
        if isMac {
            // The portable snapshot intentionally strips Mac file paths. Read
            // the local leaderboard model for its device-local artwork paths.
            for entry in try await backend.leaderboard() {
                let id = entry.ost.id
                guard let path = entry.ost.coverImagePath,
                      FileManager.default.fileExists(atPath: path),
                      let image = try? await backend.cover(ostID: id) else { continue }
                let digest = SHA256.hash(data: image).map { String(format: "%02x", $0) }.joined()
                let key = "ost.cloud.cover.upload.\(owner).\(id)"
                guard UserDefaults.standard.string(forKey: key) != digest else { continue }
                try await uploadCover(image, owner: owner, ostID: id, accessToken: session.accessToken)
                UserDefaults.standard.set(digest, forKey: key)
            }
            return []
        }

        #if os(iOS)
        let checkedKey = "ost.cloud.cover.lastCheck.\(owner)"
        let now = Date().timeIntervalSince1970
        guard now - UserDefaults.standard.double(forKey: checkedKey) >= 20 else { return [] }
        UserDefaults.standard.set(now, forKey: checkedKey)
        guard let local = backend as? IOSLocalBackend else { return [] }
        let objects = try await listCoverObjects(owner: owner, accessToken: session.accessToken)
        var changed: Set<Int> = []
        for object in objects {
            guard let name = object["name"] as? String,
                  let id = Self.coverID(from: name) else { continue }
            let updatedAt = (object["updated_at"] as? String) ?? (object["created_at"] as? String) ?? ""
            let versionKey = "ost.cloud.cover.download.\(owner).\(id)"
            let cachedVersion = UserDefaults.standard.string(forKey: versionKey)
            let localImageExists = (try? await local.cover(ostID: id)) != nil
            guard !localImageExists || cachedVersion != updatedAt else { continue }
            let image = try await downloadCover(owner: owner, name: name, accessToken: session.accessToken)
            try await local.cacheCover(ostID: id, data: image)
            UserDefaults.standard.set(updatedAt, forKey: versionKey)
            changed.insert(id)
        }
        return changed
        #else
        return []
        #endif
    }

    private static func coverID(from name: String) -> Int? {
        let filename = URL(fileURLWithPath: name).lastPathComponent
        let stem = filename.hasPrefix("cover_") ? String(filename.dropFirst(6)) : filename
        guard stem.hasSuffix(".jpg") else { return nil }
        return Int(stem.dropLast(4))
    }

    private func uploadCover(_ image: Data, owner: String, ostID: Int, accessToken: String) async throws {
        let path = "\(owner)/cover_\(ostID).jpg"
        var request = storageRequest("/storage/v1/object/osttracker-covers/\(path)", accessToken: accessToken)
        request.httpMethod = "POST"
        request.httpBody = image
        request.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
        request.setValue("true", forHTTPHeaderField: "x-upsert")
        let (data, response) = try await URLSession.shared.data(for: request)
        try check(response, data: data)
    }

    private func listCoverObjects(owner: String, accessToken: String) async throws -> [[String: Any]] {
        var request = storageRequest("/storage/v1/object/list/osttracker-covers", accessToken: accessToken)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "prefix": "\(owner)/",
            "limit": 1000,
            "offset": 0,
            "sortBy": ["column": "name", "order": "asc"],
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        try check(response, data: data)
        return try JSONSerialization.jsonObject(with: data) as? [[String: Any]] ?? []
    }

    private func downloadCover(owner: String, name: String, accessToken: String) async throws -> Data {
        let filename = URL(fileURLWithPath: name).lastPathComponent
        let request = storageRequest("/storage/v1/object/authenticated/osttracker-covers/\(owner)/\(filename)", accessToken: accessToken)
        let (data, response) = try await URLSession.shared.data(for: request)
        try check(response, data: data)
        return data
    }

    private func storageRequest(_ path: String, accessToken: String) -> URLRequest {
        var request = URLRequest(url: SupabaseConfig.url.appending(path: path))
        request.setValue(SupabaseConfig.publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        return request
    }

    func signOut() async {
        do {
            try await client.auth.signOut()
            signedInEmail = nil
            message = "Signed out."
        } catch {
            message = error.localizedDescription
        }
    }

    /// Synchronize the portable SQLite snapshot through the private row owned
    /// by the current Supabase user. The local database remains usable offline.
    func synchronize(localSnapshot: Data, isMac: Bool) async throws -> Data? {
        let session: Session
        do {
            session = try await client.auth.session
        } catch {
            syncStatus = "Sign in to enable cloud sync."
            return nil
        }

        let remote = try await fetchCloudState(accessToken: session.accessToken)
        let defaults = UserDefaults.standard
        let base = defaults.data(forKey: "ost.cloud.lastSnapshot")
        let baseRevision = defaults.object(forKey: "ost.cloud.revision") as? Int64

        guard let remote else {
            guard isMac else {
                syncStatus = "Open OSTTracker on your Mac while signed in to seed your existing data first."
                return nil
            }
            let revision = try await saveCloudState(localSnapshot, expectedRevision: nil, accessToken: session.accessToken)
            remember(localSnapshot, revision: revision)
            syncStatus = "Cloud copy created from this Mac."
            return nil
        }

        guard let base else {
            if containsPortableChanges(localSnapshot) {
                // A new/offline iPhone may have local edits before the Mac
                // creates its first cloud row. Merge them by stable IDs so a
                // first pull cannot erase those edits.
                let empty = try emptySnapshot()
                let merged = try mergeSnapshots(base: empty, local: localSnapshot, remote: remote.payload)
                let revision = try await saveCloudState(merged, expectedRevision: remote.revision, accessToken: session.accessToken)
                remember(merged, revision: revision)
                syncStatus = "Merged offline changes into the cloud."
                return merged
            }
            remember(remote.payload, revision: remote.revision)
            syncStatus = "Loaded cloud data."
            return remote.payload
        }

        let localChanged = !sameSnapshot(localSnapshot, base)
        let remoteChanged = !sameSnapshot(remote.payload, base)
        if !localChanged && !remoteChanged {
            syncStatus = "Synced • just now"
            return nil
        }
        if !localChanged {
            remember(remote.payload, revision: remote.revision)
            syncStatus = "Downloaded changes from your other device."
            return remote.payload
        }
        if !remoteChanged {
            let revision = try await saveCloudState(localSnapshot, expectedRevision: remote.revision, accessToken: session.accessToken)
            remember(localSnapshot, revision: revision)
            syncStatus = "Uploaded changes to the cloud."
            return nil
        }

        let merged = try mergeSnapshots(base: base, local: localSnapshot, remote: remote.payload)
        let revision = try await saveCloudState(merged, expectedRevision: remote.revision, accessToken: session.accessToken)
        remember(merged, revision: revision)
        syncStatus = "Merged changes from both devices."
        return merged
    }

    private struct CloudDocument {
        let revision: Int64
        let payload: Data
    }

    private func fetchCloudState(accessToken: String) async throws -> CloudDocument? {
        var components = URLComponents(url: SupabaseConfig.url.appending(path: "/rest/v1/osttracker_state"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "select", value: "revision,payload")]
        var request = URLRequest(url: components.url!)
        request.setValue(SupabaseConfig.publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        try check(response, data: data)
        let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] ?? []
        guard let row = rows.first,
              let revision = row["revision"] as? Int64,
              let payload = row["payload"] else { return nil }
        return CloudDocument(revision: revision, payload: try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]))
    }

    private func saveCloudState(_ payload: Data, expectedRevision: Int64?, accessToken: String) async throws -> Int64 {
        let snapshot = try JSONSerialization.jsonObject(with: payload)
        let body: [String: Any] = [
            "p_payload": snapshot,
            "p_expected_revision": expectedRevision as Any? ?? NSNull(),
        ]
        var request = URLRequest(url: SupabaseConfig.url.appending(path: "/rest/v1/rpc/save_osttracker_state"))
        request.httpMethod = "POST"
        request.setValue(SupabaseConfig.publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        try check(response, data: data)
        let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] ?? []
        guard let revision = rows.first?["revision"] as? Int64 else {
            throw NSError(domain: "OSTTrackerCloudSync", code: 1, userInfo: [NSLocalizedDescriptionKey: "Supabase did not return the saved revision."])
        }
        return revision
    }

    private func check(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let detail = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["message"] as? String
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw NSError(domain: "OSTTrackerCloudSync", code: code, userInfo: [NSLocalizedDescriptionKey: detail ?? "Cloud sync failed (HTTP \(code))."])
        }
    }

    private func remember(_ snapshot: Data, revision: Int64) {
        UserDefaults.standard.set(snapshot, forKey: "ost.cloud.lastSnapshot")
        UserDefaults.standard.set(revision, forKey: "ost.cloud.revision")
    }

    private func sameSnapshot(_ lhs: Data, _ rhs: Data) -> Bool {
        func canonical(_ data: Data) -> Data? {
            guard let value = try? JSONSerialization.jsonObject(with: data) else { return nil }
            return try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        }
        return canonical(lhs) == canonical(rhs)
    }

    private func containsPortableChanges(_ snapshot: Data) -> Bool {
        guard let value = try? JSONSerialization.jsonObject(with: snapshot) as? [String: Any],
              let tables = value["tables"] as? [String: [[String: Any]]] else { return false }
        return tables.values.contains { !$0.isEmpty }
    }

    private func emptySnapshot() throws -> Data {
        let names = ["people", "osts", "ratings", "notes", "ost_history", "app_settings", "retired_rounds"]
        return try JSONSerialization.data(withJSONObject: [
            "version": 1,
            "tables": Dictionary(uniqueKeysWithValues: names.map { ($0, [[String: Any]]()) }),
        ], options: [.sortedKeys])
    }

    /// Three-way, row-level merge. The common last-synced snapshot distinguishes
    /// a change from a device that simply has an older copy; CAS still guards
    /// the final write against another update arriving during the merge.
    private func mergeSnapshots(base: Data, local: Data, remote: Data) throws -> Data {
        let tableNames = ["people", "osts", "ratings", "notes", "ost_history", "app_settings", "retired_rounds"]
        func object(_ data: Data) throws -> [String: Any] {
            try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        }
        let b = try object(base), l = try object(local), r = try object(remote)
        let bt = b["tables"] as? [String: [[String: Any]]] ?? [:]
        let lt = l["tables"] as? [String: [[String: Any]]] ?? [:]
        let rt = r["tables"] as? [String: [[String: Any]]] ?? [:]
        let keys: [String: String] = ["people": "id", "osts": "id", "ratings": "id", "notes": "id", "ost_history": "id", "app_settings": "key", "retired_rounds": "id"]
        func indexed(_ rows: [[String: Any]], key: String) -> [String: [String: Any]] {
            Dictionary(rows.compactMap { row in row[key].map { (String(describing: $0), row) } }, uniquingKeysWith: { _, newest in newest })
        }
        func equal(_ lhs: [String: Any]?, _ rhs: [String: Any]?) -> Bool {
            switch (lhs, rhs) {
            case (nil, nil): return true
            case let (a?, b?): return NSDictionary(dictionary: a).isEqual(to: b)
            default: return false
            }
        }
        var tables: [String: [[String: Any]]] = [:]
        for table in tableNames {
            let key = keys[table]!
            let bm = indexed(bt[table] ?? [], key: key)
            let lm = indexed(lt[table] ?? [], key: key)
            let rm = indexed(rt[table] ?? [], key: key)
            var result: [[String: Any]] = []
            for rowKey in Set(bm.keys).union(lm.keys).union(rm.keys) {
                let baseRow = bm[rowKey], localRow = lm[rowKey], remoteRow = rm[rowKey]
                let localChanged = !equal(localRow, baseRow)
                let remoteChanged = !equal(remoteRow, baseRow)
                let chosen = localChanged && !remoteChanged ? localRow : remoteRow
                if let chosen { result.append(chosen) }
            }
            tables[table] = result.sorted { String(describing: $0[key] ?? "") < String(describing: $1[key] ?? "") }
        }
        return try JSONSerialization.data(withJSONObject: ["version": 1, "tables": tables], options: [.sortedKeys])
    }
}

struct CloudAccountSection: View {
    @Bindable private var account = CloudAccount.shared

    var body: some View {
        Section("Cloud account") {
            if let email = account.signedInEmail {
                LabeledContent("Signed in", value: email)
                Button("Sign out") { Task { await account.signOut() } }
            } else {
                #if os(iOS)
                TextField("Gmail address", text: $account.email)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.emailAddress)
                #else
                TextField("Gmail address", text: $account.email)
                    .autocorrectionDisabled()
                #endif
                Button(account.isSendingLink ? "Sending link…" : "Email me a sign-in link") {
                    Task { await account.sendSignInLink() }
                }
                .disabled(account.isSendingLink || account.email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if let message = account.message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Text(account.syncStatus)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Use the same Gmail address on each device. Supabase's free email sender only delivers to email addresses on your Supabase team.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
