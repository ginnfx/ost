// Pairing details for the Mac-hosted backend. The address is a preference;
// the secret stays in the iOS Keychain instead of UserDefaults.

#if os(iOS)
import Foundation
import Security

enum LANConnection {
    static let addressKey = "ost.lan.address"
    private static let account = "mac-backend-token"

    static var token: String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Bundle.main.bundleIdentifier ?? "OSTTracker",
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(address: URL, token: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Bundle.main.bundleIdentifier ?? "OSTTracker",
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        var item = query
        item[kSecValueData as String] = Data(token.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else {
            throw ConnectionError.couldNotSave
        }
        UserDefaults.standard.set(address.absoluteString, forKey: addressKey)
    }

    static func forget() {
        UserDefaults.standard.removeObject(forKey: addressKey)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Bundle.main.bundleIdentifier ?? "OSTTracker",
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }

    static func parseAddress(_ input: String) throws -> URL {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = trimmed.contains("://") ? trimmed : "http://\(trimmed)"
        guard var components = URLComponents(string: text),
              components.scheme == "http",
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              components.path.isEmpty || components.path == "/" else {
            throw ConnectionError.invalidAddress
        }
        let octets = host.split(separator: ".").compactMap { UInt8($0) }
        let privateIPv4 = octets.count == 4 && (
            octets[0] == 10 ||
            (octets[0] == 172 && (16...31).contains(octets[1])) ||
            (octets[0] == 192 && octets[1] == 168) ||
            (octets[0] == 169 && octets[1] == 254)
        )
        let localName = host.hasSuffix(".local")
        guard privateIPv4 || localName else { throw ConnectionError.invalidAddress }
        components.port = components.port ?? 8765
        components.path = ""
        guard let url = components.url else { throw ConnectionError.invalidAddress }
        return url
    }

    static func parsePairingText(_ input: String) throws -> (address: URL, token: String) {
        guard let parts = URLComponents(string: input.trimmingCharacters(in: .whitespacesAndNewlines)),
              parts.scheme == "osttracker", parts.host == "pair", parts.path.isEmpty,
              let items = parts.queryItems,
              let rawAddress = items.first(where: { $0.name == "address" })?.value,
              let token = items.first(where: { $0.name == "token" })?.value,
              token.count == 64,
              token.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw ConnectionError.invalidPairingText
        }
        return (try parseAddress(rawAddress), token)
    }

    enum ConnectionError: LocalizedError {
        case invalidAddress, invalidPairingText, couldNotSave
        var errorDescription: String? {
            switch self {
            case .invalidAddress: "Enter your Mac's local address, such as My-Mac.local:8765 or 192.168.1.5:8765."
            case .invalidPairingText: "Copy the connection from OSTTracker Settings on your Mac, then try again."
            case .couldNotSave: "Couldn't save the pairing code in Keychain."
            }
        }
    }
}
#endif
