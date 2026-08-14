import Foundation
import Security

/// Read and write the API keys the settings table is forbidden to hold: the row
/// stores a Keychain account name, the secret lives here under service `com.yoelgal.Meetings`.
///
/// The transcription engine already reads keys this way; this adds the write half, which Settings
/// needs so a user can paste a key without opening Keychain Access to create the item by hand.
public enum MeetingsKeychain {
    public static let service = "com.yoelgal.Meetings"

    public static func secret(account: String) -> String? {
        var item: CFTypeRef?
        guard SecItemCopyMatching([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ] as CFDictionary, &item) == errSecSuccess,
            let data = item as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Upsert. Passing nil removes the item, which is how a key is cleared — leaving a dead secret
    /// in the Keychain after the user emptied the field would be a small betrayal.
    @discardableResult
    public static func setSecret(_ secret: String?, account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        guard let secret, !secret.isEmpty else { return true }
        var attributes = query
        attributes[kSecValueData as String] = Data(secret.utf8)
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }
}
