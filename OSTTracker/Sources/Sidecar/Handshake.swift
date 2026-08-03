// Shared sidecar handshake parsing. Used by the macOS subprocess host and the
// iOS in-process host alike — the ready line is the same shape, only the
// transport differs (stdout pipe on macOS, a handshake file in the app
// container on iOS; see shared/CONTRACT.md).

import Foundation

nonisolated struct SidecarHandshake: Sendable {
    let port: Int
    let token: String
}

nonisolated enum SidecarError: Error {
    case exitedBeforeHandshake
    case handshakeTimeout
    case malformedHandshake(String)
}

nonisolated enum SidecarHandshakeParser {
    static func parse(_ line: String) throws -> SidecarHandshake {
        var port: Int?
        var token: String?
        for field in line.split(separator: " ") {
            if let value = field.dropPrefixIfPresent("port=") { port = Int(value) }
            if let value = field.dropPrefixIfPresent("token=") { token = String(value) }
        }
        guard let port, let token, !token.isEmpty else {
            throw SidecarError.malformedHandshake(line)
        }
        return SidecarHandshake(port: port, token: token)
    }
}

nonisolated extension Substring {
    func dropPrefixIfPresent(_ prefix: String) -> Substring? {
        hasPrefix(prefix) ? dropFirst(prefix.count) : nil
    }
}
