import Foundation
import Security

/// Zugang (Server-URL, API-Schlüssel, Nutzer-ID) im Schlüsselbund
enum Keychain {
    private static let service = "org.homeroll.homecast"
    private static let accountKey = "server-account"

    static func save(_ account: ServerAccount) {
        guard let data = try? JSONEncoder().encode(account) else { return }
        delete()
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: accountKey, kSecValueData as String: data,
                                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock]
        SecItemAdd(q as CFDictionary, nil)
    }

    static func load() -> ServerAccount? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: accountKey, kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return try? JSONDecoder().decode(ServerAccount.self, from: data)
    }

    static func delete() {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: accountKey]
        SecItemDelete(q as CFDictionary)
    }
}
