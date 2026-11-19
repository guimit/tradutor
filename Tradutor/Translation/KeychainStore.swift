import Foundation
import Security

/// Guarda segredos (chaves de API) no Keychain do utilizador, como "palavra-passe genérica".
enum KeychainStore {
    private static let service = "com.guilhermemenezes.Tradutor"

    static func string(for account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Grava (ou apaga, se `value` for vazio ou `nil`) o segredo.
    @discardableResult
    static func set(_ value: String?, for account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        guard let value, !value.isEmpty else { return true }

        var attributes = query
        attributes[kSecValueData as String] = Data(value.utf8)
        // Só acessível com o Mac desbloqueado e nunca sincronizado/migrado para outro dispositivo.
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }
}
