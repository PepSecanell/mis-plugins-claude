import Foundation
import Security

/// Stores one API key per AI provider in the Keychain. The items are synchronizable,
/// so iCloud Keychain carries them between your iPhone and Mac.
enum Keychain {
    private static let service = "com.keoly.agents"

    /// The Anthropic key keeps its original account name so keys saved by earlier builds still work.
    private static func account(for provider: Provider) -> String {
        provider == .anthropic ? "anthropic-api-key" : "\(provider.rawValue)-api-key"
    }

    static func key(for provider: Provider) -> String? {
        #if DEBUG
        // Test hook for command-line runs of the engine (no Keychain entitlement there).
        if let key = ProcessInfo.processInfo.environment["AGENTS_TEST_KEY_\(provider.rawValue.uppercased())"], !key.isEmpty {
            return key
        }
        #endif
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(for: provider),
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let key = String(data: data, encoding: .utf8), !key.isEmpty else { return nil }
        return key
    }

    static func setKey(_ newValue: String?, for provider: Provider) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(for: provider),
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
        ]
        SecItemDelete(base as CFDictionary)
        guard let newValue, !newValue.isEmpty else { return }
        var add = base
        add[kSecAttrSynchronizable as String] = true
        add[kSecValueData as String] = Data(newValue.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }
}
