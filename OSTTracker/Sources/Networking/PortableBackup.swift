import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// Versioned wrapper keeps exported files recognizable and safe to validate
/// before handing their payload to the backend's existing snapshot importer.
struct PortableBackup: Codable {
    let format: String
    let version: Int
    let createdAt: Date
    let snapshot: Data

    init(snapshot: Data) {
        format = "osttracker-backup"
        version = 1
        createdAt = .now
        self.snapshot = snapshot
    }

    func validatedSnapshot() throws -> Data {
        guard format == "osttracker-backup", version == 1 else {
            throw BackupFileError.unsupported
        }
        return snapshot
    }
}

enum BackupFileError: LocalizedError {
    case unsupported
    var errorDescription: String? { "This isn’t a supported OST Tracker backup." }
}

struct OSTBackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw BackupFileError.unsupported
        }
        self.data = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
